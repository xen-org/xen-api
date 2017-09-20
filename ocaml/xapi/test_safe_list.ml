
let assert_equal l1 l2 = Ounit_comparators.StringList.(assert_equal l1 l2)

let with_vm_list f () =
  let __context = Mock.make_context_with_new_db "Mock context" in
  let vm1 = Test_common.make_vm ~__context ~name_label:"a" ~name_description:"d_a" () in
  let vm2 = Ref.null in
  let vm3 = Test_common.make_vm ~__context ~name_label:"c" ~name_description:"d_c" () in
  Db.VM.destroy ~__context ~self:vm3;
  let vm4 = Test_common.make_vm ~__context ~name_label:"d" ~name_description:"d_d" () in
  f __context [vm1; vm2; vm3; vm4]

let test_map =
  with_vm_list (fun __context l ->
      let f vm = Db.VM.get_name_label ~__context ~self:vm in
      assert_equal ["a"; "d"] (Safe_list.map f l)
    )

(* Be careful: the OUnit module has a function with the same name *)
let test_filter =
  with_vm_list (fun __context l ->
      match l with
      | [vm1; vm2; vm3; vm4] as l->
        let f vm = Db.VM.get_name_label ~__context ~self:vm = "a" in
        OUnit.assert_equal [vm1] (Safe_list.filter f l)
      | _ -> failwith "Our test list should have 4 elements"
    )

let test_flat_map =
  with_vm_list (fun __context l ->
      let f vm = [(Db.VM.get_name_label ~__context ~self:vm); (Db.VM.get_name_description ~__context ~self:vm)] in
      assert_equal ["a"; "d_a"; "d"; "d_d"] (Safe_list.flat_map f l)
    )

let test =
  let ((>:::), (>::)) = OUnit.((>:::), (>::)) in
  "test_safe_list" >:::
  [ "test_map" >:: test_map
  ; "test_filter" >:: test_filter
  ; "test_flat_map" >:: test_flat_map
  ]
