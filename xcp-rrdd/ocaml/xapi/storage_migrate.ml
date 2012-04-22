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

module D=Debug.Debugger(struct let name="storage_migrate" end)
open D

open Listext
open Fun
open Stringext
open Pervasiveext
open Xmlrpc_client

let local_url = Http.Url.File ({ Http.Url.path = "/var/xapi/storage" }, "/")

open Storage_interface

let rpc url call =
	XMLRPC_protocol.rpc ~transport:(transport_of_url url)
		~http:(xmlrpc ~version:"1.0" ?auth:(Http.Url.auth_of url) (Http.Url.uri_of url)) call

module Local = Client(struct let rpc = rpc local_url end)

let success = function
	| Success x -> x
	| Failure f -> failwith (Printf.sprintf "Storage_interface.Failure %s" (f |> rpc_of_failure_t |> Jsonrpc.to_string))

let _vdi = function
	| Vdi x -> x
	| x -> failwith (Printf.sprintf "type-error, expected Vdi received %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

let _vdis = function
	| Vdis x -> x
	| x -> failwith (Printf.sprintf "type-error, expected Vdis received %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

let params = function
	| Params x -> x
	| x -> failwith (Printf.sprintf "type-error, expected Params received %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

let unit = function
	| Unit -> ()
	| x -> failwith (Printf.sprintf "type-error, expected Unit received %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

let with_activated_disk ~task ~sr ~vdi f =
	let path =
		Opt.map (fun vdi -> 
			let path = Local.VDI.attach ~task ~dp:"migrate" ~sr ~vdi ~read_write:false |> success |> params in
			Local.VDI.activate ~task ~dp:"migrate" ~sr ~vdi |> success |> unit;
			path) vdi in
	finally
		(fun () -> f path)
		(fun () ->
			Opt.iter
				(fun vdi ->
					Local.VDI.deactivate ~task ~dp:"migrate" ~sr ~vdi |> success |> unit;
					Local.VDI.detach ~task ~dp:"migrate" ~sr ~vdi |> success |> unit)
				vdi)

let perform_cleanup_actions =
	List.iter
		(fun f ->
			try f () with e -> error "Caught %s while performing cleanup actions" (Printexc.to_string e)
		)

let export' ~task ~sr ~vdi ~url ~dest =
	let remote_url = Http.Url.of_string url in
	let module Remote = Client(struct let rpc = rpc remote_url end) in

	(* Check the remote SR exists *)
	let srs = Remote.SR.list ~task in
	if not(List.mem dest srs)
	then failwith (Printf.sprintf "Remote SR %s not found" dest);
	(* Find the local VDI *)
	let vdis = Local.SR.scan ~task ~sr |> success |> _vdis in
	let local_vdi =
		try List.find (fun x -> x.vdi = vdi) vdis
		with Not_found -> failwith (Printf.sprintf "Local VDI %s not found" vdi) in
	(* Finding VDIs which are similar to [vdi] *)
	let vdis = Local.VDI.similar_content ~task ~sr ~vdi |> success |> _vdis in
	(* Choose the "nearest" one *)
	let nearest = List.fold_left
		(fun acc vdi -> match acc with
			| Some x -> Some x
			| None ->
				try
					let remote_vdi = Remote.VDI.get_by_name ~task ~sr:dest ~name:vdi.content_id |> success |> _vdi in
					debug "Local VDI %s has same content_id (%s) as remote VDI %s" vdi.vdi vdi.content_id remote_vdi.vdi;
					Some (vdi, remote_vdi)
				with _ -> None) None vdis in

	let dest_vdi =
		match nearest with
			| Some (_, remote_vdi) ->
				debug "Cloning remote VDI %s" remote_vdi.vdi;
				Remote.VDI.clone ~task ~sr:dest ~vdi:remote_vdi.vdi ~vdi_info:local_vdi ~params:[] |> success |> _vdi
			| None ->
				debug "Creating a blank remote VDI";
				Remote.VDI.create ~task ~sr:dest ~vdi_info:local_vdi ~params:[] |> success |> _vdi in
	let on_fail : (unit -> unit) list ref = ref [] in
	try
		on_fail := (fun () -> Remote.VDI.destroy ~task ~sr:dest ~vdi:dest_vdi.vdi |> success |> unit) :: !on_fail;

		let dest_vdi_url = Printf.sprintf "%s/data/%s/%s" url dest dest_vdi.vdi in
		debug "Will copy into new remote VDI: %s (%s)" dest_vdi.vdi dest_vdi_url;

		let base_vdi = Opt.map (fun x -> (fst x).vdi) nearest in
		debug "Will base our copy from: %s" (Opt.default "None" base_vdi);
		with_activated_disk ~task ~sr ~vdi:base_vdi
			(fun base_path ->
				with_activated_disk ~task ~sr ~vdi:(Some vdi)
					(fun src ->
						let args = [
							"-src"; Opt.unbox src;
							"-dest"; dest_vdi_url;
							"-size"; Int64.to_string dest_vdi.virtual_size;
							"-prezeroed"
						] @ (Opt.default [] (Opt.map (fun x -> [ "-base"; x ]) base_path)) in

						let out, err = Forkhelpers.execute_command_get_output "/opt/xensource/libexec/sparse_dd" args in
						debug "%s:%s" out err
					)
			);
		debug "Updating remote content_id";
		Remote.VDI.set_content_id ~task ~sr:dest ~vdi:dest_vdi.vdi ~content_id:local_vdi.content_id |> success |> unit;
		(* XXX: this is useful because we don't have content_ids by default *)
		Local.VDI.set_content_id ~task ~sr ~vdi:local_vdi.vdi ~content_id:local_vdi.content_id |> success |> unit;
		dest_vdi
	with e ->
		error "Caught %s: performing cleanup actions" (Printexc.to_string e);
		perform_cleanup_actions !on_fail;
		raise e

let export ~task ~sr ~vdi ~url ~dest = Success (Vdi (export' ~task ~sr ~vdi ~url ~dest))

let start ~task ~sr ~vdi ~url ~dest =
	let remote_url = Http.Url.of_string url in
	let module Remote = Client(struct let rpc = rpc remote_url end) in

	(* Find the local VDI *)
	let vdis = Local.SR.scan ~task ~sr |> success |> _vdis in
	let local_vdi =
		try List.find (fun x -> x.vdi = vdi) vdis
		with Not_found -> failwith (Printf.sprintf "Local VDI %s not found" vdi) in

	(* A list of cleanup actions to perform if the operation should fail. *)
	let on_fail : (unit -> unit) list ref = ref [] in
	try
		(* XXX: this is a vhd-ism: We need to write into a .vhd leaf *)
		let dummy = Remote.VDI.create ~task ~sr:dest ~vdi_info:local_vdi ~params:[] |> success |> _vdi in
		on_fail := (fun () -> Remote.VDI.destroy ~task ~sr:dest ~vdi:dummy.vdi |> success |> unit) :: !on_fail;
		let leaf = Remote.VDI.clone ~task ~sr:dest ~vdi:dummy.vdi ~vdi_info:local_vdi ~params:[] |> success |> _vdi in
		on_fail := (fun () -> Remote.VDI.destroy ~task ~sr:dest ~vdi:leaf.vdi |> success |> unit) :: !on_fail;
		debug "Created leaf on remote: %s" leaf.vdi;
		(* XXX: this URI construction is fragile *)
		let import_url =
			let new_uri = Printf.sprintf "%s?vdi=%s" Constants.import_raw_vdi_uri leaf.vdi in
			match remote_url with
				| Http.Url.Http(a, b) -> Http.Url.Http(a, new_uri)
				| Http.Url.File(a, b) -> Http.Url.File(a, new_uri) in

		(* Enable mirroring on the local machine *)
		let snapshot = Local.VDI.snapshot ~task ~sr ~vdi:local_vdi.vdi ~vdi_info:local_vdi ~params:["mirror", Http.Url.to_string import_url] |> success |> _vdi in
		on_fail := (fun () -> Local.VDI.destroy ~task ~sr ~vdi:snapshot.vdi |> success |> unit) :: !on_fail;
		(* Copy the snapshot to the remote *)
		let new_parent = export' ~task ~sr ~vdi:snapshot.vdi ~url ~dest in
		Remote.VDI.compose ~task ~sr:dest ~vdi1:new_parent.vdi ~vdi2:leaf.vdi |> success |> unit;
		debug "New parent = %s" new_parent.vdi;
		Success (Vdi leaf)
	with e ->
		error "Caught %s: performing cleanup actions" (Printexc.to_string e);
		perform_cleanup_actions !on_fail;
		Failure (Internal_error (Printexc.to_string e))

let stop ~task ~sr ~vdi =
	(* Find the local VDI *)
	let vdis = Local.SR.scan ~task ~sr |> success |> _vdis in
	let local_vdi =
		try List.find (fun x -> x.vdi = vdi) vdis
		with Not_found -> failwith (Printf.sprintf "Local VDI %s not found" vdi) in
	(* Disable mirroring on the local machine *)
	let snapshot = Local.VDI.snapshot ~task ~sr ~vdi:local_vdi.vdi ~vdi_info:local_vdi ~params:[] |> success |> _vdi in
	Local.VDI.destroy ~task ~sr ~vdi:snapshot.vdi |> success |> unit;
	Success Unit
