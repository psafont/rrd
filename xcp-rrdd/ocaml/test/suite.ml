(*
 * Copyright (C) 2006-2012 Citrix Systems Inc.
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

open OUnit

module MockDatabase= struct

	let schema = ref (Datamodel_schema.of_datamodel ())
	let db_ref = ref (Db_cache_types.Database.make !schema)
	let make_db () = Db_ref.in_memory (ref db_ref)

end (* MockDatabase *)

let skip str = skip_if true str

let test_always_pass () = assert_equal 1 1
let test_always_fail () = skip "This will fail" ; assert_equal 1 0

let test_mock_db () =
	let open MockDatabase in
	let db = make_db () in
	let __context = Context.make
		~database:db
		"Mock context"
	in
	ignore __context ;
	ignore (Db.VM.get_all_records ~__context) ;
	assert_equal 0 0

let test_suite = "test_suit" >:::
	[
		"test_always_pass" >:: test_always_pass ;
		"test_always_fail" >:: test_always_fail ;
		"test_mock_db" >:: test_mock_db ;
	]

let _ = run_test_tt_main test_suite
