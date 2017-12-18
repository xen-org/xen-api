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

(** Tests for the Xapi_clustering module *)

module T = Test_common

(** Tests Xapi_clustering.get_required_cluster_stacks *)
let test_get_required_cluster_stacks =
  let assert_equal ~required_cluster_stacks ~to_set =
    let module S = Ounit_comparators.StringSet in
    S.assert_equal (S.of_list to_set) (S.of_list required_cluster_stacks)
  in

  let test_zero_sms_in_database () =
    let __context = T.make_test_database () in
    let required_cluster_stacks = Xapi_clustering.get_required_cluster_stacks ~__context ~sr_sm_type:"" in
    assert_equal ~required_cluster_stacks ~to_set:[]
  in

  let test_zero_sms_with_matching_type_which_do_require_cluster_stack () =
    let __context = T.make_test_database () in
    let _ = T.make_sm ~__context ~_type:"type2" ~required_cluster_stack:["stack1"; "corosync"] () in
    let _ = T.make_sm ~__context ~_type:"type2" ~required_cluster_stack:["corosync"] () in
    let required_cluster_stacks = Xapi_clustering.get_required_cluster_stacks ~__context ~sr_sm_type:"type1" in
    assert_equal ~required_cluster_stacks ~to_set:[]
  in

  let test_one_sm_with_matching_type_which_doesnt_require_cluster_stack () =
    let __context = T.make_test_database () in
    let _ = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:[] () in
    let required_cluster_stacks = Xapi_clustering.get_required_cluster_stacks ~__context ~sr_sm_type:"type1" in
    assert_equal ~required_cluster_stacks ~to_set:[]
  in

  let test_one_sm_with_matching_type_which_does_require_cluster_stack () =
    let __context = T.make_test_database () in
    let _ = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:["corosync"] () in
    let required_cluster_stacks = Xapi_clustering.get_required_cluster_stacks ~__context ~sr_sm_type:"type1" in
    assert_equal ~required_cluster_stacks ~to_set:["corosync"]
  in

  (* there should probably never be more than one SM of a particular type, but
     test it here anyway to see that the behavior of the function is as
     expected in that situation. *)
  let test_multiple_sms_with_some_matching_type_with_some_requiring_cluster_stack () =
    let __context = T.make_test_database () in
    let _ = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:[] () in
    let _ = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:["corosync"] () in
    let _ = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:["stack1"; "corosync"] () in
    let _ = T.make_sm ~__context ~_type:"type2" ~required_cluster_stack:["corosync"] () in
    let _ = T.make_sm ~__context ~_type:"type2" ~required_cluster_stack:["stack1"] () in
    let _ = T.make_sm ~__context ~_type:"type2" ~required_cluster_stack:["stack1"; "corosync"] () in
    let required_cluster_stacks = Xapi_clustering.get_required_cluster_stacks ~__context ~sr_sm_type:"type1" in
    assert_equal ~required_cluster_stacks ~to_set:["stack1"; "corosync"]
  in

  let open OUnit in
  "test_get_required_cluster_stacks" >:::
  [ "test_zero_sms_in_database" >:: test_zero_sms_in_database
  ; "test_zero_sms_with_matching_type_which_do_require_cluster_stack" >:: test_zero_sms_with_matching_type_which_do_require_cluster_stack
  ; "test_one_sm_with_matching_type_which_doesnt_require_cluster_stack" >:: test_one_sm_with_matching_type_which_doesnt_require_cluster_stack
  ; "test_one_sm_with_matching_type_which_does_require_cluster_stack" >:: test_one_sm_with_matching_type_which_does_require_cluster_stack
  ; "test_multiple_sms_with_some_matching_type_with_some_requiring_cluster_stack" >:: test_multiple_sms_with_some_matching_type_with_some_requiring_cluster_stack
  ]

(** Tests Xapi_clustering.find_cluster_host *)
let test_find_cluster_host =
  let test_find_cluster_host_finds_zero_cluster_hosts () =
    let __context = T.make_test_database () in
    let host = Db.Host.get_all ~__context |> List.hd in
    OUnit.assert_bool "find_cluster_host should return None"
      (Xapi_clustering.find_cluster_host ~__context ~host = None)
  in

  let test_find_cluster_host_finds_one_cluster_host () =
    let __context = T.make_test_database () in
    let host = Db.Host.get_all ~__context |> List.hd in
    let ref = T.make_cluster_host ~__context ~host () in
    let _ = T.make_cluster_host ~__context ~host:(Ref.make ()) () in
    OUnit.assert_bool "find_cluster_host should return (Some ref)"
      (Xapi_clustering.find_cluster_host ~__context ~host = Some ref)
  in

  let test_find_cluster_host_finds_multiple_cluster_hosts () =
    let __context = T.make_test_database () in
    let host = Db.Host.get_all ~__context |> List.hd in
    let _ = T.make_cluster_host ~__context ~host () in
    let _ = T.make_cluster_host ~__context ~host () in
    T.assert_raises_api_error Api_errors.internal_error
      (fun () -> Xapi_clustering.find_cluster_host ~__context ~host)
  in

  let open OUnit in
  "test_find_cluster_host" >:::
  [ "test_find_cluster_host_finds_zero_cluster_hosts" >:: test_find_cluster_host_finds_zero_cluster_hosts
  ; "test_find_cluster_host_finds_one_cluster_host" >:: test_find_cluster_host_finds_one_cluster_host
  ; "test_find_cluster_host_finds_multiple_cluster_hosts" >:: test_find_cluster_host_finds_multiple_cluster_hosts
  ]

(** Tests Xapi_clustering.assert_cluster_host_enabled *)
let test_assert_cluster_host_enabled =
  let test_assert_cluster_host_is_enabled_when_it_is_enabled () =
    let __context = T.make_test_database () in
    let self = T.make_cluster_host ~__context ~enabled:true () in
    try Xapi_clustering.assert_cluster_host_enabled ~__context ~self ~expected:true
    with _ -> OUnit.assert_failure "asserting cluster_host is enabled fails when cluster_host is enabled"
  in

  let test_assert_cluster_host_is_enabled_when_it_is_disabled () =
    let __context = T.make_test_database () in
    let self = T.make_cluster_host ~__context ~enabled:false () in
    T.assert_raises_api_error Api_errors.clustering_disabled ~args:[Ref.string_of self]
      (fun () -> Xapi_clustering.assert_cluster_host_enabled ~__context ~self ~expected:true)
  in

  let test_assert_cluster_host_is_disabled_when_it_is_enabled () =
    let __context = T.make_test_database () in
    let self = T.make_cluster_host ~__context ~enabled:true () in
    T.assert_raises_api_error Api_errors.clustering_enabled ~args:[Ref.string_of self]
      (fun () -> Xapi_clustering.assert_cluster_host_enabled ~__context ~self ~expected:false)
  in

  let test_assert_cluster_host_is_disabled_when_it_is_disabled () =
    let __context = T.make_test_database () in
    let self = T.make_cluster_host ~__context ~enabled:false () in
    try Xapi_clustering.assert_cluster_host_enabled ~__context ~self ~expected:false
    with _ -> OUnit.assert_failure "asserting cluster_host is disabled fails when cluster_host is disabled"
  in

  let open OUnit in
  "test_assert_cluster_host_enabled" >:::
  [ "test_assert_cluster_host_is_enabled_when_it_is_enabled" >:: test_assert_cluster_host_is_enabled_when_it_is_enabled
  ; "test_assert_cluster_host_is_enabled_when_it_is_disabled" >:: test_assert_cluster_host_is_enabled_when_it_is_disabled
  ; "test_assert_cluster_host_is_disabled_when_it_is_enabled" >:: test_assert_cluster_host_is_disabled_when_it_is_enabled
  ; "test_assert_cluster_host_is_disabled_when_it_is_disabled" >:: test_assert_cluster_host_is_disabled_when_it_is_disabled
  ]

(** Tests Xapi_clustering.assert_cluster_host_is_enabled_for_matching_sms *)
let test_assert_cluster_host_is_enabled_for_matching_sms =
  let make_scenario ?(cluster_host_enabled=true) () =
    let __context = T.make_test_database () in
    let host = Db.Host.get_all ~__context |> List.hd in
    let cluster, cluster_host = T.make_cluster_and_cluster_host ~__context () in
    Db.Cluster_host.set_host ~__context ~self:cluster_host ~value:host;
    Db.Cluster_host.set_enabled ~__context ~self:cluster_host ~value:cluster_host_enabled;
    let sm = T.make_sm ~__context ~_type:"type1" ~required_cluster_stack:["corosync"] () in
    __context, host, cluster, cluster_host, sm
  in

  let test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_cluster_host_is_enabled () =
    let __context, host, cluster, cluster_host, sm = make_scenario () in
    OUnit.assert_equal (Xapi_clustering.assert_cluster_host_is_enabled_for_matching_sms ~__context ~host ~sr_sm_type:"type1") ()
  in

  let test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_no_matching_sms_exist () =
    let __context, host, cluster, cluster_host, sm = make_scenario () in
    OUnit.assert_equal (Xapi_clustering.assert_cluster_host_is_enabled_for_matching_sms ~__context ~host ~sr_sm_type:"type2") ()
  in

  let test_assert_cluster_host_is_enabled_for_matching_sms_fails_if_cluster_host_is_disabled () =
    let __context, host, cluster, cluster_host, sm = make_scenario ~cluster_host_enabled:false () in
    T.assert_raises_api_error Api_errors.clustering_disabled ~args:[Ref.string_of cluster_host]
      (fun () -> Xapi_clustering.assert_cluster_host_is_enabled_for_matching_sms ~__context ~host ~sr_sm_type:"type1")
  in

  let open OUnit in
  "test_assert_cluster_host_is_enabled_for_matching_sms" >:::
  [ "test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_cluster_host_is_enabled" >:: test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_cluster_host_is_enabled
  ; "test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_no_matching_sms_exist" >:: test_assert_cluster_host_is_enabled_for_matching_sms_succeeds_if_no_matching_sms_exist
  ; "test_assert_cluster_host_is_enabled_for_matching_sms_fails_if_cluster_host_is_disabled" >:: test_assert_cluster_host_is_enabled_for_matching_sms_fails_if_cluster_host_is_disabled
  ]

let test =
  let open OUnit in
  "test_clustering" >:::
  [ test_get_required_cluster_stacks
  ; test_find_cluster_host
  ; test_assert_cluster_host_enabled
  ; test_assert_cluster_host_is_enabled_for_matching_sms
  ]
