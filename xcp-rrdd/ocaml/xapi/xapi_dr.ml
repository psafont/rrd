open Db_cache_types
open Listext
open Threadext

module D = Debug.Debugger(struct let name="xapi" end)
open D

(* Keep track of foreign metadata VDIs and their database generations. *)
let db_vdi_cache : (API.ref_VDI, Generation.t) Hashtbl.t = Hashtbl.create 10
let db_vdi_cache_mutex = Mutex.create ()

(* This doesn't grab the mutex, so should only be called from add_vdis_to_cache or remove_vdis_from_cache. *)
let update_metadata_latest ~__context =
	debug "Updating metadata_latest on all foreign pool metadata VDIs";
	let module PoolMap = Map.Make(struct type t = API.ref_pool let compare = compare end) in
	(* First, create a map of type Pool -> (VDI, generation count) list *)
	let vdis_grouped_by_pool = Hashtbl.fold
		(fun vdi generation map ->
			(* Add this VDI to the map. *)
			let pool = Db.VDI.get_metadata_of_pool ~__context ~self:vdi in
			let new_list = try
				let current_list = PoolMap.find pool map in
				(vdi, generation) :: current_list
			with Not_found ->
				[vdi, generation]
			in
			PoolMap.add pool new_list map)
		db_vdi_cache
		PoolMap.empty
	in
	(* For each pool who has metadata VDIs in the database, find the VDIs with the highest database generation count. *)
	(* These VDIs contain the newest metadata we have for the pool. *)
	PoolMap.iter
		(fun pool vdi_list ->
			debug "Updating metadata_latest on all VDIs with metadata_of_pool %s" (Ref.string_of pool);
			debug "Pool %s has %d metadata VDIs" (Ref.string_of pool) (List.length vdi_list);
			(* Find the maximum database generation for VDIs containing metadata of this particular foreign pool. *)
			let maximum_generation = List.fold_right
				(fun (_, generation) acc ->
					if generation > acc then generation
					else acc)
				vdi_list 0L
			in
			debug "Largest known database generation for pool %s is %Ld." (Ref.string_of pool) maximum_generation;
			(* Set VDI.metadata_latest according to whether the VDI has the highest known generation count. *)
			List.iter
				(fun (vdi, generation) ->
					let metadata_latest = (generation = maximum_generation) in
					debug "Database in VDI %s has generation %Ld - setting metadata_latest to %b."
						(Db.VDI.get_uuid ~__context ~self:vdi)
						generation metadata_latest;
					Db.VDI.set_metadata_latest ~__context ~self:vdi ~value:metadata_latest)
				vdi_list)
		vdis_grouped_by_pool

let read_database_generation ~db_ref =
	let db = Db_ref.get_database db_ref in
	let manifest = Database.manifest db in
	Manifest.generation manifest

(* For each VDI, try to open the contained database. *)
(* If this is successful, add its generation count to the cache. *)
(* Finally, update metadata_latest on all metadata VDIs. *)
let add_vdis_to_cache ~__context ~vdis =
	Mutex.execute db_vdi_cache_mutex
		(fun () ->
			List.iter
				(fun vdi ->
					try
						let db_ref = Xapi_vdi_helpers.database_ref_of_vdi ~__context ~vdi in
						let generation = read_database_generation ~db_ref in
						debug "Adding VDI %s to metadata VDI cache." (Db.VDI.get_uuid ~__context ~self:vdi);
						Hashtbl.replace db_vdi_cache vdi generation
					with e ->
						(* If we can't open the database then it doesn't really matter that the VDI is not added to the cache. *)
						debug "Could not open database from VDI %s - caught %s"
							(Db.VDI.get_uuid ~__context ~self:vdi)
							(Printexc.to_string e))
				vdis;
			update_metadata_latest ~__context)

(* Remove all the supplied VDIs from the cache, then update metadata_latest on the remaining VDIs. *)
let remove_vdis_from_cache ~__context ~vdis =
	Mutex.execute db_vdi_cache_mutex
		(fun () ->
			List.iter
				(fun vdi ->
					debug "Removing VDI %s from metadata VDI cache." (Db.VDI.get_uuid ~__context ~self:vdi);
					Hashtbl.remove db_vdi_cache vdi)
				vdis;
			update_metadata_latest ~__context)

(* This function uses the VM export functionality to *)
(* create the objects required to reimport a list of VMs *)
let create_import_objects ~__context ~vms =
	let table = Export.create_table () in
	List.iter (Export.update_table ~__context ~include_snapshots:true ~preserve_power_state:false ~include_vhd_parents:false ~table) vms;
	Export.make_all ~with_snapshot_metadata:true ~preserve_power_state:false table __context

let clear_sr_introduced_by ~__context ~vm =
	let srs = Xapi_vm_helpers.list_required_SRs ~__context ~self:vm in
	List.iter
		(fun sr -> Db.SR.set_introduced_by ~__context ~self:sr ~value:Ref.null)
		srs

let recover_vms ~__context ~vms ~session_to ~force =
	let config = {
		Import.sr = Ref.null;
		Import.full_restore = true;
		Import.vm_metadata_only = true;
		Import.force = force;
	} in
	let objects = create_import_objects ~__context ~vms in
	Server_helpers.exec_with_new_task ~session_id:session_to "Importing VMs"
		(fun __context_to ->
			(* Check that session_to has at least pool admin permissions. *)
			let permission = Rbac_static.role_pool_admin in
			if not(Rbac.has_permission ~__context:__context_to ~permission) then begin
				let permission_name = permission.Db_actions.role_name_label in
				raise (Api_errors.Server_error(Api_errors.rbac_permission_denied,
					[permission_name; "The supplied session does not have the required permissions for VM recovery."]))
			end;
			let rpc = Helpers.make_rpc ~__context:__context_to in
			let state = Import.handle_all __context_to
				config rpc session_to objects
			in
			let vmrefs = List.setify
				(List.map
					(fun (cls, id, r) -> Ref.of_string r)
					state.Import.created_vms)
			in
			try
				Import.complete_import ~__context:__context_to vmrefs;
				(* Remove the introduced_by field from any SRs required for VMs. *)
				List.iter
					(fun vm -> clear_sr_introduced_by ~__context:__context_to ~vm)
					vmrefs;
				vmrefs
			with e ->
				if force then
					debug "%s" "VM recovery failed - not cleaning up as action was forced."
				else begin
					debug "%s" "VM recovery failed - cleaning up.";
					Importexport.cleanup state.Import.cleanup
				end;
				raise e)
