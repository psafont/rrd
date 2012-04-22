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

open Xenops_interface
open Xenops_utils
open Xenops_server_plugin
open Xenops_helpers
open Xenstore
open Pervasiveext
open Threadext
open Stringext
open Fun

let _qemu_dm = "/opt/xensource/libexec/qemu-dm-wrapper"
let _tune2fs = "/sbin/tune2fs"
let _mkfs = "/sbin/mkfs"
let _mount = "/bin/mount"
let _umount = "/bin/umount"

let run cmd args =
	debug "%s %s" cmd (String.concat " " args);
	ignore(Forkhelpers.execute_command_get_output cmd args)

module VmExtra = struct
	(** Extra data we store per VM. This is preserved when the domain is
		suspended so it can be re-used in the following 'create' which is
		part of 'resume'. When a VM is shutdown for other reasons (eg reboot)
		we throw this information away and generate fresh data on the
		following 'create' *)
	type t = {
		domid: int;
		create_info: Domain.create_info;
		build_info: Domain.build_info option;
		vcpus: int;
		shadow_multiplier: float;
		memory_static_max: int64;
		suspend_memory_bytes: int64;
		ty: Vm.builder_info option;
		vbds: Vbd.t list; (* needed to regenerate qemu IDE config *)
		vifs: Vif.t list;
		last_create_time: float;
	} with rpc
end

module DB = TypedTable(struct
	include VmExtra
	let namespace = "extra"
end)

(* Used to signal when work needs to be done on a VM *)
let updates = Updates.empty ()

let event_wait timeout p =
	let finished = ref false in
	let success = ref false in
	let event_id = ref None in
	while not !finished do
		let deltas, next_id = Updates.get !event_id timeout updates in
		if deltas = [] then finished := true;
		List.iter (fun d -> if p d then (success := true; finished := true)) deltas;
		event_id := next_id;
	done;
	!success

let this_domid ~xs = int_of_string (xs.Xs.read "domid")

let uuid_of_vm vm = Uuid.uuid_of_string vm.Vm.id
let uuid_of_di di = Uuid.uuid_of_int_array di.Xenctrl.handle
let di_of_uuid ~xc ~xs uuid =
	let all = Xenctrl.domain_getinfolist xc 0 in
	try
		let di = List.find (fun x -> uuid_of_di x = uuid) all in
		Some di
	with Not_found -> None
let domid_of_uuid ~xc ~xs uuid = Opt.map (fun di -> di.Xenctrl.domid) (di_of_uuid ~xc ~xs uuid)

module Storage = struct
	open Storage_interface

	module Client = Client(struct
		let rec retry_econnrefused upto f =
			try
				f ()
			with
				| Unix.Unix_error(Unix.ECONNREFUSED, "connect", _) as e ->
					if upto = 0 then raise e;
					debug "Caught ECONNREFUSED; retrying in 5s";
					Thread.delay 5.;
					retry_econnrefused (upto - 1) f
				| e ->
					debug "Caught %s: (probably a fatal error)" (Printexc.to_string e);
					raise e

		let rpc call =
			let open Xmlrpc_client in
			retry_econnrefused 10
				(fun () ->
					XMLRPC_protocol.rpc ~transport:(Unix "/var/xapi/storage") ~http:(xmlrpc ~version:"1.0" "/") call
				)
	end)

	let success = function
		| Success x -> x
		| x -> failwith (Printf.sprintf "Storage operation returned: %s" (x |> rpc_of_result |> Jsonrpc.to_string))

	let params = function
		| Params p -> p
		| x -> failwith (Printf.sprintf "Storage operation returned bad type. Expected Params; returned: %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

	let unit = function
		| Unit -> ()
		| x -> failwith (Printf.sprintf "Storage operation returned bad type. Expected Unit; returned: %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))			

	let vdi = function
		| Vdi vdi -> vdi
		| x -> failwith (Printf.sprintf "Storage operation returned bad type. Expected Vdi; returned: %s" (x |> rpc_of_success_t |> Jsonrpc.to_string))

	(* Used to identify this VBD to the storage layer *)
	let id_of frontend_domid vbd = Printf.sprintf "vbd/%d/%s" frontend_domid (snd vbd)

	type attached_vdi = {
		domid: int;
		params: string;
	}

	let attach_and_activate task dp sr vdi read_write =
		let result =
			Xenops_task.with_subtask task (Printf.sprintf "VDI.attach %s" dp)
				(fun () -> Client.VDI.attach "attach_and_activate" dp sr vdi read_write |> success |> params) in
		Xenops_task.with_subtask task (Printf.sprintf "VDI.activate %s" dp)
			(fun () -> Client.VDI.activate "attach_and_activate" dp sr vdi |> success |> unit);
		(* XXX: we need to find out the backend domid *)
		{ domid = 0; params = result }

	let deactivate task dp sr vdi =
		Xenops_task.with_subtask task (Printf.sprintf "VDI.deactivate %s" dp)
			(fun () -> Client.VDI.deactivate "deactivate" dp sr vdi |> success |> unit)

	let deactivate_and_detach task dp =
		Xenops_task.with_subtask task (Printf.sprintf "DP.destroy %s" dp)
			(fun () ->
				Client.DP.destroy "deactivate_and_detach" dp false |> success |> unit)

	let get_disk_by_name task path =
		debug "Storage.get_disk_by_name %s" path;
		Xenops_task.with_subtask task (Printf.sprintf "get_by_name %s" path)
			(fun () ->
				let vdi = Client.get_by_name "get_by_name" path |> success |> vdi in
				vdi.sr, vdi.vdi
			)
end

let with_disk ~xc ~xs task disk write f = match disk with
	| Local path -> f path
	| VDI path ->
		let open Storage_interface in
		let open Storage in
		let sr, vdi = get_disk_by_name task path in
		let dp = Client.DP.create "with_disk" "xenopsd" in
		finally
			(fun () ->
				let vdi = attach_and_activate task dp sr vdi write in
				let backend_vm_id = uuid_of_di (Xenctrl.domain_getinfo xc vdi.domid) |> Uuid.string_of_uuid in

				let frontend_domid = this_domid ~xs in
				begin match domid_of_uuid ~xc ~xs (Uuid.uuid_of_string backend_vm_id) with
					| None ->
						debug "Failed to determine my own domain id!";
						raise (Exception Does_not_exist)
					| Some backend_domid when backend_domid = frontend_domid ->
						(* There's no need to use a PV disk if we're in the same domain *)
						f vdi.params
					| Some backend_domid ->
						let t = {
							Device.Vbd.mode = Device.Vbd.ReadOnly;
							device_number = None; (* we don't mind *)
							phystype = Device.Vbd.Phys;
							params = vdi.params;
							dev_type = Device.Vbd.Disk;
							unpluggable = true;
							protocol = None;
							extra_backend_keys = [];
							extra_private_keys = [];
							backend_domid = backend_domid;
						} in
						let device =
							Xenops_task.with_subtask task "Vbd.add"
								(fun () -> Device.Vbd.add ~xs ~hvm:false t frontend_domid) in
						let open Device_common in
						let block_device =
							device.frontend.devid |> Device_number.of_xenstore_key |> Device_number.to_linux_device |> (fun x -> "/dev/" ^ x) in
						finally
							(fun () ->
								f block_device
							)
							(fun () ->
								Xenops_task.with_subtask task "Vbd.clean_shutdown"
									(fun () ->
										(* To avoid having two codepaths: a 99% "normal" codepath and a 1%
										   "transient failure" codepath we deliberately trigger a "transient
										   failure" in 100% of cases by opening the device ourselves. *)
										let f = ref (Some (Unix.openfile block_device [ Unix.O_RDONLY ] 0o0)) in
										let close () = Opt.iter (fun fd -> Unix.close fd; f := None) !f in
										finally
											(fun () ->
												debug "Opened %s" block_device;
												Device.Vbd.clean_shutdown_async ~xs device;
												try
													Device.Vbd.clean_shutdown_wait ~xs device
												with Device_error(_, x) ->
													debug "Caught transient Device_error %s" x;
													close ();
													Device.Vbd.clean_shutdown_wait ~xs device
											) (fun () -> close ())
									)
							)
				end
			)
			(fun () -> deactivate_and_detach task dp)

module Mem = struct
	let call_daemon xs fn args = Squeezed_rpc.Rpc.client ~xs ~service:Squeezed_rpc._service ~fn ~args
	let ignore_results (_: (string * string) list) = ()

	let wrap f =
		try f ()
		with
			| Squeezed_rpc.Error(code, descr) -> raise (Exception (Ballooning_error(code, descr)))
			| Squeezed_rpc.Server_not_registered -> raise (Exception (No_ballooning_service))

	let do_login_exn ~xs =
		let args = [ Squeezed_rpc._service_name, "xenopsd" ] in
		let results = call_daemon xs Squeezed_rpc._login args in
		List.assoc Squeezed_rpc._session_id results
	let do_login ~xs = wrap (fun () -> do_login_exn ~xs)

	(** Maintain a cached login session with the ballooning service; return the cached value on demand *)
	let get_session_id =
		let session_id = ref None in
		let m = Mutex.create () in
		fun ~xs ->
			Mutex.execute m
				(fun () ->
					match !session_id with
						| Some x -> x
						| None ->
							let s = do_login ~xs in
							session_id := Some s;
							s
				)

	(** If we fail to allocate because VMs either failed to co-operate or because they are still booting
		and haven't written their feature-balloon flag then retry for a while before finally giving up.
		In particular this should help smooth over the period when VMs are booting and haven't loaded their balloon
		drivers yet. *)
	let retry f =
		let start = Unix.gettimeofday () in
		let interval = 10. in
		let timeout = 60. in
		let rec loop () =
			try
				f ()
			with
				| Squeezed_rpc.Error(code, descr) as e when
					false
					|| code = Squeezed_rpc._error_domains_refused_to_cooperate_code
					|| code = Squeezed_rpc._error_cannot_free_this_much_memory_code ->
				let now = Unix.gettimeofday () in
				if now -. start > timeout then raise e else begin
					debug "Sleeping %.0f before retrying" interval;
					Thread.delay interval;
					loop ()
				end in
		loop ()

	(** Reserve a particular amount of memory and return a reservation id *)
	let reserve_memory_range_exn ~xc ~xs ~min ~max =
		let session_id = get_session_id ~xs in
		let reserved_memory, reservation_id =
			retry
				(fun () ->
					debug "reserve_memory_range min=%Ld max=%Ld" min max;
					let args = [ Squeezed_rpc._session_id, session_id; Squeezed_rpc._min, Int64.to_string min; Squeezed_rpc._max, Int64.to_string max ] in
					let results = call_daemon xs Squeezed_rpc._reserve_memory_range args in
					let kib = List.assoc Squeezed_rpc._kib results
					and reservation_id = List.assoc Squeezed_rpc._reservation_id results in
					debug "reserve_memory_range actual = %s" kib;
					Int64.of_string kib, reservation_id
				)
		in
		debug "reserved_memory = %Ld; min = %Ld; max = %Ld" reserved_memory min max;
		(* Post condition: *)
		assert (reserved_memory >= min);
		assert (reserved_memory <= max);
		reserved_memory, reservation_id
	let reserve_memory_range ~xc ~xs ~min ~max =
		wrap (fun () -> reserve_memory_range_exn ~xc ~xs ~min ~max)

	(** Delete a reservation given by [reservation_id] *)
	let delete_reservation_exn ~xs ~reservation_id =
		let session_id = get_session_id ~xs in
		debug "delete_reservation %s" reservation_id;
		let args = [ Squeezed_rpc._session_id, session_id; Squeezed_rpc._reservation_id, reservation_id ] in
		ignore_results (call_daemon xs Squeezed_rpc._delete_reservation args)
	let delete_reservation ~xs ~reservation_id =
		wrap (fun () -> delete_reservation_exn ~xs ~reservation_id)

	(** Reserves memory, passes the id to [f] and cleans up afterwards. If the user
		wants to keep the memory, then call [transfer_reservation_to_domain]. *)
	let with_reservation ~xc ~xs ~min ~max f =
		let amount, id = reserve_memory_range ~xc ~xs ~min ~max in
		finally
			(fun () -> f amount id)
			(fun () -> delete_reservation ~xs ~reservation_id:id)

	(** Transfer this 'reservation' to the given domain id *)
	let transfer_reservation_to_domain_exn ~xs ~reservation_id ~domid =
		let session_id = get_session_id ~xs in
		debug "transfer_reservation_to_domain %s -> %d" reservation_id domid;
		let args = [ Squeezed_rpc._session_id, session_id; Squeezed_rpc._reservation_id, reservation_id; Squeezed_rpc._domid, string_of_int domid ] in
		ignore_results (call_daemon xs Squeezed_rpc._transfer_reservation_to_domain args)
	let transfer_reservation_to_domain ~xs ~reservation_id ~domid =
		wrap (fun () -> transfer_reservation_to_domain_exn ~xs ~reservation_id ~domid)

	(** After an event which frees memory (eg a domain destruction), perform a one-off memory rebalance *)
	let balance_memory ~xc ~xs =
		debug "rebalance_memory";
		ignore_results (call_daemon xs Squeezed_rpc._balance_memory [])

end

(* We store away the device name so we can lookup devices by name later *)
let _device_id kind = Device_common.string_of_kind kind ^ "-id"

(* Return the xenstore device with [kind] corresponding to [id] *)
let device_by_id xc xs vm kind id =
	match vm |> Uuid.uuid_of_string |> domid_of_uuid ~xc ~xs with
		| None ->
			debug "VM %s does not exist in domain list" vm;
			raise (Exception Does_not_exist)
		| Some frontend_domid ->
			let devices = Device_common.list_frontends ~xs frontend_domid in
			let key = _device_id kind in
			let id_of_device device =
				let path = Hotplug.get_private_data_path_of_device device in
				try Some (xs.Xs.read (Printf.sprintf "%s/%s" path key))
				with _ -> None in
			try
				List.find (fun device -> id_of_device device = Some id) devices
			with Not_found ->
				raise (Exception Device_not_connected)

module VM = struct
	open Vm

	let key_of vm = [ vm.Vm.id ]

	let will_be_hvm vm = match vm.ty with HVM _ -> true | _ -> false

	let compute_overhead domain =
		let static_max_mib = Memory.mib_of_bytes_used domain.VmExtra.memory_static_max in
		let memory_overhead_mib =
			(if domain.VmExtra.create_info.Domain.hvm then Memory.HVM.overhead_mib else Memory.Linux.overhead_mib)
			static_max_mib domain.VmExtra.vcpus domain.VmExtra.shadow_multiplier in
		Memory.bytes_of_mib memory_overhead_mib

	let shutdown_reason = function
		| Reboot -> Domain.Reboot
		| PowerOff -> Domain.PowerOff
		| Suspend -> Domain.Suspend
		| Halt -> Domain.Halt
		| S3Suspend -> Domain.S3Suspend

	(* We compute our initial target at memory reservation time, done before the domain
	   is created. We consume this information later when the domain is built. *)
	let set_initial_target ~xs domid initial_target =
		xs.Xs.write (Printf.sprintf "/local/domain/%d/memory/initial-target" domid)
			(Int64.to_string initial_target)
	let get_initial_target ~xs domid =
		Int64.of_string (xs.Xs.read (Printf.sprintf "/local/domain/%d/memory/initial-target" domid))

	let create_exn (task: Xenops_task.t) vm =
		let k = key_of vm in
		let vmextra =
			if DB.exists k then begin
				debug "VM %s: reloading stored domain-level configuration" vm.Vm.id;
				DB.read k |> unbox
			end else begin
				debug "VM %s: has no stored domain-level configuration, regenerating" vm.Vm.id;
				let hvm = match vm.ty with HVM _ -> true | _ -> false in
				(* XXX add per-vcpu information to the platform data *)
				let vcpus = [
					"vcpu/number", string_of_int vm.vcpus;
					"vcpu/current", string_of_int vm.vcpus;
				] in
				let create_info = {
					Domain.ssidref = vm.ssidref;
					hvm = hvm;
					hap = hvm;
					name = vm.name;
					xsdata = vm.xsdata;
					platformdata = vm.platformdata @ vcpus;
					bios_strings = vm.bios_strings;
				} in {
					VmExtra.domid = 0;
					create_info = create_info;
					build_info = None;
					vcpus = vm.vcpus;
					shadow_multiplier = (match vm.Vm.ty with Vm.HVM { Vm.shadow_multiplier = sm } -> sm | _ -> 1.);
					memory_static_max = vm.memory_static_max;
					suspend_memory_bytes = 0L;
					ty = None;
					vbds = [];
					vifs = [];
					last_create_time = Unix.gettimeofday ();
				}
			end in
		with_xc_and_xs
			(fun xc xs ->
				let open Memory in
				let overhead_bytes = compute_overhead vmextra in
				(* If we are resuming then we know exactly how much memory is needed *)
				let resuming = vmextra.VmExtra.suspend_memory_bytes <> 0L in
				let min_kib = kib_of_bytes_used (if resuming then vmextra.VmExtra.suspend_memory_bytes else (vm.memory_dynamic_min +++ overhead_bytes)) in
				let max_kib = kib_of_bytes_used (if resuming then vmextra.VmExtra.suspend_memory_bytes else (vm.memory_dynamic_max +++ overhead_bytes)) in
				Mem.with_reservation ~xc ~xs ~min:min_kib ~max:max_kib
					(fun target_plus_overhead_kib reservation_id ->
						let domid = Domain.make ~xc ~xs vmextra.VmExtra.create_info (uuid_of_vm vm) in
						DB.write k {
							vmextra with
							VmExtra.domid = domid;
						};
						Mem.transfer_reservation_to_domain ~xs ~reservation_id ~domid;
						let initial_target =
							let target_plus_overhead_bytes = bytes_of_kib target_plus_overhead_kib in
							let target_bytes = target_plus_overhead_bytes --- overhead_bytes in
							min vm.memory_dynamic_max target_bytes in
						set_initial_target ~xs domid initial_target;
						if vm.suppress_spurious_page_faults
						then Domain.suppress_spurious_page_faults ~xc domid;
						Domain.set_machine_address_size ~xc domid vm.machine_address_size;
						for i = 0 to vm.vcpus (* XXX max *) - 1 do
							Device.Vcpu.add ~xs ~devid:i domid
						done
					)
			)
	let create = create_exn

	let on_domain f (task: Xenops_task.t) vm =
		let uuid = uuid_of_vm vm in
		with_xc_and_xs
			(fun xc xs ->
				match di_of_uuid ~xc ~xs uuid with
					| None -> raise (Exception Does_not_exist)
					| Some di -> f xc xs task vm di
			)

	let destroy = on_domain (fun xc xs task vm di ->
		let domid = di.Xenctrl.domid in

		let vbds = Opt.default [] (Opt.map (fun d -> d.VmExtra.vbds) (DB.read (key_of vm))) in

		(* Normally we throw-away our domain-level information. If the domain
		   has suspended then we preserve it. *)
		if di.Xenctrl.shutdown && (Domain.shutdown_reason_of_int di.Xenctrl.shutdown_code = Domain.Suspend)
		then debug "VM %s (domid: %d) has suspended; preserving domain-level information" vm.Vm.id di.Xenctrl.domid
		else begin
			debug "VM %s (domid: %d) will not have domain-level information preserved" vm.Vm.id di.Xenctrl.domid;
			if DB.exists (key_of vm) then DB.remove (key_of vm);
		end;
		Domain.destroy ~preserve_xs_vm:false ~xc ~xs domid;
		(* Detach any remaining disks *)
		List.iter (fun vbd -> Storage.deactivate_and_detach task (Storage.id_of domid vbd.Vbd.id)) vbds
	)

	let pause = on_domain (fun xc xs _ _ di ->
		if di.Xenctrl.total_memory_pages = 0n then raise (Exception Domain_not_built);
		Domain.pause ~xc di.Xenctrl.domid
	)

	let unpause = on_domain (fun xc xs _ _ di ->
		if di.Xenctrl.total_memory_pages = 0n then raise (Exception Domain_not_built);
		Domain.unpause ~xc di.Xenctrl.domid
	)

	(* NB: the arguments which affect the qemu configuration must be saved and
	   restored with the VM. *)
	let create_device_model_config = function
		| { VmExtra.build_info = None }
		| { VmExtra.ty = None } -> raise (Exception Domain_not_built)
		| { VmExtra.ty = Some ty; build_info = Some build_info; vifs = vifs; vbds = vbds } ->
			let make ?(boot_order="cd") ?(serial="pty") ?(nics=[])
					?(disks=[]) ?(pci_emulations=[]) ?(usb=["tablet"])
					?(acpi=true) ?(video=Cirrus) ?(keymap="en-us")
					?vnc_ip ?(pci_passthrough=false) ?(hvm=true) ?(video_mib=4) () =
				let video = match video with
					| Cirrus -> Device.Dm.Cirrus
					| Standard_VGA -> Device.Dm.Std_vga in
				let open Device.Dm in {
					memory = build_info.Domain.memory_max;
					boot = boot_order;
					serial = serial;
					vcpus = build_info.Domain.vcpus;
					nics = nics;
					disks = disks;
					pci_emulations = pci_emulations;
					usb = usb;
					acpi = acpi;
					disp = VNC (video, vnc_ip, true, 0, keymap);
					pci_passthrough = pci_passthrough;
					xenclient_enabled=false;
					hvm=hvm;
					sound=None;
					power_mgmt=None;
					oem_features=None;
					inject_sci = None;
					video_mib=video_mib;
					extras = [];
				} in
			let bridge_of_network = function
				| Bridge b -> b
				| VSwitch v -> v
				| Netback (_, _) -> failwith "Need to create a VIF frontend" in
			let nics = List.map (fun vif ->
				vif.Vif.mac,
				bridge_of_network vif.Vif.backend,
				vif.Vif.position
			) vifs in
			match ty with
				| PV { framebuffer = false } -> None
				| PV { framebuffer = true } ->
					Some (make ~hvm:false ())
				| HVM hvm_info ->
					if hvm_info.qemu_disk_cmdline
					then failwith "Need a disk frontend in this domain";
					Some (make ~video_mib:hvm_info.video_mib
						~video:hvm_info.video ~acpi:hvm_info.acpi
						?serial:hvm_info.serial ?keymap:hvm_info.keymap
						?vnc_ip:hvm_info.vnc_ip
						~pci_emulations:hvm_info.pci_emulations
						~pci_passthrough:hvm_info.pci_passthrough
						~boot_order:hvm_info.boot_order ~nics ())


	let build_domain_exn xc xs domid task vm vbds vifs =
		let open Memory in
		let initial_target = get_initial_target ~xs domid in
		let make_build_info kernel priv = {
			Domain.memory_max = vm.memory_static_max /// 1024L;
			memory_target = initial_target /// 1024L;
			kernel = kernel;
			vcpus = vm.vcpus;
			priv = priv;
		} in
		(* We should prevent leaking files in our filesystem *)
		let kernel_to_cleanup = ref None in
		finally (fun () ->
			let build_info =
				match vm.ty with
					| HVM hvm_info ->
						let builder_spec_info = Domain.BuildHVM {
							Domain.shadow_multiplier = hvm_info.shadow_multiplier;
							timeoffset = hvm_info.timeoffset;
							video_mib = hvm_info.video_mib;
						} in
						make_build_info Domain.hvmloader builder_spec_info
					| PV { boot = Direct direct } ->
						let builder_spec_info = Domain.BuildPV {
							Domain.cmdline = direct.cmdline;
							ramdisk = direct.ramdisk;
						} in
						make_build_info direct.kernel builder_spec_info
					| PV { boot = Indirect { devices = [] } } ->
						raise (Exception No_bootable_device)
					| PV { boot = Indirect ( { devices = d :: _ } as i ) } ->
						with_disk ~xc ~xs task d false
							(fun dev ->
								let b = Bootloader.extract ~bootloader:i.bootloader 
									~legacy_args:i.legacy_args ~extra_args:i.extra_args
									~pv_bootloader_args:i.bootloader_args 
									~disk:dev ~vm:vm.Vm.id () in
								kernel_to_cleanup := Some b;
								let builder_spec_info = Domain.BuildPV {
									Domain.cmdline = b.Bootloader.kernel_args;
									ramdisk = b.Bootloader.initrd_path;
								} in
								make_build_info b.Bootloader.kernel_path builder_spec_info
							) in
			let arch = Domain.build ~xc ~xs build_info domid in
			Domain.cpuid_apply ~xc ~hvm:(will_be_hvm vm) domid;
			debug "Built domid %d with architecture %s" domid (Domain.string_of_domarch arch);
			let k = key_of vm in
			let d = Opt.unbox (DB.read k) in
			DB.write k { d with
				VmExtra.build_info = Some build_info;
				ty = Some vm.ty;
				vbds = vbds;
				vifs = vifs;
			}
		) (fun () -> Opt.iter Bootloader.delete !kernel_to_cleanup)


	let build_domain vm vbds vifs xc xs task _ di =
		try
			build_domain_exn xc xs di.Xenctrl.domid task vm vbds vifs
		with
			| Bootloader.Bad_sexpr x ->
				let m = Printf.sprintf "Bootloader.Bad_sexpr %s" x in
				debug "%s" m;
				raise (Exception (Internal_error m))
			| Bootloader.Bad_error x ->
				let m = Printf.sprintf "Bootloader.Bad_error %s" x in
				debug "%s" m;
				raise (Exception (Internal_error m))
			| Bootloader.Unknown_bootloader x ->
				let m = Printf.sprintf "Bootloader.Unknown_bootloader %s" x in
				debug "%s" m;
				raise (Exception (Internal_error m))
			| Bootloader.Error_from_bootloader (a, b) ->
				let m = Printf.sprintf "Bootloader.Error_from_bootloader (%s, [ %s ])" a (String.concat "; " b) in
				debug "%s" m;
				raise (Exception (Bootloader_error (a, b)))
			| e ->
				let m = Printf.sprintf "Bootloader error: %s" (Printexc.to_string e) in
				debug "%s" m;
				raise (Exception (Internal_error m))

	let build task vm vbds vifs = on_domain (build_domain vm vbds vifs) task vm

	let create_device_model_exn saved_state xc xs task vm di =
		let vmextra = vm |> key_of |> DB.read |> Opt.unbox in
		Opt.iter (fun info ->
			(if saved_state then Device.Dm.restore else Device.Dm.start)
			~xs ~dmpath:_qemu_dm info di.Xenctrl.domid) (vmextra |> create_device_model_config);
		match vm.Vm.ty with
			| Vm.PV { vncterm = true; vncterm_ip = ip } -> Device.PV_Vnc.start ~xs ?ip di.Xenctrl.domid
			| _ -> ()

	let create_device_model task vm saved_state = on_domain (create_device_model_exn saved_state) task vm

	let request_shutdown task vm reason ack_delay =
		let reason = shutdown_reason reason in
		on_domain
			(fun xc xs vm task di ->
				let domid = di.Xenctrl.domid in
				try
					Domain.shutdown ~xs domid reason;
					debug "Calling shutdown_wait_for_ack";
					Domain.shutdown_wait_for_ack ~timeout:ack_delay ~xc ~xs domid reason;
					true
				with Watch.Timeout _ ->
					false
			) task vm

	let wait_shutdown task vm reason timeout =
		event_wait (Some (timeout |> ceil |> int_of_float))
			(function
				| Dynamic.Vm id when id = vm.Vm.id ->
					debug "EVENT on our VM: %s" id;
					on_domain (fun xc xs _ vm di -> di.Xenctrl.shutdown) task vm
				| Dynamic.Vm id ->
					debug "EVENT on other VM: %s" id;
					false
				| _ ->
					debug "OTHER EVENT";
					false)

	(* Create an ext2 filesystem without maximal mount count and
	   checking interval. *)
	let mke2fs device =
		run _mkfs ["-t"; "ext2"; device];
		run _tune2fs  ["-i"; "0"; "-c"; "0"; device]

	(* Mount a filesystem somewhere, with optional type *)
	let mount ?ty:(ty = None) src dest =
		let ty = match ty with None -> [] | Some ty -> [ "-t"; ty ] in
		ignore(run _mount (ty @ [ src; dest ]))

	let timeout = 300. (* 5 minutes: something is seriously wrong if we hit this timeout *)
	exception Umount_timeout

	(** Unmount a mountpoint. Retries every 5 secs for a total of 5mins before returning failure *)
	let umount ?(retry=true) dest =
		let finished = ref false in
		let start = Unix.gettimeofday () in

		while not(!finished) && (Unix.gettimeofday () -. start < timeout) do
			try
				run _umount [dest];
				finished := true
			with e ->
				if not(retry) then raise e;
				debug "Caught exception (%s) while unmounting %s: pausing before retrying"
					(Printexc.to_string e) dest;
				Thread.delay 5.
		done;
		if not(!finished) then raise Umount_timeout

	let with_mounted_dir device f =
		let mount_point = Filename.temp_file "xenops_mount_" "" in
		Unix.unlink mount_point;
		Unix.mkdir mount_point 0o640;
		finally
			(fun () ->
				mount ~ty:(Some "ext2") device mount_point;
				f mount_point)
			(fun () ->
				(try umount mount_point with e -> debug "Caught %s" (Printexc.to_string e));
				(try Unix.rmdir mount_point with e -> debug "Caught %s" (Printexc.to_string e))
			)

	let with_data ~xc ~xs task data write f = match data with
		| Disk disk ->
			with_disk ~xc ~xs task disk write
				(fun path ->
					if write then mke2fs path;
					with_mounted_dir path
						(fun dir ->
							(* Do we really want to balloon the guest down? *)
							let flags =
								if write
								then [ Unix.O_WRONLY; Unix.O_CREAT ]
								else [ Unix.O_RDONLY ] in
							let filename = dir ^ "/suspend-image" in
							Unixext.with_file filename flags 0o600
								(fun fd ->
									finally
										(fun () -> f fd)
										(fun () ->
											try
												Unixext.fsync fd;
											with Unix.Unix_error(Unix.EIO, _, _) ->
												debug "Caught EIO in fsync after suspend; suspend image may be corrupt";
												raise (Exception IO_error)
										)
								)
						)
				)
		| FD fd -> f fd

	let save task vm flags data =
		let flags' =
			List.map
				(function
					| Live -> Domain.Live
				) flags in
		on_domain
			(fun xc xs (task:Xenops_task.t) vm di ->
				let hvm = di.Xenctrl.hvm_guest in
				let domid = di.Xenctrl.domid in
				with_data ~xc ~xs task data true
					(fun fd ->
						debug "Invoking Domain.suspend";
						Domain.suspend ~xc ~xs ~hvm domid fd flags'
							(fun () ->
								debug "In callback";
								if not(request_shutdown task vm Suspend 30.)
								then raise (Exception Failed_to_acknowledge_shutdown_request);
								debug "Waiting for shutdown";
								if not(wait_shutdown task vm Suspend 1200.)
								then raise (Exception Failed_to_shutdown);
							);
						(* Record the final memory usage of the domain so we know how
						   much to allocate for the resume *)
						let di = Xenctrl.domain_getinfo xc domid in
						let pages = Int64.of_nativeint di.Xenctrl.total_memory_pages in
						debug "Final memory usage of the domain = %Ld pages" pages;
						(* Flush all outstanding disk blocks *)

						let k = key_of vm in
						let d = Opt.unbox (DB.read k) in
						
						let devices = List.map (fun vbd -> vbd.Vbd.id |> snd |> device_by_id xc xs vm.id Device_common.Vbd) d.VmExtra.vbds in
						Domain.hard_shutdown_all_vbds ~xc ~xs devices;
						List.iter (fun vbd -> match vbd.Vbd.backend with
							| None
							| Some (Local _) -> ()
							| Some (VDI path) ->
								let sr, vdi = Storage.get_disk_by_name task path in
								Storage.deactivate task (Storage.id_of domid vbd.Vbd.id) sr vdi
						) d.VmExtra.vbds;

						DB.write k { d with
							VmExtra.suspend_memory_bytes = Memory.bytes_of_pages pages;
						}
					)
			) task vm

	let restore task vm data =
		let build_info = vm |> key_of |> DB.read |> Opt.unbox |> (fun x -> x.VmExtra.build_info) |> Opt.unbox in
		on_domain
			(fun xc xs task vm di ->
				let domid = di.Xenctrl.domid in
				with_data ~xc ~xs task data false
					(fun fd ->
						Domain.restore ~xc ~xs build_info domid fd
					)
			) task vm

	let get_state vm =
		let uuid = uuid_of_vm vm in
		let vme = vm |> key_of |> DB.read in (* may not exist *)
		with_xc_and_xs
			(fun xc xs ->
				match domid_of_uuid ~xc ~xs uuid with
					| None ->
						(* XXX: we need to store (eg) guest agent info *)
						begin match vme with
							| Some { VmExtra.suspend_memory_bytes = 0L } ->
								halted_vm
							| Some _ ->
								{ halted_vm with Vm.power_state = Suspended }
							| None ->
								halted_vm
						end
					| Some d ->
						let vnc = Opt.map (fun port -> { Vm.protocol = Vm.Rfb; port = port })
							(Device.get_vnc_port ~xs d)in
						let tc = Opt.map (fun port -> { Vm.protocol = Vm.Vt100; port = port })
							(Device.get_tc_port ~xs d) in
						let local x = Printf.sprintf "/local/domain/%d/%s" d x in
						let uncooperative = try ignore_string (xs.Xs.read (local "memory/uncooperative")); true with Xenbus.Xb.Noent -> false in
						let memory_target = try xs.Xs.read (local "memory/target") |> Int64.of_string |> Int64.mul 1024L with Xenbus.Xb.Noent -> 0L in
						let rtc = try xs.Xs.read (Printf.sprintf "/vm/%s/rtc/timeoffset" (Uuid.string_of_uuid uuid)) with Xenbus.Xb.Noent -> "" in
						let rec ls_lR root dir =
							let this = try [ dir, xs.Xs.read (root ^ "/" ^ dir) ] with _ -> [] in
							let subdirs = try List.map (fun x -> dir ^ "/" ^ x) (xs.Xs.directory (root ^ "/" ^ dir)) with _ -> [] in
							this @ (List.concat (List.map (ls_lR root) subdirs)) in
						let guest_agent =
							[ "drivers"; "attr"; "data" ] |> List.map (ls_lR (Printf.sprintf "/local/domain/%d" d)) |> List.concat in
						{
							Vm.power_state = Running;
							domids = [ d ];
							consoles = Opt.to_list vnc @ (Opt.to_list tc);
							uncooperative_balloon_driver = uncooperative;
							guest_agent = guest_agent;
							memory_target = memory_target;
							rtc_timeoffset = rtc;
							last_start_time = match vme with
								| Some x -> x.VmExtra.last_create_time
								| None -> 0.
						}
			)

	let get_domain_action_request vm =
		let uuid = uuid_of_vm vm in
		with_xc_and_xs
			(fun xc xs ->
				match di_of_uuid ~xc ~xs uuid with
					| None -> Some Needs_poweroff
					| Some d ->
						if d.Xenctrl.shutdown
						then Some (match d.Xenctrl.shutdown_code with
							| 0 -> Needs_poweroff
							| 1 -> Needs_reboot
							| 2 -> Needs_suspend
							| 3 -> Needs_crashdump
							| _ -> Needs_poweroff) (* unexpected *)
						else None
			)

	let get_internal_state vm =
		vm |> key_of |> DB.read |> Opt.unbox |> VmExtra.rpc_of_t |> Jsonrpc.to_string

	let set_internal_state vm state =
		let k = key_of vm in
		DB.write k (state |> Jsonrpc.of_string |> VmExtra.t_of_rpc)
end

let on_frontend f frontend =
	with_xc_and_xs
		(fun xc xs ->
			let frontend_di = frontend |> Uuid.uuid_of_string |> di_of_uuid ~xc ~xs |> unbox in
			f xc xs frontend_di.Xenctrl.domid frontend_di.Xenctrl.hvm_guest
		)

module PCI = struct
	open Pci

	let id_of pci = snd pci.id

	let get_state vm pci =
		with_xc_and_xs
			(fun xc xs ->
				let all = match domid_of_uuid ~xc ~xs (Uuid.uuid_of_string vm) with
					| Some domid -> Device.PCI.list ~xc ~xs domid |> List.map snd
					| None -> [] in
				{
					plugged = List.mem (pci.domain, pci.bus, pci.dev, pci.fn) all
				}
			)

	let plug task vm pci =
		let device = pci.domain, pci.bus, pci.dev, pci.fn in
		let msitranslate = if pci.msitranslate then 1 else 0
		and pci_power_mgmt = if pci.power_mgmt then 1 else 0 in
		Device.PCI.bind [ device ];
		on_frontend
			(fun xc xs frontend_domid hvm ->
				(* If the guest is HVM then we plug via qemu *)
				if hvm
				then Device.PCI.plug ~xc ~xs device frontend_domid
				else Device.PCI.add ~xc ~xs ~hvm ~msitranslate ~pci_power_mgmt [ device ] frontend_domid 0
			) vm

	let unplug task vm pci =
		let device = pci.domain, pci.bus, pci.dev, pci.fn in
		on_frontend
			(fun xc xs frontend_domid hvm ->
				if hvm
				then Device.PCI.unplug ~xc ~xs device frontend_domid
				else debug "PCI.unplug for PV guests is unsupported"
			) vm
end

module VBD = struct
	open Vbd

	let id_of vbd = snd vbd.id

	let attach_and_activate task xc xs frontend_domid vbd = function
		| None ->
			(* XXX: do something better with CDROMs *)
			{ Storage.domid = this_domid ~xs; params = "" }
		| Some (Local path) ->
			{ Storage.domid = this_domid ~xs; params = path }
		| Some (VDI path) ->
			let sr, vdi = Storage.get_disk_by_name task path in
			let dp = Storage.id_of frontend_domid vbd.id in
			Storage.attach_and_activate task dp sr vdi (vbd.mode = ReadWrite)

	let frontend_domid_of_device device = device.Device_common.frontend.Device_common.domid

	let deactivate_and_detach task device vbd =
		let dp = Storage.id_of (frontend_domid_of_device device) vbd.id in
		Storage.deactivate_and_detach task dp

	let device_number_of_device d =
		Device_number.of_xenstore_key d.Device_common.frontend.Device_common.devid

	let plug task vm vbd =
		on_frontend
			(fun xc xs frontend_domid hvm ->
				let vdi = attach_and_activate task xc xs frontend_domid vbd vbd.backend in
				(* Remember the VBD id with the device *)
				let id = _device_id Device_common.Vbd, id_of vbd in
				let x = {
					Device.Vbd.mode = (match vbd.mode with 
						| ReadOnly -> Device.Vbd.ReadOnly 
						| ReadWrite -> Device.Vbd.ReadWrite
					);
					device_number = vbd.position;
					phystype = Device.Vbd.Phys;
					params = vdi.Storage.params;
					dev_type = (match vbd.ty with
						| CDROM -> Device.Vbd.CDROM
						| Disk -> Device.Vbd.Disk
					);
					unpluggable = vbd.unpluggable;
					protocol = None;
					extra_backend_keys = vbd.extra_backend_keys;
					extra_private_keys = id :: vbd.extra_private_keys;
					backend_domid = vdi.Storage.domid
				} in
				(* Store the VBD ID -> actual frontend ID for unplug *)
				let (_: Device_common.device) =
					Xenops_task.with_subtask task (Printf.sprintf "Vbd.add %s" (id_of vbd))
						(fun () -> Device.Vbd.add ~xs ~hvm x frontend_domid) in
				()
			) vm

	let unplug task vm vbd =
		with_xc_and_xs
			(fun xc xs ->
				try
					(* If the device is gone then this is ok *)
					let device = device_by_id xc xs vm Device_common.Vbd (id_of vbd) in
					Xenops_task.with_subtask task (Printf.sprintf "Vbd.clean_shutdown %s" (id_of vbd))
						(fun () -> Device.clean_shutdown ~xs device);
					Xenops_task.with_subtask task (Printf.sprintf "Vbd.release %s" (id_of vbd))
						(fun () -> Device.Vbd.release ~xs device);
					deactivate_and_detach task device vbd;
				with (Exception Does_not_exist) ->
					debug "Ignoring missing device: %s" (id_of vbd)
			)

	let insert task vm vbd disk =
		with_xc_and_xs
			(fun xc xs ->
				let (device: Device_common.device) = device_by_id xc xs vm Device_common.Vbd (id_of vbd) in
				let frontend_domid = frontend_domid_of_device device in
				let vdi = attach_and_activate task xc xs frontend_domid vbd (Some disk) in
				let device_number = device_number_of_device device in
				let phystype = Device.Vbd.Phys in
				Device.Vbd.media_insert ~xs ~device_number ~params:vdi.Storage.params ~phystype frontend_domid
			)

	let eject task vm vbd =
		with_xc_and_xs
			(fun xc xs ->
				let (device: Device_common.device) = device_by_id xc xs vm Device_common.Vbd (id_of vbd) in
				let frontend_domid = frontend_domid_of_device device in
				let device_number = device_number_of_device device in
				Device.Vbd.media_eject ~xs ~device_number frontend_domid;
				deactivate_and_detach task device vbd;
			)

	let get_state vm vbd =
		with_xc_and_xs
			(fun xc xs ->
				try
					let (device: Device_common.device) = device_by_id xc xs vm Device_common.Vbd (id_of vbd) in
					let path = Device_common.kthread_pid_path_of_device ~xs device in
					let kthread_pid = try xs.Xs.read path |> int_of_string with _ -> 0 in
					let plugged = Hotplug.device_is_online ~xs device in
					let device_number = device_number_of_device device in
					let domid = device.Device_common.frontend.Device_common.domid in
					let ejected = Device.Vbd.media_is_ejected ~xs ~device_number domid in
					{
						Vbd.plugged = plugged;
						media_present = not ejected;
						kthread_pid = kthread_pid
					}
				with
					| Exception Does_not_exist
					| Exception Device_not_connected ->
						unplugged_vbd
			)

	let get_device_action_request vm vbd =
		with_xc_and_xs
			(fun xc xs ->
				let (device: Device_common.device) = device_by_id xc xs vm Device_common.Vbd (id_of vbd) in
				if Hotplug.device_is_online ~xs device
				then None
				else Some Needs_unplug
			)
end

module VIF = struct
	open Vif

	let id_of vif = snd vif.id

	let backend_domid_of xc xs vif =
		match vif.backend with
			| Bridge _
			| VSwitch _ -> this_domid ~xs
			| Netback (vm, _) -> vm |> Uuid.uuid_of_string |> domid_of_uuid ~xc ~xs |> unbox

	let plug_exn task vm vif =
		on_frontend
			(fun xc xs frontend_domid hvm ->
				let backend_domid = backend_domid_of xc xs vif in
				(* Remember the VIF id with the device *)
				let id = _device_id Device_common.Vif, id_of vif in

				let (_: Device_common.device) =
					Xenops_task.with_subtask task (Printf.sprintf "Vif.add %s" (id_of vif))
						(fun () ->
							Device.Vif.add ~xs ~devid:vif.position
								~netty:(match vif.backend with
									| VSwitch x -> Netman.Vswitch x
									| Bridge x -> Netman.Bridge x
									| Netback (_, _) -> failwith "Unsupported")
								~mac:vif.mac ~carrier:vif.carrier ~mtu:vif.mtu
								~rate:vif.rate ~backend_domid
								~other_config:vif.other_config
								~extra_private_keys:(id :: vif.extra_private_keys)
								frontend_domid) in
				()
			) vm

	let plug task vm = plug_exn task vm

	let unplug_exn task vm vif =
		with_xc_and_xs
			(fun xc xs ->
				try
					(* If the device is gone then this is ok *)
					let device = device_by_id xc xs vm Device_common.Vif (id_of vif) in
					(* NB different from the VBD case to make the test pass for now *)
					Xenops_task.with_subtask task (Printf.sprintf "Vif.hard_shutdown %s" (id_of vif))
						(fun () -> Device.hard_shutdown ~xs device);
					Xenops_task.with_subtask task (Printf.sprintf "Vif.release %s" (id_of vif))
						(fun () -> Device.Vif.release ~xs device);
				with (Exception Does_not_exist) ->
					debug "Ignoring missing device: %s" (id_of vif)
			);
		()

	let unplug task vm = unplug_exn task vm

	let get_state vm vif =
		with_xc_and_xs
			(fun xc xs ->
				try
					let (d: Device_common.device) = device_by_id xc xs vm Device_common.Vif (id_of vif) in
					let path = Device_common.kthread_pid_path_of_device ~xs d in
					let kthread_pid = try xs.Xs.read path |> int_of_string with _ -> 0 in
					let plugged = Hotplug.device_is_online ~xs d in
					{
						Vif.plugged = plugged;
						media_present = plugged;
						kthread_pid = kthread_pid
					}
				with
					| Exception Does_not_exist
					| Exception Device_not_connected ->
						unplugged_vif
			)

	let get_device_action_request vm vif =
		with_xc_and_xs
			(fun xc xs ->
				let (device: Device_common.device) = device_by_id xc xs vm Device_common.Vif (id_of vif) in
				if Hotplug.device_is_online ~xs device
				then None
				else Some Needs_unplug
			)

end

module UPDATES = struct
	let get last timeout = Updates.get last timeout updates
end

let _introduceDomain = "@introduceDomain"
let _releaseDomain = "@releaseDomain"

module IntMap = Map.Make(struct type t = int let compare = compare end)
module IntSet = Set.Make(struct type t = int let compare = compare end)

let list_domains xc =
	let dis = Xenctrl.domain_getinfolist xc 0 in
	let ids = List.map (fun x -> x.Xenctrl.domid) dis in
	List.fold_left (fun map (k, v) -> IntMap.add k v map) IntMap.empty (List.combine ids dis)


let domain_looks_different a b = match a, b with
	| None, Some _ -> true
	| Some _, None -> true
	| None, None -> false
	| Some a', Some b' ->
		a'.Xenctrl.shutdown <> b'.Xenctrl.shutdown
		|| (a'.Xenctrl.shutdown && b'.Xenctrl.shutdown && (a'.Xenctrl.shutdown_code <> b'.Xenctrl.shutdown_code))

let list_different_domains a b =
	let c = IntMap.merge (fun _ a b -> if domain_looks_different a b then Some () else None) a b in
	List.map fst (IntMap.bindings c)

let all_domU_watches domid uuid =
	let open Printf in [
		sprintf "/local/domain/%d/data/updated" domid;
		sprintf "/local/domain/%d/memory/target" domid;
		sprintf "/local/domain/%d/memory/uncooperative" domid;
		sprintf "/local/domain/%d/console/vnc-port" domid;
		sprintf "/local/domain/%d/console/tc-port" domid;
		sprintf "/local/domain/%d/device" domid;
		sprintf "/vm/%s/rtc/timeoffset" uuid;
	]

let watches_of_device device =
	let interesting_backend_keys = [
		"kthread-pid";
		"tapdisk-pid";
		"shutdown-done";
		"params";
	] in
	let open Device_common in
	let be = device.backend.domid in
	let fe = device.frontend.domid in
	let kind = string_of_kind device.backend.kind in
	let devid = device.frontend.devid in
	List.map (fun k -> Printf.sprintf "/local/domain/%d/backend/%s/%d/%d/%s" be kind fe devid k) interesting_backend_keys

let watch_xenstore () =
	with_xc_and_xs
		(fun xc xs ->
			let domains = ref IntMap.empty in
			let watches = ref IntMap.empty in

			let add_domU_watches xs domid uuid =
				debug "Adding watches for: domid %d" domid;
				List.iter (fun p -> xs.Xs.watch p p) (all_domU_watches domid uuid);
				watches := IntMap.add domid [] !watches in
			let remove_domU_watches xs domid uuid =
				debug "Removing watches for: domid %d" domid;
				List.iter (fun p -> xs.Xs.unwatch p p) (all_domU_watches domid uuid);
				IntMap.iter (fun _ ds ->
					List.iter (fun d ->
						List.iter (fun p -> xs.Xs.unwatch p p) (watches_of_device d)
					) ds
				) !watches;

				watches := IntMap.remove domid !watches in

			let add_device_watch xs device =
				let open Device_common in
				debug "Adding watches for: %s" (string_of_device device);
				let domid = device.frontend.domid in
				List.iter (fun p -> xs.Xs.watch p p) (watches_of_device device);
				watches := IntMap.add domid (device :: (IntMap.find domid !watches)) !watches in

			let remove_device_watch xs device =
				let open Device_common in
				debug "Removing watches for: %s" (string_of_device device);
				let domid = device.frontend.domid in
				let current = IntMap.find domid !watches in
				List.iter (fun p -> xs.Xs.unwatch p p) (watches_of_device device);
				watches := IntMap.add domid (List.filter (fun x -> x <> device) current) !watches in

			let look_for_different_domains () =
				let domains' = list_domains xc in
				let different = list_different_domains !domains domains' in
				List.iter
					(fun domid ->
						debug "Domain %d may have changed state" domid;
						(* The uuid is either in the new domains map or the old map. *)
						let di = IntMap.find domid (if IntMap.mem domid domains' then domains' else !domains) in
						let id = Uuid.uuid_of_int_array di.Xenctrl.handle |> Uuid.string_of_uuid in
						if not (DB.exists [ id ])
						then debug "However domain %d is not managed by us: ignoring" domid
						else begin
							Updates.add (Dynamic.Vm id) updates;
							(* A domain is 'running' if we know it has not shutdown *)
							let running = IntMap.mem domid domains' && (not (IntMap.find domid domains').Xenctrl.shutdown) in
							match IntMap.mem domid !watches, running with
								| true, true -> () (* still running, nothing to do *)
								| false, false -> () (* still offline, nothing to do *)
								| false, true ->
									add_domU_watches xs domid id
								| true, false ->
									remove_domU_watches xs domid id
						end
					) different;
				domains := domains' in

			let look_for_different_devices domid =
				if not(IntMap.mem domid !watches)
				then debug "Ignoring frontend device watch on unmanaged domain: %d" domid
				else begin
					let devices = IntMap.find domid !watches in
					let devices' = Device_common.list_frontends ~xs domid in
					let old_devices = Listext.List.set_difference devices devices' in
					let new_devices = Listext.List.set_difference devices' devices in
					List.iter (add_device_watch xs) new_devices;
					List.iter (remove_device_watch xs) old_devices;
				end in

			xs.Xs.watch _introduceDomain "";
			xs.Xs.watch _releaseDomain "";
			look_for_different_domains ();

			let fire_event_on_vm domid =
				let d = int_of_string domid in
				if not(IntMap.mem d !domains)
				then debug "Ignoring watch on shutdown domain %d" d
				else
					let di = IntMap.find d !domains in
					let id = Uuid.uuid_of_int_array di.Xenctrl.handle |> Uuid.string_of_uuid in
					Updates.add (Dynamic.Vm id) updates in

			let fire_event_on_device domid kind devid =
				let d = int_of_string domid in
				if not(IntMap.mem d !domains)
				then debug "Ignoring watch on shutdown domain %d" d
				else
					let di = IntMap.find d !domains in
					let id = Uuid.uuid_of_int_array di.Xenctrl.handle |> Uuid.string_of_uuid in
					let update = match kind with
						| "vbd" ->
							let devid' = devid |> int_of_string |> Device_number.of_xenstore_key |> Device_number.to_linux_device in
							Some (Dynamic.Vbd (id, devid'))
						| "vif" -> Some (Dynamic.Vif (id, devid))
						| x ->
							debug "Unknown device kind: '%s'" x;
							None in
					Opt.iter (fun x -> Updates.add x updates) update in

			while true do
				let path, _ =
					if Xs.has_watchevents xs
					then Xs.get_watchevent xs
					else Xs.read_watchevent xs in
				if path = _introduceDomain || path = _releaseDomain
				then look_for_different_domains ()
				else match List.filter (fun x -> x <> "") (String.split '/' path) with
					| "local" :: "domain" :: domid :: "backend" :: kind :: frontend :: devid :: _ ->
						debug "Watch on backend %s %s -> %s.%s" domid kind frontend devid;
						fire_event_on_device frontend kind devid
					| "local" :: "domain" :: frontend :: "device" :: _ ->
						look_for_different_devices (int_of_string frontend)
					| "local" :: "domain" :: domid :: _ ->
						fire_event_on_vm domid
					| "vm" :: uuid :: _ ->
						Updates.add (Dynamic.Vm uuid) updates
					| _  -> debug "Ignoring unexpected watch: %s" path
			done
		)

let init () =
	let (_: Thread.t) = Thread.create
		(fun () ->
			try
				Debug.with_thread_associated "xenstore" watch_xenstore ();
				debug "watch_xenstore thread exitted"
			with e ->
				debug "watch_xenstore thread raised: %s" (Printexc.to_string e)
		) () in
	()

module DEBUG = struct
	let trigger cmd args = match cmd, args with
		| "reboot", [ k ] ->
			let uuid = Uuid.uuid_of_string k in
			with_xc_and_xs
				(fun xc xs ->
					match di_of_uuid ~xc ~xs uuid with
						| None -> raise (Exception Does_not_exist)			
						| Some di ->
							Xenctrl.domain_shutdown xc di.Xenctrl.domid Xenctrl.Reboot
				)
		| "halt", [ k ] ->
			let uuid = Uuid.uuid_of_string k in
			with_xc_and_xs
				(fun xc xs ->
					match di_of_uuid ~xc ~xs uuid with
						| None -> raise (Exception Does_not_exist)			
						| Some di ->
							Xenctrl.domain_shutdown xc di.Xenctrl.domid Xenctrl.Halt
				)
		| _ ->
			debug "DEBUG.trigger cmd=%s Not_supported" cmd;
			raise (Exception Not_supported)
end
