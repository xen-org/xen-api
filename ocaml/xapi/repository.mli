(*
 * Copyright (C) Citrix Systems Inc.
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

val introduce :
     __context:Context.t
  -> name_label:string
  -> name_description:string
  -> binary_url:string
  -> source_url:string
  -> [`Repository] API.Ref.t

val forget :
    __context:Context.t
  -> self:[`Repository] API.Ref.t
  -> unit

val get_enabled_repository :
     __context:Context.t
  -> [`Repository] API.Ref.t

val cleanup :
     __context:Context.t
  -> self:[`Repository] API.Ref.t
  -> prefix:string
  -> unit

val with_reposync_lock : (unit -> 'a) -> 'a

val reposync_try_lock : unit -> bool

val reposync_unlock : unit -> unit
