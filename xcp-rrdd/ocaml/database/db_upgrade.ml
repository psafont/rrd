
module D = Debug.Debugger(struct let name = "xapi" (* this is set to 'xapi' deliberately! :) *) end)
open D

open Stringext
open Vm_memory_constraints

(* ---------------------- upgrade db file from last release schema -> current schema.

   upgrade_from_last_release contains the generic mechanism for upgrade (i.e. filling in default values
   specified in IDL).

   There are also some non-generic db upgrade rules coded specifically in non_generic_db_upgrade_rules.

   For Orlando we have to make these rules idempontent and run them on _every_ master populate. This
   makes sure we'll run them from MiamiGA->Orlando, as well as beta_x->Orlando etc. etc. (for the
   beta upgrades we don't have the luxury of a db schema version change to trigger off.) If we can
   get this done earlier for the next release we can trigger off the schema vsn change again..
*)

module Names = Db_names

let (+++) = Int64.add

(* -- Orlando upgrade code removed, now we're doing next release
(* Since these transformations are now run on _every_ Orlando master start we combine everything into a single pass of the VM records
   for efficiency.. *)
let upgrade_vm_records () =
	let vm_table = Db_backend.lookup_table_in_cache Names.vm in
	let vm_rows = Db_backend.get_rowlist vm_table in
	(* Upgrade the memory constraints of each virtual machine. *)
	List.iter (fun vm_row ->
		(* Helper functions to access the database. *)
		let get field_name = Int64.of_string (Db_backend.lookup_field_in_row vm_row field_name) in
		let set field_name value = Db_backend.set_field_in_row vm_row field_name (Int64.to_string value) in

		(* Fetch the current memory constraints. *)
		let constraints = {Vm_memory_constraints.
			static_min  = get Names.memory_static_min;
			dynamic_min = get Names.memory_dynamic_min;
			target      = get Names.memory_target;
			dynamic_max = get Names.memory_dynamic_max;
			static_max  = get Names.memory_static_max;
		} in

		if (Db_backend.lookup_field_in_row vm_row Names.is_control_domain = "true") then
		begin
			(* Upgrades the memory constraints for every host's domain zero record.  *)
			(* The new constraints must be:                                          *)
			(*   1. valid from the point of view of non-upgraded Miami hosts         *)
			(*      (they must not cause any change in memory balloon size for non-  *)
			(*      upgraded hosts during a rolling upgrade from Miami to Orlando);  *)
			(*   2. untransformably invalid from the point of view of Orlando hosts  *)
			(*      (even after static_{min,max} are recalculated during startup).   *)
			(*      This will cause the constraints to be regenerated by the         *)
			(*      create_domain_zero_default_memory_constraints function when a    *)
			(*      freshly-upgraded Orlando host boots for the very first time.     *)
			(* The correctness of this function is important to the success of a     *)
			(* rolling upgrade from Miami to Orlando. The sequence is as follows:    *)
			(*   1. Upgrade master.                                                  *)
			(*   2. Master comes back and updates the memory constraints for every   *)
			(*      host's domain 0 record (this function).                          *)
			(*   3. Master runs the update_domain_zero_record function for its own   *)
			(*      domain 0 record (but no-one elses). This causes a fresh default  *)
			(*      set of memory constraints to be generated for the master only.   *)
			(*   4. Each slave restarts and connects to the master. After restarting *)
			(*      a slave receives a copy of the upgraded database. Miami slaves   *)
			(*      read the value of dynamic_max when determining their balloon     *)
			(*      target, whose value remains unchanged by this function.          *)
			(*   5. When a slave is upgraded, it runs the update_domain_zero_record  *)
			(*      function for its own domain 0 record (but no-one elses), causing *)
			(*      a fresh default set of memory constraints to be generated.       *)
			set Names.memory_dynamic_min (constraints.Vm_memory_constraints.dynamic_max +++ 1L);
		end else
		(** Upgrades memory constraints for each VM record by giving memory_target   *)
		(** an initial value equal to the existing value of memory_dynamic_max. In   *)
		(** addition, attempts to transform any invalid constraints into valid ones. *)
		begin
			(* Take the original constraints and add target := dynamic_max *)
			let constraints = {constraints with
				Vm_memory_constraints.target =
					if   constraints.Vm_memory_constraints.target = 0L
					then constraints.Vm_memory_constraints.dynamic_max
					else constraints.Vm_memory_constraints.target;
			} in
			(* Attempt to transform the original constraints into valid constraints. *)
			(* If the transformation fails, then just keep the original constraints. *)
			let constraints = match Vm_memory_constraints.transform constraints with
				| Some transformed_constraints -> transformed_constraints
				| None -> constraints in
			(* Write the new (possibly-transformed) constraints back to the database. *)
			set Names.memory_static_min  constraints.Vm_memory_constraints.static_min;
			set Names.memory_dynamic_min constraints.Vm_memory_constraints.dynamic_min;
			set Names.memory_target      constraints.Vm_memory_constraints.target;
			set Names.memory_dynamic_max constraints.Vm_memory_constraints.dynamic_max;
			set Names.memory_static_max  constraints.Vm_memory_constraints.static_max;
		end;

	) vm_rows

let update_templates () =
	let vm_table = Db_backend.lookup_table_in_cache Names.vm in
	let vm_rows = Db_backend.get_rowlist vm_table in
	(* Upgrade the memory constraints of each virtual machine. *)
	List.iter (fun vm_row ->
		(* CA-18974: We accidentally shipped Miami creating duplicate keys in template other-config; need to strip these out across
		   upgrade *)
		let other_config = Db_backend.lookup_field_in_row vm_row Names.other_config in
		let other_config_kvs = String_unmarshall_helper.map (fun x->x) (fun x->x) other_config in
		(* so it turns out that it was actually the (k,v) pair as a whole that was duplicated,
		   so we can just call setify on the whole key,value pair list directly;
		   we don't have to worry about setifying the keys separately *)
		let dups_removed = Listext.List.setify other_config_kvs in
		(* marshall again and write back to dbrow *)
		let dups_removed = String_marshall_helper.map (fun x->x) (fun x->x) dups_removed in
		Db_backend.set_field_in_row vm_row Names.other_config dups_removed;

		if bool_of_string (Db_backend.lookup_field_in_row vm_row Names.is_a_template) &&
		  (List.mem_assoc Xapi_globs.default_template_key other_config_kvs) then
		    let default_template_key_val = List.assoc Xapi_globs.default_template_key other_config_kvs in
		    if default_template_key_val="true" then
		      begin
			(* CA-18035: Add viridian flag to built-in templates (_not custom ones_) across upgrade *)
			let platform = Db_backend.lookup_field_in_row vm_row Names.platform in
			let platform_kvs = String_unmarshall_helper.map (fun x->x) (fun x->x) platform in
			let platform_kvs =
			  if not (List.mem_assoc Xapi_globs.viridian_key_name platform_kvs) then
			    (Xapi_globs.viridian_key_name,Xapi_globs.default_viridian_key_value)::platform_kvs else platform_kvs in
			let platform_kvs = String_marshall_helper.map (fun x->x) (fun x->x) platform_kvs in
			Db_backend.set_field_in_row vm_row Names.platform platform_kvs;

			(* CA-19924 If template name is "Red Hat Enterprise Linux 5.2" || "Red Hat Enterprise Linux 5.2 x64" then we need to ensure that
			   we have ("machine-address-size", "36") in other_config. This is because the RHEL5.2 template changed between beta1 and beta2
			   and we need to make sure it's the same after upgrade..
			*)
			let template_name_label = Db_backend.lookup_field_in_row vm_row Names.name_label in
			let other_config = Db_backend.lookup_field_in_row vm_row Names.other_config in
			let other_config = String_unmarshall_helper.map (fun x->x) (fun x->x) other_config in
			let other_config =
			  if (template_name_label="Red Hat Enterprise Linux 5.2" || template_name_label="Red Hat Enterprise Linux 5.2 x64")
			    && (not (List.mem_assoc Xapi_globs.machine_address_size_key_name other_config)) then
			      (Xapi_globs.machine_address_size_key_name, Xapi_globs.machine_address_size_key_value)::other_config else other_config in
			let other_config = String_marshall_helper.map (fun x->x) (fun x->x) other_config in
			Db_backend.set_field_in_row vm_row Names.other_config other_config

		      end
	) vm_rows
*)

(* !!! This fn is release specific: REMEMBER TO UPDATE IT AS WE MOVE TO NEW RELEASES *)
let non_generic_db_upgrade_rules () =

	(* GEORGE -> MIDNIGHT RIDE *)
	let vm_table = Db_backend.lookup_table_in_cache Names.vm in
	let vm_rows = Db_backend.get_rowlist vm_table in
	let update_snapshots vm_row =
		let vm = Db_backend.lookup_field_in_row vm_row Names.ref in
		let snapshot_rows = List.filter (fun s -> Db_backend.lookup_field_in_row s Names.snapshot_of = vm) vm_rows in
		let snapshot_rows = List.filter (fun s -> Db_backend.lookup_field_in_row s Names.parent = Ref.string_of Ref.null) snapshot_rows in
		let compare s1 s2 =
			let t1 = Db_backend.lookup_field_in_row s1 Names.snapshot_time in
			let t2 = Db_backend.lookup_field_in_row s2 Names.snapshot_time in
			compare t1 t2 in
		let ordered_snapshot_rows = List.sort compare snapshot_rows in
		let rec aux = function
			| [] -> ()
			| [s] -> ()
			| s1 :: s2 :: t ->
				Db_backend.set_field_in_row s2 Names.parent (Db_backend.lookup_field_in_row s1 Names.ref);
				aux (s2 :: t) in
		aux ordered_snapshot_rows in
	List.iter update_snapshots vm_rows

let upgrade_from_last_release dbconn =
  debug "Database schema version is that of last release: attempting upgrade";

  (* !!! UPDATE THIS WHEN MOVING TO NEW RELEASE !!! *)
  let old_release = Datamodel_types.rel_george in
  let this_release = Datamodel_types.rel_midnight_ride in

  let objs_in_last_release =
    List.filter (fun x -> List.mem old_release x.Datamodel_types.obj_release.Datamodel_types.internal) Db_backend.api_objs in
  let table_names_in_last_release =
    List.map (fun x->Gen_schema.sql_of_obj x.Datamodel_types.name) objs_in_last_release in

  let objs_in_this_release =
    List.filter (fun x -> List.mem this_release x.Datamodel_types.obj_release.Datamodel_types.internal) Db_backend.api_objs in
  let table_names_in_this_release =
    List.map (fun x->Gen_schema.sql_of_obj x.Datamodel_types.name) objs_in_this_release in

  let table_names_new_in_this_release =
    List.filter (fun tblname -> not (List.mem tblname table_names_in_last_release)) table_names_in_this_release in
  
  (* populate gets all field names from the existing (old) db file, not the (current) schema... which is nice: *)
  Db_connections.populate dbconn table_names_in_last_release;

  (* we also have to ensure that the in-memory cache contains the new tables added in this release that will not have been
     created by the proceeding populate (cos this is restricted to table names in last release). Unless the new tables are
     explicitly added to the in-memory cache they will not be written out into the new db file across upgrade. [Turns out
     you get away with this in the sqlite backend since there the tables are created from the schema_file; in the XML
     backend you're not so lucky, so this needs to be made explicit..
  *)
  let create_blank_table_in_cache tblname =
    let newtbl = Hashtbl.create 20 in
    Db_backend.set_table_in_cache tblname newtbl in
  List.iter create_blank_table_in_cache table_names_new_in_this_release;

  (* for each table, go through and fill in missing default values *)
  let add_default_fields_to_tbl tblname =
    let tbl = Db_backend.lookup_table_in_cache tblname in
    let rows = Db_backend.get_rowlist tbl in
    let add_fields_to_row r =
      let kvs = Hashtbl.fold (fun k v env -> (k,v)::env) r [] in
      let new_kvs = Db_backend.add_default_kvs kvs tblname in
      (* now blank r and fill it with new kvs: *)
      Hashtbl.clear r;
      List.iter (fun (k,v) -> Hashtbl.replace r k v) new_kvs in
    List.iter add_fields_to_row rows in

  (* Go and fill in default values *)
  List.iter add_default_fields_to_tbl table_names_in_last_release;
  
  non_generic_db_upgrade_rules();

  (* Now do the upgrade: *)
  (* 1. move existing db out of the way *)
  Unix.rename dbconn.Parse_db_conf.path (dbconn.Parse_db_conf.path ^ ".prev_version." ^ (string_of_float (Unix.gettimeofday())));
  let dbconn_to_flush_to = Db_connections.preferred_write_db() in
  (* 2. create a new empty db file (with current schema) *)
  Db_connections.create_empty_db dbconn_to_flush_to;
  (* 3. mark all tables we want to write data into as dirty, and all rows as new *)
  List.iter
    (fun tname ->
	   Db_dirty.set_all_dirty_table_status tname;
	   let rows = Db_backend.get_rowlist (Db_backend.lookup_table_in_cache tname) in
	   let objrefs = List.map (fun row -> Db_backend.lookup_field_in_row row Db_backend.reference_fname) rows in
	   List.iter (fun objref->Db_dirty.set_all_row_dirty_status objref Db_dirty.New) objrefs
    )
    table_names_in_last_release;
  debug "Database upgrade complete, restarting to use new db";
  (* 4. flush and exit with restart return code, so watchdog kicks xapi off again (this time with upgraded db) *)
  ignore (Db_connections.flush_dirty_and_maybe_exit dbconn_to_flush_to (Some Xapi_globs.restart_return_code))

exception Schema_mismatch

(* Maybe upgrade most recent db *)
let maybe_upgrade most_recent_db =
  debug "Considering upgrade...";
  let major_vsn, minor_vsn = Db_connections.read_schema_vsn most_recent_db in
  debug "Db has schema major_vsn=%d, minor_vsn=%d (current is %d %d) (last is %d %d)" major_vsn minor_vsn Datamodel.schema_major_vsn Datamodel.schema_minor_vsn Datamodel.last_release_schema_major_vsn Datamodel.last_release_schema_minor_vsn;
  begin
    if major_vsn=Datamodel.schema_major_vsn && minor_vsn=Datamodel.schema_minor_vsn then
      () (* current vsn: do nothing *)
    else if major_vsn=Datamodel.last_release_schema_major_vsn && minor_vsn=Datamodel.last_release_schema_minor_vsn then begin
      upgrade_from_last_release most_recent_db
      (* Note: redo log is not active at present because HA is always disabled before an upgrade. *)
      (* If this ever becomes not the case, consider invalidating the redo-log here (using Redo_log.empty()). *)
    end else raise Schema_mismatch
  end
