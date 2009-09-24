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
module D=Debug.Debugger(struct let name="dbsync" end)
open D

open Client

(* Synchronising code which is specific to the master *)


(* create pool record (if master and not one already there) *)
let create_pool_record ~__context =
	let pools = Db.Pool.get_all ~__context in
	if pools=[] then
		Db.Pool.create ~__context ~ref:(Ref.make()) ~uuid:(Uuid.to_string (Uuid.make_uuid()))
			~name_label:"" ~name_description:"" ~master:(Helpers.get_localhost ~__context) 
			~default_SR:Ref.null ~suspend_image_SR:Ref.null ~crash_dump_SR:Ref.null ~other_config:[]
			~ha_enabled:false ~ha_configuration:[] ~ha_statefiles:[]
			~ha_host_failures_to_tolerate:0L ~ha_plan_exists_for:0L ~ha_allow_overcommit:false ~ha_overcommitted:false ~blobs:[] ~tags:[] ~gui_config:[] 
			~wlb_url:"" ~wlb_username:"" ~wlb_password:Ref.null ~wlb_enabled:false ~wlb_verify_cert:false
			~redo_log_enabled:false ~redo_log_vdi:Ref.null

let set_master_ip ~__context =
  let ip =
    match (Helpers.get_management_ip_addr()) with
	Some ip -> ip
      | None ->
	  (error "Cannot read master IP address. Check the control interface has an IP address"; "") in
  let host = Helpers.get_localhost ~__context in
    Db.Host.set_address ~__context ~self:host ~value:ip


let set_master_pool_reference ~__context =
  let pool = List.hd (Db.Pool.get_all ~__context) in
    Db.Pool.set_master ~__context ~self:pool ~value:(Helpers.get_localhost ~__context) 

(** Look at all running VMs, examine their consoles and regenerate the console URLs.
    This catches the case where the IP address changes but the URLs still point to the wrong
    place. *)
let refresh_console_urls ~__context =
  List.iter
    (fun console ->
       Helpers.log_exn_continue (Printf.sprintf "Updating console: %s" (Ref.string_of console))
	 (fun () ->
	    let vm = Db.Console.get_VM ~__context ~self:console in
	    let host = Db.VM.get_resident_on ~__context ~self:vm in
	    let address = Db.Host.get_address ~__context ~self:host in
	    let url_should_be = Printf.sprintf "https://%s%s?ref=%s" address Constants.console_uri (Ref.string_of vm) in
	    Db.Console.set_location ~__context ~self:console ~value:url_should_be
	 ) ()
    ) (Db.Console.get_all ~__context)

(** CA-15449: after a pool restore database VMs which were running on slaves now have dangling resident_on fields.
    If these are control domains we destroy them, otherwise we reset them to Halted. *)
let reset_vms_running_on_missing_hosts ~__context =
  List.iter (fun vm ->
	       let vm_r = Db.VM.get_record ~__context ~self:vm in
	       let valid_resident_on = Db.is_valid_ref vm_r.API.vM_resident_on in
	       if not valid_resident_on then begin
		 if vm_r.API.vM_is_control_domain then begin
		   info "Deleting control domain VM uuid '%s' ecause VM.resident_on refers to a Host which is nolonger in the Pool" vm_r.API.vM_uuid;
		   Db.VM.destroy ~__context ~self:vm
		 end else if vm_r.API.vM_power_state = `Running then begin
		   let msg = Printf.sprintf "Resetting VM uuid '%s' to Halted because VM.resident_on refers to a Host which is nolonger in the Pool" vm_r.API.vM_uuid in
		   info "%s" msg;
		   Helpers.log_exn_continue msg (fun () -> Xapi_vm_lifecycle.force_state_reset ~__context ~self:vm ~value:`Halted) ()
		 end
	       end) (Db.VM.get_all ~__context)

(** Release 'locks' on VMs in the Halted state: ie {VBD,VIF}.{currently_attached,reserved}
    Note that the {allowed,current}_operations fields are non-persistent so blanked on *master* startup (not slave)
    No allowed_operations are recomputed here: this work is performed later in a non-critical thread.
 *)
let release_locks ~__context =
  (* non-running VMs should have their VBD.current_operations cleared: *)
  let vms = List.filter (fun self -> Db.VM.get_power_state ~__context ~self = `Halted) (Db.VM.get_all ~__context) in
  List.iter (fun vm -> 
	       List.iter (fun self -> 
			    Xapi_vbd_helpers.clear_current_operations ~__context ~self)
		 (Db.VM.get_VBDs ~__context ~self:vm)) vms;
  (* Resets the current operations of all Halted VMs *)
  List.iter (fun self -> Xapi_vm_lifecycle.force_state_reset ~__context ~self ~value:`Halted) vms;
  (* All VMs should have their scheduled_to_be_resident_on field cleared *)
  List.iter (fun self -> Db.VM.set_scheduled_to_be_resident_on ~__context ~self ~value:Ref.null)
    (Db.VM.get_all ~__context)

(** Miami added an explicit VLAN linking table; to cope with the upgrade case
    recreate any missing VLAN records here *)
let create_missing_vlan_records ~__context =
  debug "Recreating any missing VLAN records";
  let all_pifs = Db.PIF.get_records_where ~__context ~expr:Db_filter_types.True in
  let base_pifs = List.filter (fun (_, rc) -> rc.API.pIF_physical) all_pifs in
  List.iter (fun (rf, rc) ->
	       if rc.API.pIF_VLAN <> (-1L) then begin
		 (* make sure this VLAN record exists *)
		 let vlan = rc.API.pIF_VLAN_master_of in
		 try
		   ignore(Db.VLAN.get_uuid ~__context ~self:vlan)
		 with _ ->
		   debug "VLAN PIF '%s' has missing VLAN record" rc.API.pIF_uuid;
		   (* Find the base PIF on this host to link it up to *)
		   let my_base_pifs = List.filter (fun (_, x) -> x.API.pIF_host = rc.API.pIF_host) base_pifs in
		   begin match List.filter (fun (_, x) -> x.API.pIF_device = rc.API.pIF_device) my_base_pifs with
		   | [ brf, brc ] ->
		       debug "VLAN PIF '%s' corresponds to base PIF '%s'" rc.API.pIF_uuid brc.API.pIF_uuid;
		       let vlan_ref = Ref.make () and vlan_uuid = Uuid.string_of_uuid (Uuid.make_uuid ()) in
		       Db.PIF.set_VLAN_master_of ~__context ~self:rf ~value:vlan_ref;
		       Db.VLAN.create ~__context ~ref:vlan_ref ~uuid:vlan_uuid
			 ~tagged_PIF:brf ~untagged_PIF:rf ~tag:rc.API.pIF_VLAN ~other_config:[]
		   | [] ->
		       warn "Failed to find untagged PIF corresponding to VLAN PIF '%s'" rc.API.pIF_uuid
		   | _ ->
		       warn "Found multiple untagged PIF corresponding to VLAN PIF '%s'" rc.API.pIF_uuid
		   end
	       end) all_pifs

(** During rolling upgrade the Rio hosts require host metrics to exist. The persistence changes
    in Miami resulted in these not being created by default. We recreate them here for compatability *)
let create_host_metrics ~__context =
  List.iter 
    (fun self ->
       let m = Db.Host.get_metrics ~__context ~self in
       let exists = try ignore(Db.Host_metrics.get_uuid ~__context ~self:m); true with _ -> false in
       if not(exists) then begin
	 debug "Creating missing Host_metrics object for Host: %s" (Db.Host.get_uuid ~__context ~self);
	 let r = Ref.make () in
	 Db.Host_metrics.create ~__context ~ref:r
	   ~uuid:(Uuid.to_string (Uuid.make_uuid ())) ~live:false
	   ~memory_total:0L ~memory_free:0L ~last_updated:Date.never ~other_config:[];
	 Db.Host.set_metrics ~__context ~self ~value:r
       end) (Db.Host.get_all ~__context)


let create_tools_sr __context = 
  Helpers.call_api_functions ~__context (fun rpc session_id ->
    (* Creates a new SR and PBD record *)
    (* N.b. dbsync_slave is called _before_ this, so we can't rely on the PBD creating code in there 
       to make the PBD for the shared tools SR *)
    let create_magic_sr name description _type content_type device_config sr_other_config shared =
      let sr = 
	try
	  (* Check if it already exists *)
	  List.hd (Client.SR.get_by_name_label rpc session_id name)
	with _ ->
	  begin
	    let sr =
	      Client.SR.introduce ~rpc ~session_id ~uuid:(Uuid.to_string (Uuid.make_uuid())) 
		~name_label:name
		~name_description:description
		~_type ~content_type ~shared ~sm_config:[] in
	    Client.SR.set_other_config ~rpc ~session_id ~self:sr ~value:sr_other_config;
	    sr
	  end in
      (* Master has created this shared SR, lets make PBDs for all of the slaves too. Nb. device-config is same for all hosts *)
      let hosts = Db.Host.get_all ~__context in
      List.iter (fun host -> ignore (Create_storage.maybe_create_pbd rpc session_id sr device_config host)) hosts
    in
    
    (* Create XenSource Tools ISO, if an SR with this name is not already there: *)
    let tools_srs = List.filter (fun sr -> Helpers.is_tools_sr ~__context ~sr) (Db.SR.get_all ~__context) in
    if tools_srs = [] then
      create_magic_sr Xapi_globs.miami_tools_sr_name
	"XenServer Tools ISOs"
	"iso" "iso"
	["location",Xapi_globs.tools_sr_dir; "legacy_mode", "true"]
	[Xapi_globs.xensource_internal, "true";
	 Xapi_globs.tools_sr_tag, "true";
	 Xapi_globs.i18n_key, "xenserver-tools";
	 (Xapi_globs.i18n_original_value_prefix ^ "name_label"),
	Xapi_globs.miami_tools_sr_name;
	 (Xapi_globs.i18n_original_value_prefix ^ "name_description"),
	"XenServer Tools ISOs"]
	true)

let create_tools_sr_noexn __context = Helpers.log_exn_continue "creating tools SR" create_tools_sr __context

(* Update the database to reflect current state. Called for both start of day and after
   an agent restart. *)
let update_env __context =
  debug "creating root user";
  Create_misc.create_root_user ~__context;

  debug "creating pool record";
  create_pool_record ~__context;
  set_master_pool_reference ~__context;
  set_master_ip ~__context;

  (* CA-15449: when we restore from backup we end up with Hosts being forgotten and VMs
     marked as running with dangling resident_on references. We delete the control domains
     and reset the rest to Halted. *)
  reset_vms_running_on_missing_hosts ~__context;

  refresh_console_urls ~__context;

  (* Resets all Halted VMs to a known good state *)
  release_locks ~__context;
  (* Cancel tasks that were running on the master - by setting host=None we consider all tasks
     in the db for cancelling *)
  Cancel_tasks.cancel_tasks_on_host ~__context ~host_opt:None;
  (* Update the SM plugin table *)
  Xapi_sm.resync_plugins ~__context;

  create_missing_vlan_records ~__context;
  create_host_metrics ~__context;
  create_tools_sr_noexn __context
    
