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

open Listext
open Stringext
open Fun
open Xenops_interface

let ( |> ) a b = b a

let service_name = "xenops"

module D = Debug.Debugger(struct let name = service_name end)

let print_debug = ref false

let debug (fmt: ('a , unit, string, unit) format4) =
	let time_of_float x = 
		let time = Unix.gmtime x in
		Printf.sprintf "%04d%02d%02dT%02d:%02d:%02dZ"
			(time.Unix.tm_year+1900)
			(time.Unix.tm_mon+1)
			time.Unix.tm_mday
			time.Unix.tm_hour
			time.Unix.tm_min
			time.Unix.tm_sec in
	if !print_debug 
	then Printf.kprintf
		(fun s -> 
			Printf.printf "%s %s\n" (time_of_float (Unix.gettimeofday ()))  s; 
			flush stdout) fmt
	else Printf.kprintf (fun s -> D.debug "%s" s) fmt

let all = List.fold_left (&&) true
let any = List.fold_left (||) false

let return x = Some x, None

exception Exception of error

let unwrap = function
    | Some x, None -> x
    | None, Some e -> raise (Exception e)
    | _, _ -> failwith "protocol error"

let dropnone x = List.filter_map (fun x -> x) x

let unbox = function
	| None -> raise (Exception Does_not_exist)
	| Some x -> x

module type READWRITE = sig
	type t
	val t_of_rpc: Rpc.t -> t
	val rpc_of_t: t -> Rpc.t
	val namespace: string
end

let root = "/var/run/" ^ service_name

let rec rm_rf f =
	if not(Sys.is_directory f)
	then Unixext.unlink_safe f
	else begin
		List.iter rm_rf (List.map (Filename.concat f) (Array.to_list (Sys.readdir f)));
		Unix.rmdir f
	end

let empty_database () =
	if Sys.file_exists root then rm_rf root;
	Unixext.mkdir_rec root 0x0755

module TypedTable = functor(RW: READWRITE) -> struct
	open RW
	type key = string list
	let filename_of_key k = Printf.sprintf "%s/%s/%s" root RW.namespace (String.concat "/" k)
	let read (k: key) =
		let filename = filename_of_key k in
		debug "DB.read %s" filename;
		try
			Some (t_of_rpc (Jsonrpc.of_string (Unixext.string_of_file filename)))
		with _ -> None
	let write (k: key) (x: t) =
		let filename = filename_of_key k in
		debug "DB.write %s" filename;
		Unixext.mkdir_rec (Filename.dirname filename) 0o755;
		let json = Jsonrpc.to_string (rpc_of_t x) in
		debug "%s <- %s" filename json;
		Unixext.write_string_to_file filename json
	let exists (k: key) = Sys.file_exists (filename_of_key k)
	let delete (k: key) =
		let filename = filename_of_key k in
		debug "DB.delete %s" filename;
		rm_rf filename
	let list (k: key) =
		if exists k
		then Array.to_list (Sys.readdir (filename_of_key k))
		else []

	let add (k: key) (x: t) =
		if exists k then begin
			debug "Key %s already exists" (String.concat "/" k);
			raise (Exception Already_exists)
		end else write k x

	let remove (k: key) =
		if not(exists k)
		then raise (Exception Does_not_exist)
		else delete k
end

let halted_vm = {
	Vm.power_state = Halted;
	domids = [];
	consoles = [];
	memory_target = 0L;
	rtc_timeoffset = "";
	uncooperative_balloon_driver = false;
	guest_agent = [];
	last_start_time = 0.;
}

let unplugged_pci = {
	Pci.plugged = false;
}

let unplugged_vbd = {
	Vbd.plugged = false;
	kthread_pid = 0;
	media_present = false;
}

let unplugged_vif = {
	Vif.plugged = false;
	kthread_pid = 0;
	media_present = false;
}



