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
module Audit = Debug.Debugger(struct let name="audit" end)
module D = Debug.Debugger(struct let name="rbac_audit" end)

(* Rbac Audit fields:

    * Already existing fields in debug records:
          o $timestamp
          o type ('info')
          o $hostname
          o $xapi thread number
          o $xapi task name/id
          o 'audit' (the record key indicating an API call audit record)

    * Extra RBAC-specific fields for _side-effecting_ API calls (CP-706) as s-exprs
      (ie. read-only calls to DB fields are not currently logged):
          o $session's trackid
          o $session's subject_identifier (when available)
          o $session's username (when available)
          o ('DENIED'|'ALLOWED')
          o ('OK'|'ERROR:'$exception/error code field)
          o $call type ('api'|'http')
          o $api/http call name [for http-level operations, at least import/export,host/pool-backup,guest/host-console-access]
          o $important-call-parameters (eg. vm_uuid, host_uuid), as s-exprs
                + human-readable names for each important-call-parameters (eg. vm_name, host_name)
*)

let trackid session_id = (Context.trackid_of_session (Some session_id))

open Db_actions
open Db_filter_types


let is_http action = 
	Stringext.String.startswith Datamodel.rbac_http_permission_prefix action

let call_type_of ~action =
	if is_http action then "HTTP" else "API"

let str_local_session = "LOCAL_SESSION"
let str_local_superuser = "LOCAL_SUPERUSER"


let get_subject_common ~__context ~session_id ~fnname
	~fn_if_local_session ~fn_if_local_superuser ~fn_if_subject =
	try
		if Session_check.is_local_session __context session_id
		then (fn_if_local_session ())
		else
		if (DB_Action.Session.get_is_local_superuser ~__context ~self:session_id)
		then (fn_if_local_superuser ()) 
		else (fn_if_subject ())
	with
		| e -> begin 
				D.debug "error %s for %s:%s"
					fnname (trackid session_id) (ExnHelper.string_of_exn e);
				"" (* default value returned after an internal error *)
			end

let get_subject_identifier __context session_id =
	get_subject_common ~__context ~session_id
		~fnname:"get_subject_identifier"
		~fn_if_local_session:(fun()->str_local_session)
		~fn_if_local_superuser:(fun()->str_local_superuser)
		~fn_if_subject:(
			fun()->DB_Action.Session.get_auth_user_sid ~__context ~self:session_id
		)

let get_subject_name __context session_id =
	get_subject_common ~__context ~session_id
		~fnname:"get_subject_name"
		~fn_if_local_session:(fun()->"")
		~fn_if_local_superuser:(fun()->"")
		~fn_if_subject:(fun()->
			let sid =
				DB_Action.Session.get_auth_user_sid ~__context ~self:session_id
			in
			let subjs = DB_Action.Subject.get_records_where ~__context
				~expr:(Eq(Field "subject_identifier", Literal (sid)))
			in
			if List.length subjs > 1 then
				failwith (Printf.sprintf
					"More than one subject for subject_identifier %s"sid
				);
			let (subj_id,subj) = List.hd subjs in
			List.assoc
				"subject-name" (*Auth_signature.subject_information_field_subject_name*)
				subj.API.subject_other_config
		)

(*given a ref-value, return a human-friendly value associated with that ref*)
let get_obj_of_ref_common obj_ref fn =
		let indexrec = Ref_index.lookup obj_ref in
		match indexrec with
		| None -> None
		| Some indexrec -> fn indexrec

let get_obj_of_ref obj_ref =
	get_obj_of_ref_common obj_ref
		(fun irec -> Some(irec.Ref_index.name_label, irec.Ref_index.uuid, irec.Ref_index._ref))

let get_obj_name_of_ref obj_ref =
	get_obj_of_ref_common obj_ref (fun irec -> irec.Ref_index.name_label)

let get_obj_uuid_of_ref obj_ref =
	get_obj_of_ref_common obj_ref (fun irec -> Some(irec.Ref_index.uuid))

let get_obj_ref_of_ref obj_ref =
	get_obj_of_ref_common obj_ref (fun irec -> Some(irec.Ref_index._ref))

let get_sexpr_arg name name_of_ref uuid_of_ref ref_value : SExpr.t =
	SExpr.Node
		( (* s-expr lib should properly escape malicious values *)
			(SExpr.String name)::
			(SExpr.String name_of_ref)::
			(SExpr.String uuid_of_ref)::
			(SExpr.String ref_value):: 
			[]
		)

(* given a list of (name,'',ref-value) triplets, *)
(* map '' -> friendly-value of ref-value. *)
(* used on the master to map missing reference names from slaves *)
let get_obj_names_of_refs (obj_ref_list : SExpr.t list) : SExpr.t list=
	List.map
		(fun obj_ref ->
			match obj_ref with
				|SExpr.Node (SExpr.String name::SExpr.String ""::
						SExpr.String ""::SExpr.String ref_value::[]) ->
					get_sexpr_arg
						name
						(match (get_obj_name_of_ref ref_value) with 
							 | None -> "" (* ref_value is not a ref! *)
							 | Some obj_name -> obj_name (* the missing name *)
						)
						(match (get_obj_uuid_of_ref ref_value) with 
							 | None -> "" (* ref_value is not a ref! *)
							 | Some obj_uuid -> obj_uuid (* the missing uuid *)
						)
						ref_value
				|_->obj_ref (* do nothing if not a triplet *)
		)
		obj_ref_list

(* unwrap the audit record and add names to the arg refs *)
(* this is necessary because we can only obtain the ref names *)
(* on the master, and http audit records can come from slaves *)
let populate_audit_record_with_obj_names_of_refs line =
	try
		let sexpr_idx = (String.index line ']') + 1 in
		let before_sexpr_str = String.sub line 0 sexpr_idx in
		(* remove the [...] prefix *)
		let sexpr_str = Stringext.String.sub_to_end line sexpr_idx in
		let sexpr = SExpr_TS.of_string sexpr_str	in
		match sexpr with
		|SExpr.Node els -> begin
				if List.length els = 0
				then line
				else
				let (args:SExpr.t) = List.hd (List.rev els) in
				(match List.partition (fun (e:SExpr.t) ->e<>args) els with
					|prefix, ((SExpr.Node arg_list)::[]) ->
						(* paste together the prefix of original audit record *) 
						before_sexpr_str^" "^
						(SExpr.string_of 
						(SExpr.Node (
							prefix@
							((SExpr.Node (get_obj_names_of_refs arg_list))::
							[])
						))
						)
					|prefix,_->line
				)
			end
		|_->line
	with e ->
		D.debug "error populating audit record arg names: %s" 
			(ExnHelper.string_of_exn e)
		;
		line

(* Map selected xapi call arguments into audit sexpr arguments.
    Not all parameters are mapped into audit log arguments because
    some, like passwords, are sensitive and should not be persisted
    into the audit log. Use heuristics to map non-sensitive parameters.
*)
let sexpr_args_of name xml_value =
	(* heuristic 1: print descriptive arguments in the xapi call *)
	if (List.mem name ["name";"label";"description";"name_label";"name_description"])
	then
	( match xml_value with
		| Xml.PCData value -> Some (get_sexpr_arg name value "" "")
		|_->None
	)
	else
	(* heuristic 2: print uuid/refs arguments in the xapi call *)
	match xml_value with
	| Xml.PCData value -> (
		let name_uuid_ref = get_obj_of_ref value in
		match name_uuid_ref with
		| None ->
			if Stringext.String.startswith Ref.ref_prefix value
			then (* it's a ref, just not in the db cache *)
				Some (get_sexpr_arg name "" "" value)
			else (* ignore values that are not a ref *)
				None
		| Some(_name_of_ref_value, uuid_of_ref_value, ref_of_ref_value) ->
			let name_of_ref_value = (match _name_of_ref_value with|None->""|Some a -> a) in
			Some (get_sexpr_arg name name_of_ref_value uuid_of_ref_value ref_of_ref_value)
		)
	|_-> None

(* Given an action and its parameters, *)
(* return the marshalled uuid params and corresponding names *)
let rec sexpr_of_parameters action args : SExpr.t list =
	match args with
	| None -> []
	| Some (str_names,xml_values) -> 
	begin
	if (List.length str_names) <> (List.length xml_values)
	then
		( (* debug mode *)
		D.debug "cannot marshall arguments for the action %s: name and value list lengths don't match. str_names=[%s], xml_values=[%s]" action ((List.fold_left (fun ss s->ss^s^",") "" str_names)) ((List.fold_left (fun ss s->ss^(Xml.to_string s)^",") "" xml_values));
		[]
		)
	else
	List.fold_right2
		(fun str_name xml_value (params:SExpr.t list) ->
			if str_name = "session_id" 
			then params (* ignore session_id param *)
			else 
			(* if it is a constructor structure, need to rewrap params *)
			if str_name = "__structure"
			then match xml_value with 
				| Xml.Element (_,_,(Xml.Element ("struct",_,iargs))::[]) ->
						let (myparam:SExpr.t list) =
							(sexpr_of_parameters action (Some
							(List.fold_right
								(fun xml_arg (acc_xn,acc_xv) ->
									match xml_arg with
									| Xml.Element ("member",_,
											(Xml.Element ("name",_,(Xml.PCData xn)::[])
											::(Xml.Element ("value",_,x) as xv)
											::[]
											)
										) -> xn::acc_xn, xv::acc_xv
									| _ -> acc_xn,acc_xv
								)
								iargs
								([],[])
							)
						))
						in myparam@params
				| xml_value ->
					(match (sexpr_args_of str_name xml_value)
					 with None->params|Some p->p::params
					)
			else 
			(* the expected list of xml arguments *)
			begin
				let name,filtered_xml_value = 
					match xml_value with
					(* try to pick up only the xml value *)
					| Xml.Element ("value", _, v::[]) ->
							(match v with
							| Xml.Element ("string",_,v::[]) -> str_name,v
							| _ -> str_name,v
						)
					| _ -> str_name,xml_value
				in
				(match (sexpr_args_of name filtered_xml_value)
				 with None->params|Some p->p::params
				)
			end
		)
		str_names
		xml_values
		[]
	end

let has_to_audit action =
	let has_side_effect action =
		not (Stringext.String.has_substr action ".get") (* TODO: a bit slow? *)
	in
	has_side_effect action
	&&
	not ( (* these actions are ignored *)
		List.mem action 
			[ (* list of _actions_ filtered out from the audit log *)
				"session.local_logout"; (* session logout have their own *)
				"session.logout"; (* rbac_audit calls, because after logout *)
				                  (* the session is destroyed and no audit is possible*)
				"event.next"; (* this action is just spam in the audit log*)
				"http/get_rrd_updates"; (* spam *)
				"http/post_remote_db_access"; (* spam *)
				"host.tickle_heartbeat"; (* spam *)
			]
	)

let wrap fn =
	try fn () 
	with e -> (* never bubble up the error here *) 
		D.debug "ignoring %s" (ExnHelper.string_of_exn e)

let sexpr_of __context session_id allowed_denied ok_error result_error ?args action permission =
  let result_error = 
		if result_error = "" then result_error else ":"^result_error
	in
	(*let (params:SExpr.t list) = (string_of_parameters action args) in*)
	SExpr.Node (
		SExpr.String (trackid session_id)::
    SExpr.String (get_subject_identifier __context session_id)::
    SExpr.String (get_subject_name __context session_id)::
		SExpr.String (allowed_denied)::		
		SExpr.String (ok_error ^ result_error)::
    SExpr.String (call_type_of action)::
		(*SExpr.String (Helper_hostname.get_hostname ())::*)
    SExpr.String action::
    (SExpr.Node (sexpr_of_parameters action args))::
		[]
	)

let append_line = Audit.audit

let fn_append_to_master_audit_log = ref None

let audit_line_of __context session_id allowed_denied ok_error result_error action permission ?args =
	let _line = 
		(SExpr.string_of 
			 (sexpr_of __context session_id allowed_denied 
					ok_error result_error ?args action permission
			 )
		)
	in
	let line = Stringext.String.replace "\n" " " _line in (* no \n in line *)
	let line = Stringext.String.replace "\r" " " line in (* no \r in line *)

	let audit_line = append_line "%s" line in
	(*D.debug "line=%s, audit_line=%s" line audit_line;*)
	match !fn_append_to_master_audit_log with 
		| None -> () 
		| Some fn -> fn __context action audit_line

let allowed_ok ~__context ~session_id ~action ~permission ?args ?result () =
	wrap (fun () ->
		if has_to_audit action then 
			audit_line_of __context session_id "ALLOWED" "OK" "" action permission ?args
	)

let allowed_error ~__context ~session_id ~action ~permission ?args ?error () =
	wrap (fun () ->
		if has_to_audit action then
			let error_str = 
				match error with
				| None -> ""
				| Some error -> (ExnHelper.string_of_exn error)
			in
			audit_line_of __context session_id "ALLOWED" "ERROR" error_str action permission ?args
	)
	
let denied ~__context ~session_id ~action ~permission ?args () =
	wrap (fun () ->
		if has_to_audit action then
			audit_line_of __context session_id "DENIED" "" "" action permission ?args
	)

let session_destroy ~__context ~session_id =
(*	
	(* this is currently only creating spam in the audit log *)
	let action="session.destroy" in
	allowed_ok ~__context ~session_id ~action ~permission:action ()
*)
	()

let session_create ~__context ~session_id =
(*
	(* this is currently only creating spam in the audit log *)
	let action="session.create" in
	allowed_ok ~__context ~session_id ~action ~permission:action ()
*)
	()
