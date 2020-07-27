(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Stdext
open Pervasiveext

module R = Debug.Make (struct let name = "taskhelper" end)

module D = Debug.Make (struct let name = "dummytaskhelper" end)

(** Every operation has an origin: either the HTTP connection it came from or
    an internal subsystem (eg synchroniser thread / event handler
    thread) *)
type origin = Http of Http.Request.t * Unix.file_descr | Internal

let string_of_origin = function
  | Http (req, fd) ->
      let peer =
        match Unix.getpeername fd with
        | Unix.ADDR_UNIX _ ->
            "Unix domain socket"
        | Unix.ADDR_INET _ ->
            "Internet"
      in
      (* unfortunately all connections come from stunnel on localhost *)
      Printf.sprintf "HTTP request from %s with User-Agent: %s" peer
        (default "unknown" req.Http.Request.user_agent)
  | Internal ->
      "Internal"

(** A Context is used to represent every API invocation. It may be extended
    to include extra data without changing all the autogenerated signatures *)
type t = {
    session_id: API.ref_session option
  ; task_id: API.ref_task
  ; forwarded_task: bool
  ; origin: origin
  ; database: Db_ref.t
  ; dbg: string
  ; mutable test_rpc: (Rpc.call -> Rpc.response) option
  ; mutable test_clusterd_rpc: (Rpc.call -> Rpc.response) option
}

let get_session_id x =
  match x.session_id with
  | None ->
      failwith "Could not find a session_id"
  | Some x ->
      x

let forwarded_task ctx = ctx.forwarded_task

let get_task_id ctx = ctx.task_id

let task_in_database ctx = Ref.is_real ctx.task_id

let get_origin ctx = string_of_origin ctx.origin

let database_of x = x.database

(** Calls coming in from the unix socket are pre-authenticated *)
let is_unix_socket s =
  match Unix.getpeername s with
  | Unix.ADDR_UNIX _ ->
      true
  | Unix.ADDR_INET _ ->
      false

let default_database () =
  if Pool_role.is_master () then
    Db_backend.make ()
  else
    Db_ref.Remote

let preauth ~__context =
  match __context.origin with
  | Internal ->
      false
  | Http (req, s) ->
      is_unix_socket s

let get_initial () =
  {
    session_id= None
  ; task_id= Ref.make_dummy "initial_task"
  ; forwarded_task= false
  ; origin= Internal
  ; database= default_database ()
  ; dbg= "initial_task"
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

(* ref fn used to break the cyclic dependency between context, db_actions and taskhelper *)
let __get_task_name : (__context:t -> API.ref_task -> string) ref =
  ref (fun ~__context t -> "__get_task_name not set")

let __make_task =
  ref
    (fun ~__context
         ~(http_other_config : (string * string) list)
         ?(description : string option)
         ?(session_id : API.ref_session option)
         ?(subtask_of : API.ref_task option)
         (task_name : string)
         -> (Ref.null, Uuid.null))

let __destroy_task : (__context:t -> API.ref_task -> unit) ref =
  ref (fun ~__context:_ _ -> ())

let string_of_task __context = __context.dbg

let check_for_foreign_database ~__context =
  match __context.session_id with
  | Some sid -> (
    match Db_backend.get_registered_database (Ref.string_of sid) with
    | Some database ->
        {__context with database}
    | None ->
        __context
  )
  | None ->
      __context

(** destructors *)
let destroy __context =
  if not __context.forwarded_task then
    !__destroy_task ~__context __context.task_id

(* CP-982: create tracking id in log files to link username to actions *)
let trackid_of_session ?(with_brackets = false) ?(prefix = "") session_id =
  match session_id with
  | None ->
      ""
  | Some session_id ->
      (* a hash is used instead of printing the sensitive session_id value *)
      let trackid =
        Printf.sprintf "trackid=%s"
          (Digest.to_hex (Digest.string (Ref.string_of session_id)))
      in
      if with_brackets then Printf.sprintf "%s(%s)" prefix trackid else trackid

let trackid ?(with_brackets = false) ?(prefix = "") __context =
  (* CP-982: create tracking id in log files to link username to actions *)
  trackid_of_session ~with_brackets ~prefix __context.session_id

let make_dbg http_other_config task_name task_id =
  if List.mem_assoc "dbg" http_other_config then
    List.assoc "dbg" http_other_config
  else
    Printf.sprintf "%s%s%s" task_name
      (if task_name = "" then "" else " ")
      (Ref.really_pretty_and_small task_id)

(** constructors *)

let from_forwarded_task ?(http_other_config = []) ?session_id
    ?(origin = Internal) task_id =
  let task_name =
    if Ref.is_dummy task_id then
      Ref.name_of_dummy task_id
    else
      !__get_task_name ~__context:(get_initial ()) task_id
  in
  let info = if not (Ref.is_dummy task_id) then R.info else D.debug in
  (* CP-982: promote tracking debug line to info status *)
  let dbg = make_dbg http_other_config task_name task_id in
  info "task %s forwarded%s" dbg
    (trackid_of_session ~with_brackets:true ~prefix:" " session_id) ;
  {
    session_id
  ; task_id
  ; forwarded_task= true
  ; origin
  ; database= default_database ()
  ; dbg
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

let make ?(http_other_config = []) ?(quiet = false) ?subtask_of ?session_id
    ?(database = default_database ()) ?(task_in_database = false)
    ?task_description ?(origin = Internal) task_name =
  (* create a real or a dummy task *)
  let task_id, task_uuid =
    if task_in_database then
      !__make_task ~__context:(get_initial ()) ~http_other_config
        ?description:task_description ?session_id ?subtask_of task_name
    else
      (Ref.make_dummy task_name, Uuid.null)
  in
  let dbg = make_dbg http_other_config task_name task_id in
  (* log the creation of a subtask (unless quite=true) *)
  ( if (not quiet) && subtask_of <> None then
      let task_uuid =
        if task_uuid = Uuid.null then
          ""
        else
          Printf.sprintf " (uuid:%s)" (Uuid.to_string task_uuid)
      in
      let info = if task_in_database then R.info else D.debug in
      info "task %s%s created%s%s"
        (* CP-982: promote tracking debug line to info status *) dbg task_uuid
        (trackid_of_session ~with_brackets:true ~prefix:" " session_id)
        (* CP-982: link each task to original session created during login *)
        ( match subtask_of with
        | None ->
            ""
        | Some subtask_of ->
            " by task " ^ make_dbg [] "" subtask_of
        )
  ) ;
  {
    session_id
  ; database
  ; task_id
  ; origin
  ; forwarded_task= false
  ; dbg
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

let get_http_other_config http_req =
  let http_other_config_hdr = "x-http-other-config-" in
  http_req.Http.Request.additional_headers
  |> List.filter (fun (k, v) ->
         Astring.String.is_prefix ~affix:http_other_config_hdr k)
  |> List.map (fun (k, v) ->
         ( String.sub k
             (String.length http_other_config_hdr)
             (String.length k - String.length http_other_config_hdr)
         , v ))

(** Called by autogenerated dispatch code *)
let of_http_req ?session_id ?(internal_async_subtask = false) ~generate_task_for
    ~supports_async ~label ~http_req ~fd =
  let http_other_config = get_http_other_config http_req in
  let new_task_context () =
    let subtask_of =
      Pervasiveext.may Ref.of_string http_req.Http.Request.subtask_of
    in
    make ?session_id ?subtask_of ~http_other_config ~task_in_database:true
      ~origin:(Http (http_req, fd))
      label
  in
  if internal_async_subtask then
    new_task_context ()
  else
    match http_req.Http.Request.task with
    | Some task_id ->
        from_forwarded_task ?session_id ~http_other_config
          ~origin:(Http (http_req, fd))
          (Ref.of_string task_id)
    | None ->
        if generate_task_for && supports_async then
          new_task_context ()
        else
          make ?session_id ~http_other_config
            ~origin:(Http (http_req, fd))
            label

let set_test_rpc context rpc = context.test_rpc <- Some rpc

let get_test_rpc context = context.test_rpc

let set_test_clusterd_rpc context rpc = context.test_clusterd_rpc <- Some rpc

let get_test_clusterd_rpc context = context.test_clusterd_rpc
