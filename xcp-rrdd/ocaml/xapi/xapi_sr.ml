open Printf
open Threadext
open Pervasiveext
open Listext
open Db_filter_types
open API
open Client

(* internal api *)

module D=Debug.Debugger(struct let name="xapi" end)
open D

(**************************************************************************************)
(* current/allowed operations checking                                                *)

open Record_util

let all_ops : API.storage_operations_set = 
  [ `scan; `destroy; `forget; `plug; `unplug; `vdi_create; `vdi_destroy; `vdi_resize; `vdi_clone; `vdi_snapshot;
    `vdi_introduce; `update ]

let sm_cap_table = 
  [ `vdi_create, Smint.Vdi_create;
    `vdi_destroy, Smint.Vdi_delete;
    `vdi_resize, Smint.Vdi_resize;
    `vdi_introduce, Smint.Vdi_introduce;
    `update, Smint.Sr_update;
    (* We fake clone ourselves *)
    `vdi_snapshot, Smint.Vdi_snapshot ]

type table = (API.storage_operations, ((string * (string list)) option)) Hashtbl.t

let set_difference a b = List.filter (fun x -> not(List.mem x b)) a

(** Returns a table of operations -> API error options (None if the operation would be ok) *)
let valid_operations ~__context record _ref' : table = 
  let _ref = Ref.string_of _ref' in
  let current_ops = record.Db_actions.sR_current_operations in

  let table : table = Hashtbl.create 10 in
  List.iter (fun x -> Hashtbl.replace table x None) all_ops;
  let set_errors (code: string) (params: string list) (ops: API.storage_operations_set) =
    List.iter (fun op ->
		 if Hashtbl.find table op = None
		 then Hashtbl.replace table op (Some(code, params))) ops in

  (* Policy:
     Anyone may attach and detach VDIs in parallel but we serialise
     vdi_create, vdi_destroy, vdi_resize operations.
     Multiple simultaneous PBD.unplug operations are ok.
  *)

  (* First consider the backend SM capabilities *)
  let sm_caps = 
    try
      Sm.capabilities_of_driver record.Db_actions.sR_type
    with Sm.Unknown_driver _ -> []
  in

  (* Then filter out the operations we don't want to see for the magic tools SR *)
  let sm_caps = 
    if Helpers.is_tools_sr ~__context ~sr:_ref'
    then List.filter (fun cap -> not(List.mem cap [ Smint.Vdi_create; Smint.Vdi_delete ])) sm_caps
    else sm_caps in

  let forbidden_by_backend = 
    List.filter (fun op -> List.mem_assoc op sm_cap_table && not(List.mem (List.assoc op sm_cap_table) sm_caps))
      all_ops in
  set_errors Api_errors.sr_operation_not_supported [ _ref ] forbidden_by_backend;


  let safe_to_parallelise = [ ] in
  let current_ops = List.setify (List.map snd current_ops) in
  
  (* If there are any current operations, all the non_parallelisable operations
     must definitely be stopped *)
  if current_ops <> []
  then set_errors Api_errors.other_operation_in_progress
    [ "SR"; _ref; sr_operation_to_string (List.hd current_ops) ]
    (set_difference all_ops safe_to_parallelise);

  let all_are_parallelisable = List.fold_left (&&) true 
    (List.map (fun op -> List.mem op safe_to_parallelise) current_ops) in
  (* If not all are parallelisable (eg a vdi_resize), ban the otherwise 
     parallelisable operations too *)
  if not(all_are_parallelisable)
  then set_errors  Api_errors.other_operation_in_progress
    [ "SR"; _ref; sr_operation_to_string (List.hd current_ops) ]
    safe_to_parallelise;
  table

let throw_error (table: table) op = 
  if not(Hashtbl.mem table op)
  then raise (Api_errors.Server_error(Api_errors.internal_error, [ Printf.sprintf "xapi_sr.assert_operation_valid unknown operation: %s" (sr_operation_to_string op) ]));

  match Hashtbl.find table op with
  | Some (code, params) -> raise (Api_errors.Server_error(code, params))
  | None -> ()

let assert_operation_valid ~__context ~self ~(op:API.storage_operations) = 
  let all = Db.SR.get_record_internal ~__context ~self in
  let table = valid_operations ~__context all self in
  throw_error table op
    
let update_allowed_operations ~__context ~self : unit =
  let all = Db.SR.get_record_internal ~__context ~self in
  let valid = valid_operations ~__context all self in
  let keys = Hashtbl.fold (fun k v acc -> if v = None then k :: acc else acc) valid [] in
  Db.SR.set_allowed_operations ~__context ~self ~value:keys

(** Someone is cancelling a task so remove it from the current_operations *)
let cancel_task ~__context ~self ~task_id = 
  let all = List.map fst (Db.SR.get_current_operations ~__context ~self) in
  if List.mem task_id all then
    begin
      Db.SR.remove_from_current_operations ~__context ~self ~key:task_id;
      update_allowed_operations ~__context ~self
    end

let cancel_tasks ~__context ~self ~all_tasks_in_db ~task_ids =
  let ops = Db.SR.get_current_operations ~__context ~self in
  let set = (fun value -> Db.SR.set_current_operations ~__context ~self ~value) in
  Helpers.cancel_tasks ~__context ~ops ~all_tasks_in_db ~task_ids ~set

(**************************************************************************************)

(* Limit us to a single scan per SR at a time: any other thread that turns up gets
   immediately rejected *)
let scans_in_progress = Hashtbl.create 10
let scans_in_progress_m = Mutex.create ()

let i_should_scan_sr sr = 
  Mutex.execute scans_in_progress_m 
    (fun () -> 
       if Hashtbl.mem scans_in_progress sr
       then false (* someone else already is *)
       else (Hashtbl.replace scans_in_progress sr true; true))
let scan_finished sr = 
  Mutex.execute scans_in_progress_m 
    (fun () -> 
       Hashtbl.remove scans_in_progress sr)

(* Perform a single scan of an SR in a background thread. Limit to one thread per SR *)
let scan_one ~__context sr = 
  if i_should_scan_sr sr
  then 
    ignore(Thread.create
      (fun () ->
	 Server_helpers.exec_with_subtask ~__context "scan one" (fun ~__context ->
	 finally
	   (fun () ->
	      try
		Helpers.call_api_functions ~__context
		  (fun rpc session_id ->
		     Helpers.log_exn_continue (Printf.sprintf "scanning SR %s" (Ref.string_of sr))
		       (fun sr -> 
			  Client.SR.scan rpc session_id sr) sr)
	      with e ->
		error "Caught exception attempting an SR.scan: %s" (ExnHelper.string_of_exn e)
	   )
	   (fun () -> 
	      scan_finished sr)
      )) ())

let get_all_plugged_srs ~__context =
  let pbds = Db.PBD.get_all ~__context in
  let pbds_plugged_in = List.filter (fun self -> Db.PBD.get_currently_attached ~__context ~self) pbds in
  List.setify (List.map (fun self -> Db.PBD.get_SR ~__context ~self) pbds_plugged_in)

let scan_all ~__context =
  let srs = get_all_plugged_srs ~__context in
  (* only scan those with the dirty/auto_scan key set *)
  let scannable_srs = 
    List.filter (fun sr ->
		   let oc = Db.SR.get_other_config ~__context ~self:sr in
		   (List.mem_assoc Xapi_globs.auto_scan oc && (List.assoc Xapi_globs.auto_scan oc = "true"))
		   || (List.mem_assoc "dirty" oc)) srs in
  if List.length scannable_srs > 0 then
    debug "Automatically scanning SRs = [ %s ]" (String.concat ";" (List.map Ref.string_of scannable_srs));
  List.iter (scan_one ~__context) scannable_srs

let scanning_thread () =
  name_thread "sr_scan";
  Server_helpers.exec_with_new_task "SR scanner" (fun __context ->
  let host = Helpers.get_localhost ~__context in

  let get_delay () =
    try
      let oc = Db.Host.get_other_config ~__context ~self:host in
      float_of_string (List.assoc Xapi_globs.auto_scan_interval oc)
    with _ -> 30.
    in

  while true do
    Thread.delay (get_delay ());
    try scan_all ~__context
    with e -> debug "Exception in SR scanning thread: %s" (Printexc.to_string e)
  done)

(* introduce, creates a record for the SR in the database. It has no other side effect *)
let introduce  ~__context ~uuid ~name_label
    ~name_description ~_type ~content_type ~shared ~sm_config =
  let _type = String.lowercase _type in
  if not(List.mem _type (Sm.supported_drivers ()))
  then raise (Api_errors.Server_error(Api_errors.sr_unknown_driver, [ _type ]));
  let uuid = if uuid="" then Uuid.to_string (Uuid.make_uuid()) else uuid in (* fill in uuid if none specified *)
  let sr_ref = Ref.make () in
    (* Create SR record in DB *)
  let () = Db.SR.create ~__context ~ref:sr_ref ~uuid
      ~name_label ~name_description 
      ~allowed_operations:[] ~current_operations:[]
      ~virtual_allocation:0L
      ~physical_utilisation: (-1L)
      ~physical_size: (-1L)
      ~content_type
      ~_type ~shared ~other_config:[] ~default_vdi_visibility:true
      ~sm_config ~blobs:[] ~tags:[] in

    update_allowed_operations ~__context ~self:sr_ref;
    (* Return ref of newly created sr *)
    sr_ref

let make ~__context ~host ~device_config ~physical_size ~name_label ~name_description ~_type ~content_type ~sm_config = 
  raise (Api_errors.Server_error (Api_errors.message_deprecated, []))


(** Before destroying an SR record, unplug and destroy referencing PBDs. If any of these
    operations fails, the ensuing exception should keep the SR record around. *)
let unplug_and_destroy_pbds ~__context ~self = 
  let pbds = Db.SR.get_PBDs ~__context ~self in
  Helpers.call_api_functions
    (fun rpc session_id ->
       List.iter
	 (fun pbd ->
	    Client.PBD.unplug ~rpc ~session_id ~self:pbd;
	    Client.PBD.destroy ~rpc ~session_id ~self:pbd)
	 pbds)

(* Create actually makes the SR on disk, and introduces it into db, and creates PDB record for current host *)
let create  ~__context ~host ~device_config ~(physical_size:int64) ~name_label ~name_description
    ~_type ~content_type ~shared ~sm_config =
  debug "SR.create name_label=%s sm_config=[ %s ]" name_label (String.concat "; " (List.map (fun (k, v) -> k ^ " = " ^ v) sm_config));
  let _type = String.lowercase _type in
  if not(List.mem _type (Sm.supported_drivers ()))
  then raise (Api_errors.Server_error(Api_errors.sr_unknown_driver, [ _type ]));

  let sr_uuid = Uuid.make_uuid() in
  let sr_uuid_str = Uuid.to_string sr_uuid in
  (* Create the SR in the database before creating on disk, so the backends can read the sm_config field. If an error happens here
     we have to clean up the record.*)
  let sr_ref =
    introduce  ~__context ~uuid:sr_uuid_str ~name_label
      ~name_description ~_type ~content_type ~shared ~sm_config in 

  (* We have to transform_password_device config here on the sr_create call, since the backends will be expecting
     transformed passwords.. *)
  begin
    try 
      let subtask_of = Some (Context.get_task_id __context) in
        Sm.sr_create (subtask_of, Sm.sm_master true :: (Xapi_pbd.transform_password_device_config device_config)) _type sr_ref physical_size;
    with
    | Smint.Not_implemented_in_backend ->
	Db.SR.destroy ~__context ~self:sr_ref;
	raise (Api_errors.Server_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr_ref ]))

    | e -> 
	  Db.SR.destroy ~__context ~self:sr_ref;
	  raise e
  end;

  let pbds =
    if shared then
      List.map (fun h->Xapi_pbd.create ~__context ~sR:sr_ref ~device_config ~host:h ~other_config:[])
	(Db.Host.get_all ~__context)
    else
      [Xapi_pbd.create_thishost ~__context ~sR:sr_ref ~device_config ~currently_attached:false ] in
    Helpers.call_api_functions ~__context
      (fun rpc session_id ->
	 List.iter
	   (fun self ->
	      try
		Client.PBD.plug ~rpc ~session_id ~self
	      with e -> warn "Could not plug PBD '%s': %s" (Db.PBD.get_uuid ~__context ~self) (Printexc.to_string e))
	   pbds);
    sr_ref

let check_no_pbds_attached ~__context ~sr =
  let all_pbds_attached_to_this_sr =
    Db.PBD.get_records_where ~__context ~expr:(And(Eq(Field "SR", Literal (Ref.string_of sr)), Eq(Field "currently_attached", Literal "true"))) in
    if List.length all_pbds_attached_to_this_sr > 0
    then raise (Api_errors.Server_error(Api_errors.sr_has_pbd, [ Ref.string_of sr ]))

(* Remove SR record from database without attempting to remove SR from disk.
   Fail if a PBD record still exists; force the user to unplug it and delete it first. *)
let forget  ~__context ~sr =
  (* NB we fail if ANY host is connected to this SR *)
  check_no_pbds_attached ~__context ~sr;
  List.iter (fun self -> Db.PBD.destroy ~__context ~self) (Db.SR.get_PBDs ~__context ~self:sr);
  Db.SR.destroy ~__context ~self:sr;
  let vdis = Db.VDI.get_refs_where ~__context ~expr:(Eq(Field "SR", Literal (Ref.string_of sr))) in
  List.iter (fun vdi ->  Db.VDI.destroy ~__context ~self:vdi) vdis

(* Remove SR from disk and remove SR record from database. (This operation uses the SR's associated
   PBD record on current host to determine device_config reqd by sr backend) *)
let destroy  ~__context ~sr =
  check_no_pbds_attached ~__context ~sr;
  let pbds = Db.SR.get_PBDs ~__context ~self:sr in

  (* raise exception if the 'indestructible' flag is set in other_config *)
  let oc = Db.SR.get_other_config ~__context ~self:sr in
  if (List.mem_assoc "indestructible" oc) && (List.assoc "indestructible" oc = "true") then
    raise (Api_errors.Server_error(Api_errors.sr_indestructible, [ Ref.string_of sr ]));
    
  Storage_access.SR.attach ~__context ~self:sr;

  begin
    try
      Sm.call_sm_functions ~__context ~sR:sr
	(fun device_config driver -> Sm.sr_delete device_config driver sr)
    with
    | Smint.Not_implemented_in_backend ->
	raise (Api_errors.Server_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr ]))
  end;

  (* The sr_delete may have deleted some VDI records *)
  let vdis = Db.SR.get_VDIs ~__context ~self:sr in

  (* Let's not call detach because the backend throws an error *)
  Db.SR.destroy ~__context ~self:sr;
  (* Safe to delete all the PBD records because we called 'check_no_pbds_attached' earlier *)
  List.iter (fun pbd -> Db.PBD.destroy ~__context ~self:pbd) pbds;
  List.iter (fun vdi ->  Db.VDI.destroy ~__context ~self:vdi) vdis

let update ~__context ~sr =
  Sm.assert_pbd_is_plugged ~__context ~sr;
  Sm.call_sm_functions ~__context ~sR:sr
    (fun device_config driver -> Sm.sr_update device_config driver sr)

let get_supported_types ~__context = Sm.supported_drivers ()

(* CA-13190 Rio->Miami upgrade needs to prevent concurrent scans *)
let scan_upgrade_lock = Mutex.create ()

(* Perform a scan of this locally-attached SR *)
let scan ~__context ~sr = 
  Mutex.execute scan_upgrade_lock
    (fun () ->

  Sm.call_sm_functions ~__context ~sR:sr
    (fun backend_config driver ->
       try
	 Sm.sr_scan backend_config driver sr;
	 Db.SR.remove_from_other_config ~__context ~self:sr ~key:"dirty";
       with e ->
	 error "Caught error scanning SR (%s): %s." 
	   (Db.SR.get_name_label ~__context ~self:sr) (ExnHelper.string_of_exn e);
	 raise e)

    )

let set_shared ~__context ~sr ~value =
  if value then
    (* We can always set an SR to be shared... *)
    Db.SR.set_shared ~__context ~self:sr ~value
  else
    begin
      let pbds = Db.PBD.get_all ~__context in
      let pbds = List.filter (fun pbd -> Db.PBD.get_SR ~__context ~self:pbd = sr) pbds in
      if List.length pbds > 1 then
	raise (Api_errors.Server_error (Api_errors.sr_has_multiple_pbds,List.map (fun pbd -> Ref.string_of pbd) pbds));
      Db.SR.set_shared ~__context ~self:sr ~value
    end
  
let probe ~__context ~host ~device_config ~_type ~sm_config =
  debug "SR.probe sm_config=[ %s ]" (String.concat "; " (List.map (fun (k, v) -> k ^ " = " ^ v) sm_config));

  let _type = String.lowercase _type in
  if not(List.mem _type (Sm.supported_drivers ()))
  then raise (Api_errors.Server_error(Api_errors.sr_unknown_driver, [ _type ]));
  let subtask_of = Some (Context.get_task_id __context) in
    Sm.sr_probe (subtask_of, Sm.sm_master true :: (Xapi_pbd.transform_password_device_config device_config)) _type sm_config

let set_virtual_allocation ~__context ~self ~value = 
  Db.SR.set_virtual_allocation ~__context ~self ~value

let set_physical_size ~__context ~self ~value = 
  Db.SR.set_physical_size ~__context ~self ~value

let set_physical_utilisation ~__context ~self ~value = 
  Db.SR.set_physical_utilisation ~__context ~self ~value

let assert_can_host_ha_statefile ~__context ~sr = 
  Xha_statefile.assert_sr_can_host_statefile ~__context ~sr

let create_new_blob ~__context ~sr ~name ~mime_type =
  let blob = Xapi_blob.create ~__context ~mime_type in
  Db.SR.add_to_blobs ~__context ~self:sr ~key:name ~value:blob;
  blob

let lvhd_stop_using_these_vdis_and_call_script ~__context ~vdis ~plugin ~fn ~args = 
  (* Sanity check: all VDIs should be in the same SR *)
  let srs = List.setify (List.concat (List.map (fun vdi -> try [ Db.VDI.get_SR ~__context ~self:vdi ] with _ -> []) vdis)) in
  if List.length srs > 1
  then failwith "VDIs must all be in the same SR";
  (* If vdis = [] then srs = []. Otherwise vdis <> [] and len(srs) = 1 *)
  if List.length srs = 1 then begin
    Sm.assert_pbd_is_plugged ~__context ~sr:(List.hd srs);
    if not (Helpers.i_am_srmaster ~__context ~sr:(List.hd srs))
    then failwith "I am not the SRmaster"; (* should never happen *)
  end;

  (* Find all the VBDs with currently_attached = true. We rely on logic in the master forwarding layer
     to guarantee that no other VBDs may become currently_attached = true. *)
  let localhost = Helpers.get_localhost ~__context in
  Helpers.call_api_functions ~__context
    (fun rpc session_id ->
       Sm.with_all_vbds_paused ~__context ~vdis
	 (fun () ->
	    Client.Host.call_plugin rpc session_id localhost
	      plugin
	      fn
	      args
	 )
    )
