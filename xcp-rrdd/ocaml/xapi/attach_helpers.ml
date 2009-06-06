open Pervasiveext
open Client

module D = Debug.Debugger(struct let name="xapi" end)
open D

let timeout = 300. (* 5 minutes, should never take this long *)

(** Attempt an unplug, and if it fails because the device is in use, wait for it to 
    detach by polling the currently-attached field. *)
let safe_unplug rpc session_id self = 
  try
    Client.VBD.unplug rpc session_id self
  with Api_errors.Server_error(error, _) as e when error = Api_errors.device_detach_rejected ->
    debug "safe_unplug caught device_detach_rejected: polling the currently_attached flag of the VBD";
    let start = Unix.gettimeofday () in
    let unplugged = ref false in
    while not(!unplugged) && (Unix.gettimeofday () -. start < timeout) do
      Thread.delay 5.;
      unplugged := not(Client.VBD.get_currently_attached rpc session_id self)
    done;
    if not(!unplugged) then begin
      debug "Timeout waiting for dom0 device to be unplugged";
      raise e
    end

(** For a VBD attached to a control domain, check to see if a valid task_id is present in
    the other-config. If a VBD exists for a task which has been cancelled or deleted then
    we assume the VBD has leaked. *)
let has_vbd_leaked __context vbd = 
  let other_config = Db.VBD.get_other_config ~__context ~self:vbd in
  let device = Db.VBD.get_device ~__context ~self:vbd in
  if not(List.mem_assoc Xapi_globs.vbd_task_key other_config)
  then (warn "dom0 block-attached disk has no task reference - who made it? device = %s" device; false)
  else
    let task_id = Ref.of_string (List.assoc Xapi_globs.vbd_task_key other_config) in
    (* check if the task record still exists and is pending *)
    try 
      let status = Db.Task.get_status ~__context ~self:task_id in
      not(List.mem status [ `pending; `cancelling ]) (* pending and cancelling => not leaked *)
    with _ -> true (* task record gone, must have leaked *)
      

(** Execute a function with a list of VBDs after attaching a bunch of VDIs to an vm *)
let with_vbds rpc session_id __context vm vdis mode f = 
  let task_id = Context.get_task_id __context in
  let vbds = ref [] in
  finally
    (fun () ->
       List.iter (fun vdi ->
		    let vbd = Client.VBD.create ~rpc ~session_id ~vM:vm ~empty:false ~vDI:vdi 
		      ~userdevice:"autodetect" ~bootable:false ~mode ~_type:`Disk ~unpluggable:true
		      ~qos_algorithm_type:"" ~qos_algorithm_params:[] 
		      ~other_config:[ Xapi_globs.vbd_task_key, Ref.string_of task_id ] in
		    (* sanity-check *)
		    if has_vbd_leaked __context vbd
		    then error "Attach_helpers.with_vbds new VBD has leaked: %s" (Ref.string_of vbd);

		    let vbd_uuid = Client.VBD.get_uuid ~rpc ~session_id ~self:vbd in
		    let uuid = Client.VM.get_uuid ~rpc ~session_id ~self:vm in
		    debug "created VBD (uuid %s); attempting to hotplug to VM (uuid: %s)" vbd_uuid uuid; 
		    vbds := vbd :: !vbds;
		    Client.VBD.plug rpc session_id vbd
		 ) vdis;
       vbds := List.rev !vbds;
       f !vbds)
    (fun () ->
      (* Use a new session here to cover the case where the session has become invalid *)
      Helpers.call_api_functions ~__context (fun rpc session_id ->
	List.iter (Helpers.log_exn_continue "unplugging disk from VM" 
		      (fun self -> safe_unplug rpc session_id self)) !vbds;
	List.iter (Helpers.log_exn_continue "destroying VBD on VM" 
		      (fun self -> Client.VBD.destroy rpc session_id self)) !vbds))
