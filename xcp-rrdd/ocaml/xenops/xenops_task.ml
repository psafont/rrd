(*
 * Copyright (C) 2011 Citrix Systems Inc.
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
(**
 * @group Xenops
 *)

open Threadext
open Pervasiveext
open Xenops_interface
open Xenops_utils

type t = {
	id: string;
	mutable result: Task.result;
	mutable subtasks: (string * Task.result) list;
	f: t -> unit;
	cancel: unit -> unit;
}

module SMap = Map.Make(struct type t = string let compare = compare end)
	
let tasks = ref SMap.empty
let m = Mutex.create ()
let c = Condition.create ()

let next_task_id =
	let counter = ref 0 in
	fun () ->
		let result = string_of_int !counter in
		incr counter;
		result

(* XXX: when are these ever removed? *)
let add (f: t -> unit) =
	let t = {
		id = next_task_id ();
		result = Task.Pending 0.;
		subtasks = [];
		f = f;
		cancel = (fun () -> ());
	} in
	Mutex.execute m
		(fun () ->
			tasks := SMap.add t.id t !tasks
		);
	t

let run item =
	try
		let start = Unix.gettimeofday () in
		item.f item;
		let duration = Unix.gettimeofday () -. start in
		item.result <- Task.Completed duration;
	with
		| Exception e ->
			debug "Caught exception while processing queue: %s" (e |> rpc_of_error |> Jsonrpc.to_string);
			item.result <- Task.Failed e
		| e ->
			debug "Caught exception while processing queue: %s" (Printexc.to_string e);
			item.result <- Task.Failed (Internal_error (Printexc.to_string e))

let find_locked id =
	if not (SMap.mem id !tasks) then raise (Exception Does_not_exist);
	SMap.find id !tasks

let with_subtask t name f =
	let start = Unix.gettimeofday () in
	try
		let result = f () in
		t.subtasks <- (name, Task.Completed (Unix.gettimeofday () -. start)) :: t.subtasks;
		result
	with e ->
		t.subtasks <- (name, Task.Failed (Internal_error (Printexc.to_string e))) :: t.subtasks;
		raise e
