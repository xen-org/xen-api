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

val update_allowed_operations : __context:Context.t -> self:API.ref_pool -> unit

(* checks that no other pool ops are running
   before starting a new pool operation *)
val with_pool_operation :
     __context:Context.t
  -> self:API.ref_pool
  -> doc:string
  -> op:API.pool_allowed_operations
  -> (unit -> 'a)
  -> 'a

val ha_disable_in_progress : __context:Context.t -> bool

val ha_enable_in_progress : __context:Context.t -> bool

(* useful when a non-pool operation requires
   that no pool operations are running. *)
val assert_no_pool_ops : __context:Context.t -> unit

val call_fn_on_members_main_first :
     __context:Context.t
  -> (   rpc:(Rpc.call -> Rpc.response)
      -> session_id:API.ref_session
      -> host:API.ref_host
      -> 'a
     )
  -> unit
(** [call_fn_on_members_main_first] Executes a [Client.Client.Host] operation
    on all members in the pool. The operation is done first on the main host.
    Useful when attaching an SR to all hosts in the pool. *)

val call_fn_on_members_main_last :
     __context:Context.t
  -> (   rpc:(Rpc.call -> Rpc.response)
      -> session_id:API.ref_session
      -> host:[`host] Ref.t
      -> 'a
     )
  -> unit
(** [call_fn_on_members_main_first] Executes a [Client.Client.Host] operation
    on all members in the pool. The operation is done last on the main host.
    *)

val get_members : __context:Context.t -> [`host] Ref.t * [`host] Ref.t list
(** [get_members] returns the main host and a list of non-main pool members
    *)

val get_members_main_first : __context:Context.t -> [`host] Ref.t list
(** [get_members_main_first] returns a list of pool members, with the main
    first *)

val get_members_main_last : __context:Context.t -> [`host] Ref.t list
(** [get_members_main_last] returns a list of pool members, with the main
    last*)

val apply_guest_agent_config : __context:Context.t -> unit
