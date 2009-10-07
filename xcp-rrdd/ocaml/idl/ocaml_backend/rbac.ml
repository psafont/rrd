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
module D = Debug.Debugger(struct let name="rbac" end)
open D

let trackid session_id = (Context.trackid_of_session (Some session_id))

(* From the Requirements:

1) Since we rely on an external directory/authentication service, disabling this
   external authentication effectively disables RBAC too. When disabled like 
   this only the local root account can be used so the system "fails secure". 
   Given this we do not need any separate mechanism to enable/disable RBAC.

2) At all times the RBAC policy will be applied; the license state will only 
   affect the Pool Administrator's ability to modify the subject -> role mapping.

3) The local superuser (root) has the "Pool Admin" role.
4) If a subject has no roles assigned then, authentication will fail with an 
   error such as PERMISSION_DENIED.

5) To guarantee the new role takes effect, the user should be logged out and 
   forced to log back in again (requires "Logout active user connections" permission)
   (So, there's no need to update the session immediately after modifying either the 
   Subject.roles field or the Roles.subroles field, or for this function to
   immediately reflect any modifications in these fields without the user logging out
   and in again)

    *  Definitions:
    * R = { "Pool Admin" "Pool Operator" "VM Power Admin" "VM Admin" "VM Operator" "Read Only" }
          o i.e. R is the static set of roles
    * perm(r) = the static set of permissions associated with role r
          o e.g. perm("Pool Admin") gives the "Pool Admin" column from the above table
    * subject_role(sid) = the set of roles assigned to subject sid
          o This is the user-configurable subject -> role mapping
    * subject(s) = the unique subject ID associated with the user who logged in and got session s
    * groups(sid) = the set of group subject IDs associated with user subject ID sid
          o Note that a user is allowed to log in either because subject(s) is explicitly listed or because one or more of groups(sid) is explicitly listed

    * A session s will be permitted to call a XenAPI function associated with permission p iff
          o p is a member of all_perms(s) where
                + all_perms(s) = Union over r in roles(s) of perm(r) where
                      # roles(s) = Union over sid in all_sids(s) of subject_role(sid) where
                            * all_sids(s) = Union(subject(s), groups(subject(s))
    * and denied otherwise.

Intuitively the 3 nested Unions above come from the 3 one -> many relationships:
1. a session (i.e. a user) has multiple subject IDs;
2. a subject ID has multiple roles;
3. a role has multiple permissions.

*)

(* efficient look-up structures *)
(* Speed-up rbac lookup: (session_ref, permissions set) hashtabl *)
let session_permissions_tbl = Hashtbl.create 256 (* initial 256 sessions *)
module Permission_set = Set.Make(String)
(* This flag enables efficient look-up of the permission set *)
let use_efficient_permission_set = true

let permission_set permission_list = 
	List.fold_left
		(fun set r->Permission_set.add r set)
		Permission_set.empty
		permission_list

let create_session_permissions_tbl ~session_id ~rbac_permissions =
	if use_efficient_permission_set
		&& Pool_role.is_master () (* Create this structure on the master only, *)
		                          (* so as to avoid heap-leaking on the slaves *)
	then begin
		debug "Creating permission-set tree for session %s"
			(Context.trackid_of_session (Some session_id));
		let permission_tree = (permission_set rbac_permissions) in
		Hashtbl.replace session_permissions_tbl session_id permission_tree;
		Some(permission_tree)
	end
	else
		None

let destroy_session_permissions_tbl ~session_id =
	if use_efficient_permission_set then
		Hashtbl.remove
			session_permissions_tbl
			session_id

let is_permission_in_session ~session_id ~permission ~session =
	let find_linear elem set = List.exists (fun e -> e = elem) set in
	let find_log elem set = Permission_set.mem elem set in
	if use_efficient_permission_set then
	begin (* use efficient log look-up of permissions *)
		let permission_tree = 
			try Some(Hashtbl.find session_permissions_tbl session_id)
			with Not_found -> begin
					create_session_permissions_tbl
						~session_id
						~rbac_permissions:session.API.session_rbac_permissions
				end
		in match permission_tree with
		| Some(permission_tree) -> find_log permission permission_tree
		| None -> find_linear permission session.API.session_rbac_permissions
	end
	else (* use linear look-up of permissions *)
		find_linear permission session.API.session_rbac_permissions

open Db_actions

(* look up the list generated in xapi_session.get_permissions *)
let is_access_allowed ~__context ~session_id ~permission =

	(* always allow local system access *)
	if Session_check.is_local_session __context session_id
	then true

	(* normal user session *)
	else 
	let session = DB_Action.Session.get_record ~__context ~self:session_id in
	(* the root user can always execute anything *)
	if session.API.session_is_local_superuser
	then true

	(* not root user, so let's decide if permission is allowed or denied *)
	else
		is_permission_in_session ~session_id ~permission ~session


(* Execute fn if rbac access is allowed for action, otherwise fails. *)
let nofn = fun () -> ()
let check ?(extra_dmsg="") ?(extra_msg="") ?args ~__context ~fn session_id action =

	(* all permissions are in lowercase, see gen_rbac.writer_ *)
	let permission = String.lowercase action in
	
	if (is_access_allowed ~__context ~session_id ~permission)
	then (* allow access to action *)
	begin
		try
			let result = (fn ()) (* call rbac-protected function *)
			in
			Rbac_audit.allowed_ok ~__context ~session_id ~action
					~permission ?args ~result ();
			result
		with error-> (* catch all exceptions *)
			begin
				Rbac_audit.allowed_error ~__context ~session_id ~action 
					~permission ?args ~error ();
				raise error
			end
	end
	else (* deny access to action *)
	begin
		let msg=(Printf.sprintf "No permission in user session%s" extra_msg) in
		debug "%s[%s]: %s %s %s" action permission msg (trackid session_id) extra_dmsg;
		Rbac_audit.denied ~__context ~session_id ~action ~permission 
			?args ();
		raise (Api_errors.Server_error 
			(Api_errors.rbac_permission_denied,[permission;msg]))
	end

let get_session_of_context ~__context ~permission =
	try (Context.get_session_id __context)
	with Failure _ -> raise (Api_errors.Server_error
		(Api_errors.rbac_permission_denied,[permission;"no session in context"]))

let assert_permission_name ~__context ~permission =
	let session_id = get_session_of_context ~__context ~permission in
	check ~__context ~fn:nofn session_id permission

let assert_permission ~__context ~permission =
	assert_permission_name ~__context ~permission:permission.role_name_label

(* this is necessary to break dependency cycle between rbac and taskhelper *)
let init_task_helper_rbac_has_permission_fn =
	if !TaskHelper.rbac_assert_permission_fn = None
	then TaskHelper.rbac_assert_permission_fn := Some(assert_permission)

let has_permission_name ~__context ~permission =
	let session_id = get_session_of_context ~__context ~permission in
	is_access_allowed ~__context ~session_id ~permission

let has_permission ~__context ~permission =
	has_permission_name ~__context ~permission:permission.role_name_label

let check_with_new_task ?(extra_dmsg="") ?(extra_msg="") ?(task_desc="check") 
		?args ~fn session_id action =
	let task_desc = task_desc^":"^action in
	Server_helpers.exec_with_new_task task_desc
		(fun __context -> 
			check ~extra_dmsg ~extra_msg ~__context ?args ~fn session_id action
		)

(* used by xapi_http.ml to decide if rbac checks should be applied *)
let is_rbac_enabled_for_http_action http_action_name =
	not 
		(List.mem http_action_name Datamodel.public_http_actions_with_no_rbac_check)

