(** Functions relating to Xen domains *)

open Printf
open Stringext
open Listext
open Pervasiveext

open Device_common

module D = Debug.Debugger(struct let name = "xenops" end)
open D

type build_hvm_info = {
	pae: bool;
	apic: bool;
	acpi: bool;
	nx: bool;
	viridian: bool;
	shadow_multiplier: float;
	timeoffset: string;
}

type build_pv_info = {
	cmdline: string;
	ramdisk: string option;
}

type builder_spec_info = BuildHVM of build_hvm_info | BuildPV of build_pv_info

type build_info = {
	memory_max: int64;    (* memory max in kilobytes *)
	memory_target: int64; (* memory target in kilobytes *)
	kernel: string;       (* in hvm case, point to hvmloader *)
	vcpus: int;           (* vcpus max *)
	priv: builder_spec_info;
}

type domid = int

exception Restore_signature_mismatch
exception Domain_build_failed
exception Domain_restore_failed
exception Domain_restore_truncated_hvmstate
exception Xenguest_protocol_failure of string (* internal protocol failure *)
exception Xenguest_failure of string (* an actual error is reported to us *)
exception Timeout_backend
exception Could_not_read_file of string (* eg linux kernel/ initrd *)
exception Domain_stuck_in_dying_state of Xc.domid

let save_signature = "XenSavedDomain\n"
let qemu_save_signature = "QemuDeviceModelRecord\n"
let hvmloader = "/usr/lib/xen/boot/hvmloader"
let releaseDomain = "@releaseDomain"
let introduceDomain = "@introduceDomain"

let log_exn_continue msg f x = try f x with e -> debug "Ignoring exception: %s while %s" (Printexc.to_string e) msg

let log_exn_rm ~xs x = log_exn_continue ("xenstore-rm " ^ x) xs.Xs.rm x

let set_difference a b = List.filter (fun x -> not(List.mem x b)) a

let assert_file_is_readable filename = 
	try Unix.access filename [ Unix.F_OK; Unix.R_OK ]
	with _ -> raise (Could_not_read_file filename)
let maybe f = function None -> () | Some x -> f x

type domarch = Arch_HVM | Arch_native | Arch_X64 | Arch_X32

let string_of_domarch = function
	| Arch_HVM    -> "hvm"
	| Arch_native -> ""
	| Arch_X64    -> "x64"
	| Arch_X32    -> "x32"

let domarch_of_string = function
	| "hvm" -> Arch_HVM
	| "x64" -> Arch_X64
	| "x32" -> Arch_X32
	| _     -> Arch_native


let make ~xc ~xs ~hvm ?(name="") ?(xsdata=[]) ?(platformdata=[]) uuid =
	let ssidref = 0l in

	let flags = if hvm then [ Xc.CDF_HVM; Xc.CDF_HAP ] else [] in
	let domid = Xc.domain_create xc ssidref flags uuid in
	let name = if name <> "" then name else sprintf "Domain-%d" domid in
	try

		let dom_path = xs.Xs.getdomainpath domid in
		let vm_path = "/vm/" ^ (Uuid.to_string uuid) in
		let vss_path = "/vss/" ^ (Uuid.to_string uuid) in
		let roperm = Xenbus.roperm_for_guest domid in
		let rwperm = Xenbus.rwperm_for_guest domid in
		debug "Regenerating the xenstored tree under: [%s]" dom_path;

		Xs.transaction xs (fun t ->
			(* Clear any existing rubbish in xenstored *)
			t.Xst.rm dom_path;
			t.Xst.mkdir dom_path;
			t.Xst.setperms dom_path roperm;

			t.Xst.rm vm_path;
			t.Xst.mkdir vm_path;
			t.Xst.setperms vm_path roperm;

			t.Xst.rm vss_path;
			t.Xst.mkdir vss_path;
			t.Xst.setperms vss_path rwperm;

			t.Xst.write (dom_path ^ "/vm") vm_path;
			t.Xst.write (dom_path ^ "/vss") vss_path;
			t.Xst.write (dom_path ^ "/name") name;

			(* create cpu and memory directory with read only perms *)
			List.iter (fun dir ->
				let ent = sprintf "%s/%s" dom_path dir in
				t.Xst.mkdir ent;
				t.Xst.setperms ent roperm
			) [ "cpu"; "memory" ];
			(* create read/write nodes for the guest to use *)
			List.iter (fun dir ->
				let ent = sprintf "%s/%s" dom_path dir in
				t.Xst.mkdir ent;
				t.Xst.setperms ent rwperm
			) [ "device"; "error"; "drivers"; "control"; "attr"; "data"; "messages" ];
		);

		xs.Xs.writev vm_path [
			"uuid", (Uuid.to_string uuid);
			"name", name;
		];

		xs.Xs.writev dom_path xsdata;
		xs.Xs.writev dom_path (List.map (fun (k,v) ->
			("platform/" ^ k, v)) platformdata);

		xs.Xs.write (dom_path ^ "/control/platform-feature-multiprocessor-suspend") "1";

		debug "Created domain with id: %d" domid;
		domid
	with e ->
		debug "Caught exception in domid %d creation: %s" domid (Printexc.to_string e);
		raise e

type shutdown_reason = PowerOff | Reboot | Suspend | Crash | Halt | Unknown of int

(** Strings suitable for putting in the control/shutdown xenstore entry *)
let string_of_shutdown_reason = function
	| PowerOff -> "poweroff"
	| Reboot   -> "reboot"
	| Suspend  -> "suspend"
        | Crash    -> "crash" (* this one makes no sense to send to a guest *)
	| Halt     -> "halt"
	| Unknown x -> sprintf "(unknown %d)" x (* or this one *)

(** Decode the shutdown_reason contained within the dominfo struct *)
let shutdown_reason_of_int = function
	| 0 -> PowerOff
	| 1 -> Reboot
	| 2 -> Suspend
	| 3 -> Crash
	| 4 -> Halt
	| x -> Unknown x

let shutdown_to_xc_shutdown = function
	| PowerOff -> Xc.Poweroff
	| Reboot   -> Xc.Reboot
	| Suspend  -> Xc.Suspend
	| Crash    -> Xc.Crash
	| Halt     -> Xc.Halt
	| Unknown _-> raise (Invalid_argument "unknown")

(** Immediately change the domain state to shutdown *)
let hard_shutdown ~xc domid req = 
	Xc.domain_shutdown xc domid (shutdown_to_xc_shutdown req)

(** Return the path in xenstore watched by the PV shutdown driver *)
let control_shutdown ~xs domid = xs.Xs.getdomainpath domid ^ "/control/shutdown"

(** Request a shutdown, return without waiting for acknowledgement *)
let shutdown ~xs domid req =
	debug "Requesting shutdown of domain %d" domid;
	let reason = string_of_shutdown_reason req in
	xs.Xs.write (control_shutdown ~xs domid) reason

(** PV domains will acknowledge the request by deleting the node from the
    store, block until this happens. *)
let shutdown_wait_for_ack ?timeout ~xs domid req =
	debug "Waiting for PV domain %d to acknowledge shutdown request" domid;
	let path = control_shutdown ~xs domid in
	try
	  Watch.wait_for ~xs ?timeout (Watch.value_to_become path "");
	  debug "Domain acknowledged shutdown request";
	  true
	with Watch.Timeout _ ->
	  debug "Timed-out waiting for domain to acknowledge shutdown request";
	  false


let shutdown_ack ?(timeout=60.) ~xc ~xs domid req =
	(* For both PV and HVM, write the control/shutdown node *)
	shutdown ~xs domid req;
	(* PV domains will acknowledge the request (if not then something
	   very bad is wrong) *)
	if not((Xc.domain_getinfo xc domid).Xc.hvm_guest)
	then shutdown_wait_for_ack ~timeout ~xs domid req
	else begin
	  (* If HVM domain has no PV drivers, we shut it down here *)
	  if not(Xc.hvm_check_pvdriver xc domid)
	  then Xc.domain_shutdown xc domid (shutdown_to_xc_shutdown req);
	  (* If HVM domain has PV drivers, it shuts itself down but it
	     doesn't remove the control/shutdown node. *)
	  true
	end

let sysrq ~xs domid key =
	let path = xs.Xs.getdomainpath domid ^ "/control/sysrq" in
	xs.Xs.write path (String.make 1 key)

(** Forcibly shuts down all VBD backends in parallel and returns when they have all
    reported successful flushing.
    extra_debug_paths is a list of xenstore paths which will also be watched
    for manually checking the migrate synchronisation code.
 *)
let hard_shutdown_all_vbds ~xc ~xs ?(extra_debug_paths = []) (devices: device list) = 
	(* Tell them all to flush now *)
	List.iter (Device.Vbd.hard_shutdown_request ~xs) devices;
	(* If requested we watch additional debugging paths: *)
	let debug_watches = List.map Watch.value_to_appear extra_debug_paths in
	(* Wait for them all to acknowledge *)
	try
	  let watches = List.map (Device.Vbd.hard_shutdown_complete ~xs) devices in
	  ignore(Watch.wait_for ~xs (Watch.all_of (watches @ debug_watches)));
	  debug "VBD backends have flushed"
	with Watch.Timeout _ ->
	  debug "Timeout waiting for backends to flush";
	  raise Timeout_backend
	
let destroy ?(preserve_xs_vm=false) ~xc ~xs domid =
	let dom_path = xs.Xs.getdomainpath domid in

	let all_devices = list_devices_between ~xs 0 domid in
	debug "Domain.destroy: all known devices = [ %a ]" (fun () -> String.concat "; ")
          (List.map string_of_device all_devices);

	(* Now we should kill the domain itself *)
	debug "Domain.destroy calling Xc.domain_destroy (domid %d)" domid;
	log_exn_continue "Xc.domain_destroy" (Xc.domain_destroy xc) domid;

	log_exn_continue "Error stoping device-model, already dead ?"
	                 (fun () -> Device.Dm.stop ~xs domid) ();

	(* Forcibly shutdown every backend *)
	List.iter 
	  (fun device ->
	     try
	       Device.hard_shutdown ~xs device
	     with e ->
	       (* If this fails we may have a resource leak. We should prevent
		  this from happening! *)
	       debug "Caught exception %s while destroying device %s"
		 (Printexc.to_string e) (string_of_device device);
	       (* Keep going on a best-effort basis *)
	       ) all_devices;

	(* For each device which has a hotplug entry, perform the cleanup. Even if one
	   fails, try to cleanup the rest anyway.*)
	let released = ref [] in
	List.iter (fun x ->
		log_exn_continue ("waiting for hotplug for " ^ (string_of_device x))
		                 (fun () ->
			Hotplug.release ~xs x; released := x :: !released
		                 ) ()
		) all_devices;

	(* If we fail to release a device we leak resources. If we are to tolerate this
	   then we need an async cleanup thread. *)
	let failed_devices = List.filter (fun x -> not(List.mem x !released)) all_devices in
	List.iter (fun dev ->
		error "Domain.destroy failed to release device: %s"
		      (string_of_device dev)) failed_devices;

	(* Delete the /vm/<uuid> and /vss/<uuid> directories if they exists *)
	if not preserve_xs_vm then (
		begin try xs.Xs.rm (xs.Xs.read (dom_path ^ "/vm")) with _ -> () end;
		begin try xs.Xs.rm (xs.Xs.read (dom_path ^ "/vss")) with _ -> () end;
	);

	(* Delete the /local/domain/<domid> and all the backend device paths *)
	debug "Domain.destroy: rm %s" dom_path;
	xs.Xs.rm dom_path;
	debug "Domain.destroy: deleting backend paths";
	let backend_path = xs.Xs.getdomainpath 0 ^ "/backend" in
	let all_backend_types = try xs.Xs.directory backend_path with _ -> [] in
	List.iter (fun ty -> log_exn_rm ~xs (Printf.sprintf "%s/%s/%d" backend_path ty domid)) all_backend_types;

	(* If all devices were properly un-hotplugged, then zap the tree in xenstore.
	   If there was some error leave the tree for debugging / async cleanup. *)
	if failed_devices = []
	then log_exn_rm ~xs (Hotplug.get_private_path domid);

	(* Block waiting for the dying domain to disappear: aim is to catch shutdown errors early*)
	let still_exists () = 
	  try
	    let info = Xc.domain_getinfo xc domid in
	    debug "Domain %d still exists (domid=%d; uuid=%s): waiting for it to disappear." domid info.Xc.domid (Uuid.to_string (Uuid.uuid_of_int_array info.Xc.handle));
	    true
	  with 
	  | Xc.Error err ->
	      debug "Xc.domain_getinfo %d threw: %s -- assuming domain nolonger exists" domid err;
	      false
	  | e ->
	      warn "Xc.domain_getinfo %d threw unexpected error: %s -- assuming domain nolonger exists" domid (Printexc.to_string e);
	      raise e in
	let start = Unix.gettimeofday () in
	let timeout = 30. in
	while still_exists () && (Unix.gettimeofday () -. start < timeout) do
	  Thread.delay 5.
	done;
	if still_exists () then begin
	  (* CA-13801: to avoid confusing people, we shall change this domain's uuid *)
	  let s = Printf.sprintf "deadbeef-dead-beef-dead-beef0000%04x" domid in
	  warn "Domain stuck in dying state after 30s; resetting UUID to %s" s;
	  Xc.domain_sethandle xc domid (Uuid.of_string s);
	  raise (Domain_stuck_in_dying_state domid)
	end


let pause ~xc domid =
	Xc.domain_pause xc domid

let unpause ~xc domid =
	Xc.domain_unpause xc domid

(** create store and console channels *)
let create_channels ~xc domid =
	let store = Xc.evtchn_alloc_unbound xc domid 0 in
	let console = Xc.evtchn_alloc_unbound xc domid 0 in
	store, console

(* pre build *)
let build_pre ~xc ~xs ~vcpus ~mem_max_kib ~shadow_kib domid =
	let shadow_mib = Int64.to_int (Int64.div shadow_kib 1024L) in
	debug "build_pre domid=%d; mem=%Lu KiB; shadow=%Lu KiB (%d MiB)"
	      domid mem_max_kib shadow_kib shadow_mib;
	let dom_path = xs.Xs.getdomainpath domid in
	let use_vmxassist =
	  try bool_of_string (xs.Xs.read (dom_path ^ "/platform/vmxassist"))
	  with _ -> false in
	Xc.domain_setvmxassist xc domid use_vmxassist;
	Xc.domain_max_vcpus xc domid vcpus;
	Xc.domain_setmaxmem xc domid mem_max_kib;
	Xc.domain_set_memmap_limit xc domid mem_max_kib;
	Xc.shadow_allocation_set xc domid shadow_mib;
	create_channels ~xc domid

let resume_post ~xc ~xs domid =
	let dom_path = xs.Xs.getdomainpath domid in
	let store_mfn_s = xs.Xs.read (dom_path ^ "/store/ring-ref") in
	let store_mfn = Nativeint.of_string store_mfn_s in
	let store_port = int_of_string (xs.Xs.read (dom_path ^ "/store/port")) in
	xs.Xs.introduce domid store_mfn store_port

(* puts value in store after the domain build succeed *)
let build_post ~xc ~xs ~vcpus ~mem_target_kib ~mem_max_kib domid
               store_mfn store_port ents vments =
	let dom_path = xs.Xs.getdomainpath domid in
	(* expand local stuff with common values *)
	let ents =
		[ ("memory/static-max", Int64.to_string mem_max_kib);
		  ("memory/target", Int64.to_string mem_target_kib);
		  ("domid", string_of_int domid);
		  ("store/port", string_of_int store_port);
		  ("store/ring-ref", sprintf "%nu" store_mfn);
		] @ ents in
	Xs.transaction xs (fun t -> t.Xst.writev dom_path ents);
	if vments <> [] then (
		let vm_path = xs.Xs.read (dom_path ^ "/vm") in
		Xs.transaction xs (fun t -> t.Xst.writev vm_path vments)
	);
	xs.Xs.introduce domid store_mfn store_port

(** build a linux type of domain *)
let build_linux ~xc ~xs ~mem_max_kib ~mem_target_kib ~kernel ~cmdline ~ramdisk ~vcpus domid =
	assert_file_is_readable kernel;
	maybe assert_file_is_readable ramdisk;

	let mem_max_kib' = Memory.Linux.required_available mem_max_kib in

	let store_port, console_port =
		build_pre ~xc ~xs ~mem_max_kib:mem_max_kib' ~shadow_kib:0L ~vcpus domid in

	let mem_target_mib = (Int64.to_int (Int64.div mem_target_kib 1024L)) in
	let cnx = XenguestHelper.connect
	  [
	    "-mode"; "linux_build";
	    "-domid"; string_of_int domid;
	    "-memsize"; string_of_int mem_target_mib;
	    "-image"; kernel;
	    "-ramdisk"; (match ramdisk with Some x -> x | None -> "");
	    "-cmdline"; cmdline;
	    "-features"; "";
	    "-flags"; "0";
	    "-store_port"; string_of_int store_port;
	    "-console_port"; string_of_int console_port;
	    "-fork"; "true";
	  ] [] in
	let line = finally
	  (fun () -> XenguestHelper.receive_success cnx)
	  (fun () -> XenguestHelper.disconnect cnx) in

	debug "Read [%s]" line;
	let store_mfn, console_mfn, protocol =
		match String.split ' ' line with
		| [ store_mfn; console_mfn; protocol ] ->
		    Nativeint.of_string store_mfn, Nativeint.of_string console_mfn, protocol
		| _ ->
		    raise Domain_build_failed in

	let local_stuff = [
		"serial/0/limit",    string_of_int 65536;
		"console/port",      string_of_int console_port;
		"console/ring-ref",  sprintf "%nu" console_mfn;
	] in
	build_post ~xc ~xs ~vcpus ~mem_target_kib ~mem_max_kib domid store_mfn store_port local_stuff [];
	match protocol with
	| "x86_32-abi" -> Arch_X32
	| "x86_64-abi" -> Arch_X64
	| _            -> Arch_native

(** build hvm type of domain *)
let build_hvm ~xc ~xs ~mem_max_kib ~mem_target_kib ~shadow_multiplier ~vcpus
              ~kernel ~pae ~apic ~acpi ~nx ~viridian ~timeoffset domid =
	assert_file_is_readable kernel;

	(* NB we reserve a little extra *)
	let mem_max_kib' = Memory.HVM.required_available mem_max_kib
	and shadow_kib = Memory.HVM.required_shadow vcpus mem_max_kib shadow_multiplier in
	(* HVM must have at least 1MiB of shadow *)
	let shadow_kib = max 1024L shadow_kib in

	let store_port, console_port =
		build_pre ~xc ~xs ~mem_max_kib:mem_max_kib' ~shadow_kib ~vcpus domid in

	let mem_max_mib = (Int64.to_int (Int64.div mem_max_kib 1024L)) in

	let cnx = XenguestHelper.connect
	  [
	    "-mode"; "hvm_build";
	    "-domid"; string_of_int domid;
	    "-store_port"; string_of_int store_port;
	    "-image"; kernel;
	    "-memsize"; string_of_int mem_max_mib;
	    "-vcpus"; string_of_int vcpus;
	    "-pae"; string_of_bool pae;
	    "-apic"; string_of_bool apic;
	    "-acpi"; string_of_bool acpi;
	    "-nx"; string_of_bool nx;
	    "-viridian"; string_of_bool viridian;
	    "-fork"; "true";
	  ] [] in
	let line = finally
	  (fun () -> XenguestHelper.receive_success cnx)
	  (fun () -> XenguestHelper.disconnect cnx) in

	(* XXX: domain builder will reduce our shadow allocation under our feet.
	   Detect this and override. *)
	let requested_shadow_mib = Int64.to_int (Int64.div shadow_kib 1024L) in
	let actual_shadow_mib = Xc.shadow_allocation_get xc domid in
	if actual_shadow_mib < requested_shadow_mib then begin
	  warn "HVM domain builder reduced our shadow memory from %d to %d MiB; reverting" 
	    requested_shadow_mib actual_shadow_mib;
	  Xc.shadow_allocation_set xc domid requested_shadow_mib;
	  let shadow = Xc.shadow_allocation_get xc domid in
	  debug "Domain now has %d MiB of shadow" shadow;
	end;

	debug "Read [%s]" line;
	let store_mfn =
		try Nativeint.of_string line
		with _ -> raise Domain_build_failed in
	let vm_stuff = [
		"rtc/timeoffset",    timeoffset;
	] in

	build_post ~xc ~xs ~vcpus ~mem_target_kib ~mem_max_kib domid store_mfn store_port [] vm_stuff;
	Arch_HVM

let build ~xc ~xs info domid =
	match info.priv with
	| BuildHVM hvminfo ->
		build_hvm ~xc ~xs ~mem_max_kib:info.memory_max ~mem_target_kib:info.memory_target
		          ~shadow_multiplier:hvminfo.shadow_multiplier ~vcpus:info.vcpus
		          ~kernel:info.kernel ~pae:hvminfo.pae ~apic:hvminfo.apic ~acpi:hvminfo.acpi
		          ~nx:hvminfo.nx ~viridian:hvminfo.viridian ~timeoffset:hvminfo.timeoffset domid
	| BuildPV pvinfo   ->
		build_linux ~xc ~xs ~mem_max_kib:info.memory_max ~mem_target_kib:info.memory_target
		            ~kernel:info.kernel ~cmdline:pvinfo.cmdline ~ramdisk:pvinfo.ramdisk
		            ~vcpus:info.vcpus domid

(* restore a domain from a file descriptor. it read first the signature
 * to be we are not trying to restore from random data.
 * the linux_restore process is in charge to allocate memory as it's needed
 *)
let restore_common ~xc ~xs ~hvm ~store_port ~console_port ~vcpus ~extras domid fd =
	if Io.read fd (String.length save_signature) <> save_signature then
		raise Restore_signature_mismatch;

	Unix.clear_close_on_exec fd;
	let cnx = XenguestHelper.connect
	  ([
	    "-mode"; if hvm then "hvm_restore" else "restore";
	    "-domid"; string_of_int domid;
	    "-fd"; string_of_int (Obj.magic fd);
	    "-store_port"; string_of_int store_port;
	    "-console_port"; string_of_int console_port;
	    "-fork"; "true";
	  ] @ extras) [ fd ] in

	let line = finally
	  (fun () -> XenguestHelper.receive_success cnx)
	  (fun () -> XenguestHelper.disconnect cnx) in

	debug "Read [%s]" line;
	let store_mfn, console_mfn =
		match String.split_f String.isspace line with
		| [ store; console ] -> Nativeint.of_string store, Nativeint.of_string console
		| _                  -> raise Domain_restore_failed
		in

	if hvm then (
		(* restore qemu-dm tmp file *)
		if Io.read fd (String.length qemu_save_signature) <> qemu_save_signature then
			raise Restore_signature_mismatch;
		let limit = Int64.of_int (Io.read_int fd) in
		debug "qemu-dm state file size: %Ld" limit;

		let file = sprintf "/tmp/xen.qemu-dm.%d" domid in
		let fd2 = Unix.openfile file [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; ] 0o640 in
		finally (fun () ->
			if Unixext.copy_file ~limit fd fd2 <> limit then
				raise Domain_restore_truncated_hvmstate
		) (fun () -> Unix.close fd2);
	);
	store_mfn, console_mfn

let resume ~xc ~xs ~hvm ~cooperative domid =
	if not cooperative
	then failwith "Domain.resume works only for collaborative domains";
	Xc.domain_resume_fast xc domid;
	resume_post ~xc	~xs domid;
	if hvm then Device.Dm.resume ~xs domid

let restore ~xc ~xs ~mem_max_kib ~mem_target_kib ~vcpus domid fd =
	let mem_max_kib' = Memory.Linux.required_available mem_max_kib in

	let store_port, console_port =
	        build_pre ~xc ~xs ~mem_max_kib:mem_max_kib' ~shadow_kib:0L ~vcpus domid in

	let store_mfn, console_mfn = restore_common ~xc ~xs ~hvm:false
	                                            ~store_port ~console_port
	                                            ~vcpus ~extras:[] domid fd in
	let local_stuff = [
		"serial/0/limit",    string_of_int 65536;
		"console/port",     string_of_int console_port;
		"console/ring-ref", sprintf "%nu" console_mfn;
	] in
	build_post ~xc ~xs ~vcpus ~mem_target_kib ~mem_max_kib domid store_mfn store_port local_stuff []

let hvm_restore ~xc ~xs ~mem_max_kib ~mem_target_kib ~shadow_multiplier ~vcpus ~pae ~viridian ~timeoffset domid fd =
	let shadow_kib = Memory.HVM.required_shadow vcpus mem_max_kib shadow_multiplier
	and mem_max_kib' = Memory.HVM.required_available mem_max_kib in

	let store_port, console_port =
		build_pre ~xc ~xs ~mem_max_kib:mem_max_kib' ~shadow_kib ~vcpus domid in
	let extras = [
		"-pae"; string_of_bool pae;
		"-viridian"; string_of_bool viridian;
	] in

	let store_mfn, console_mfn = restore_common ~xc ~xs ~hvm:true
	                                            ~store_port ~console_port
	                                            ~vcpus ~extras domid fd in
	let vm_stuff = [
		"rtc/timeoffset",    timeoffset;
	] in
	(* and finish domain's building *)
	build_post ~xc ~xs ~vcpus ~mem_target_kib ~mem_max_kib domid store_mfn store_port [] vm_stuff

type suspend_flag = Live | Debug

(* suspend register the callback function that will be call by linux_save
 * and is in charge to suspend the domain when called. the whole domain
 * context is saved to fd
 *)
let suspend ~xc ~xs ~hvm domid fd flags ?(progress_callback = fun _ -> ()) do_suspend_callback =
	debug "Domain.suspend domid=%d" domid;
	Io.write fd save_signature;

	let cmdline_to_flag flag =
		match flag with
		| Live -> [ "-live"; "true" ]
		| Debug -> [ "-debug"; "true" ]
		in
	let flags' = List.map cmdline_to_flag flags in

	let xenguestargs = [
		"-fd"; string_of_int (Obj.magic fd);
		"-mode"; if hvm then "hvm_save" else "save";
		"-domid"; string_of_int domid;
		"-fork"; "true";
	] @ (List.concat flags') in

	let cnx = XenguestHelper.connect xenguestargs [ fd ] in
	finally (fun () ->
		debug "Blocking for suspend notification from xenguest";

		(* Monitor the debug (stderr) output of the xenguest helper and
		   spot the progress indicator *)
		let callback txt =
			let prefix = "\\b\\b\\b\\b" in
			if String.startswith prefix txt then
				let rest = String.sub txt (String.length prefix)
				                   (String.length txt - (String.length prefix)) in
				match String.split_f (fun x -> String.isspace x || x = '%') rest with
				| [ percent ] -> (
					try
						let percent = int_of_string percent in
						debug "Got progress: %d /100" percent;
						progress_callback (float_of_int percent /. 100.)
					with e -> debug "string_of_int or progress_callback fail [%s]" percent;
                                                  (* MTC: catch exception by progress_callback, for example, 
                                                     an abort request, and re-raise them *) 
                                                   raise e
					)
				| _ -> ()
			else
				debug "%s" txt
			in

		(match XenguestHelper.non_debug_receive ~debug_callback:callback cnx with
		 | XenguestHelper.Suspend -> debug "got suspend notification from xenguesthelper"
		 | XenguestHelper.Error x ->
		     error "Received error message from xenguesthelper: %s" x;
		     raise (Xenguest_failure (Printf.sprintf "Error while waiting for suspend notification: %s" x))
		 | msg ->
		     let err = Printf.sprintf "expected %s got %s"
		       (XenguestHelper.string_of_message XenguestHelper.Suspend)
		       (XenguestHelper.string_of_message msg) in
		     raise (Xenguest_protocol_failure err));
		do_suspend_callback ();
		if hvm then (
			debug "Suspending qemu-dm for domid %d" domid;
			Device.Dm.suspend ~xs domid;
		);
 		XenguestHelper.send cnx "done\n";

		let msg = XenguestHelper.non_debug_receive cnx in
		progress_callback 1.;
		match msg with
		| XenguestHelper.Result x -> debug "Final result: %s" x
		| XenguestHelper.Error x  ->
		    error "Received error message from xenguesthelper: %s" x;
		    raise (Xenguest_failure (Printf.sprintf "Received error from xenguesthelper: %s" x))
		| _                       ->
			debug "Unknown final result from xenguesthelper"
	) (fun () -> XenguestHelper.disconnect cnx);

	(* hvm domain need to also save qemu-dm data *)
	if hvm then (
		Io.write fd qemu_save_signature;
		let file = sprintf "/tmp/xen.qemu-dm.%d" domid in
		let fd2 = Unix.openfile file [ Unix.O_RDONLY ] 0o640 in
		let size = (Unix.stat file).Unix.st_size in
		debug "qemu-dm state file size: %d" size;

		finally (fun () ->
			Io.write_int fd size;
			let limit = Int64.of_int size in
			if Unixext.copy_file ~limit fd2 fd <> limit
			then failwith "Failed to write whole qemu-dm state file"
		) (fun () -> 
			Unix.unlink file;
			Unix.close fd2)
	);
	debug "Suspend for domid %d finished" domid

let send_s3resume ~xc domid = Xc.domain_send_s3resume xc domid

let vcpu_affinity_set ~xc domid vcpu cpumap =
	let bitmap = ref Int64.zero in
	if Array.length cpumap > 64 then
		invalid_arg "affinity_set";
	let bit_set bitmap n =
		Int64.logor bitmap (Int64.shift_left 1L n) in
	(* set bits in the bitmap that are true *)
	Array.iteri (fun i has_affinity ->
		if has_affinity then bitmap := bit_set !bitmap i
		) cpumap;
	Xc.vcpu_affinity_set xc domid vcpu !bitmap

let vcpu_affinity_get ~xc domid vcpu =
	let bitmap = Xc.vcpu_affinity_get xc domid vcpu in
	let cpumap = Array.make 64 false in
	let bit_isset bitmap n =
		(Int64.logand bitmap (Int64.shift_left 1L n)) > 0L in
	(* set bit in the array that are set in the bitmap *)
	for i = 0 to 63 do cpumap.(i) <- bit_isset bitmap i done;
	cpumap

let get_uuid ~xc domid =
	Uuid.uuid_of_int_array (Xc.domain_getinfo xc domid).Xc.handle

let grant_api_access ~xs domid mac ip port session vmref =
	let kvs = [
	        "mac", mac;
		"ip", ip;
		"port", string_of_int port;
		"session_id", session;
		"vm_ref", vmref;
	] in
	xs.Xs.writev (xs.Xs.getdomainpath domid) kvs

let get_api_access ~xs domid =
	let keys = [ "ip"; "port"; "session_id"; "vm_ref" ] in
	let v = xs.Xs.readv (xs.Xs.getdomainpath domid) keys in
	List.nth v 0, int_of_string (List.nth v 1),
	List.nth v 2, List.nth v 3

let guest_get_api_access ~xs =
	let keys = [ "ip"; "port"; "session_id"; "vm_ref" ] in
	let v = xs.Xs.readv "" keys in
	List.nth v 0, int_of_string (List.nth v 1),
	List.nth v 2, List.nth v 3

let add_ioport ~xc domid start_port end_port =
	let nr_ports = end_port - start_port in
	debug "ioport add %d %#x-%#x" domid start_port (start_port + nr_ports);
	Xc.domain_ioport_permission xc domid start_port nr_ports true

let del_ioport ~xc domid start_port end_port =
	let nr_ports = end_port - start_port in
	debug "ioport del %d %#x-%#x" domid start_port (start_port + nr_ports);
	Xc.domain_ioport_permission xc domid start_port nr_ports false

(* start_address and end_address are potentially 64 bit? *)
let add_iomem ~xc domid start_address end_address =
	let mem_to_pfn m = Int64.to_nativeint (Int64.div m 4096L) in
	let start_pfn = mem_to_pfn start_address and end_pfn = mem_to_pfn end_address in
	let nr_pfns = Nativeint.sub end_pfn start_pfn in
	debug "iomem add %d %#nx-%#nx" domid start_pfn end_pfn;
	Xc.domain_iomem_permission xc domid start_pfn nr_pfns true

let del_iomem ~xc domid start_address end_address =
	let mem_to_pfn m = Int64.to_nativeint (Int64.div m 4096L) in
	let start_pfn = mem_to_pfn start_address and end_pfn = mem_to_pfn end_address in
	let nr_pfns = Nativeint.sub end_pfn start_pfn in
	debug "iomem del %d %#nx-%#nx" domid start_pfn end_pfn;
	Xc.domain_iomem_permission xc domid start_pfn nr_pfns false

let add_irq ~xc domid irq =
	debug "irq add %d %#x" domid irq;
	Xc.domain_irq_permission xc domid irq true

let del_irq ~xc domid irq =
	debug "irq del %d %#x" domid irq;
	Xc.domain_irq_permission xc domid irq false

let set_machine_address_size ~xc domid width =
  match width with
    | Some width -> begin
	(debug "set machine address size dom%d to %d bits" domid width);
	Xc.domain_set_machine_address_size xc domid width
	  end
    | None -> ()

let suppress_spurious_page_faults ~xc domid =
  debug "suppress spurious page faults for dom%d" domid;
  Xc.domain_suppress_spurious_page_faults xc domid

type cpuid_reg = Eax | Ebx | Ecx | Edx
type cpuid_rtype = Clear | Set | Default | Same | Keep

type cpuid_config = ((int64 * int64 option) * ((cpuid_reg * (cpuid_rtype array)) list)) list

exception Cpuid_unknown_type of char
exception Cpuid_unknown_reg of string
exception Cpuid_misconfiguration

let cpuid_reg_of_string = function
	| "eax" -> Eax | "ebx" -> Ebx | "ecx" -> Ecx | "edx" -> Edx
	| s -> raise (Cpuid_unknown_reg s)

let cpuid_rtype_of_char = function
	| '0' -> Clear | '1' -> Set | 'x' -> Default | 's' -> Same | 'k' -> Keep
	| c -> raise (Cpuid_unknown_type c)

let char_of_cpuid_rtype = function
	| Clear -> '0' | Set -> '1' | Default -> 'x' | Same -> 's' | Keep -> 'k'

let cpuid_cfg_to_xc_cpuid_cfg a constr =
	let get_config_for reg lconstr =
		if List.mem_assoc reg lconstr then (
			let rtype = List.assoc reg lconstr in
			if Array.length rtype <> 32 then
				raise Cpuid_misconfiguration;
			let s = String.create 32 in
			Array.iteri (fun i x -> s.[i] <- char_of_cpuid_rtype x) rtype;
			Some s
		) else
			None
		in
	a.(0) <- get_config_for Eax constr;
	a.(1) <- get_config_for Ebx constr;
	a.(2) <- get_config_for Ecx constr;
	a.(3) <- get_config_for Edx constr;
	()

let cpuid_cfg_of_xc_cpuid_cfg cfg =
	let back_to reg arr =
		match arr with
		| None   -> None
		| Some s ->
			let a = Array.create 32 Default in
			for i = 0 to String.length s
			do
				a.(i) <- cpuid_rtype_of_char s.[i]
			done;
			Some (reg, a)
		in
	List.fold_left (fun acc x -> match x with None -> acc | Some x -> x :: acc)
	               [] [ back_to Eax cfg.(0); back_to Ebx cfg.(1);
	                    back_to Ecx cfg.(2); back_to Edx cfg.(3) ]

let cpuid_set ~xc ~hvm domid cfg =
	let tmp = Array.create 4 None in
	let cfgout = List.map (fun (node, constr) ->
		cpuid_cfg_to_xc_cpuid_cfg tmp constr;
		let ret = Xc.domain_cpuid_set xc domid hvm node tmp in
		let ret = cpuid_cfg_of_xc_cpuid_cfg ret in
		(node, ret)
	) cfg in
	cfgout

let cpuid_apply ~xc ~hvm domid =
	Xc.domain_cpuid_apply xc domid hvm

let cpuid_check cfg =
	let tmp = Array.create 4 None in
	List.map (fun (node, constr) ->
		cpuid_cfg_to_xc_cpuid_cfg tmp constr;
		let (success, cfgout) = Xc.cpuid_check node tmp in
		(success, (node, (cpuid_cfg_of_xc_cpuid_cfg cfgout)))
	) cfg
