module D = Debug.Debugger(struct let name = "db_hiupgrade" end)
open D

open Stringext

(* DB upgrade steps that would be difficult to do in db_upgrade.ml

   This is an ugly hack to work around the problems with creating new rows in
   db_upgrade.ml:non_generic_db_upgrade_rules (a context is required, which
   would have to be built manually).

   This function is called during the xapi startup (xapi.ml:server_init).  By
   the time it's called we've lost information about whether we need to
   upgrade, hence it has to be idempotent.
 *)

(* !!! This function is release specific: REMEMBER TO UPDATE IT AS WE MOVE TO NEW RELEASES *)
let hi_level_db_upgrade_rules ~__context () =
	try
		let pool = List.hd (Db.Pool.get_all ~__context) in (* there can be only one *)
		(* get a Secret reference that makes sense, if there is no password ("")
		   then use null, otherwise convert if clear-text and else keep what's
		   there *)
		let wlb_passwd_ref = 
			let old_wlb_pwd = Ref.string_of (Db.Pool.get_wlb_password ~__context ~self:pool) in
			if old_wlb_pwd = ""
				then Ref.null
				else if String.startswith "OpaqueRef:" old_wlb_pwd
					then Db.Pool.get_wlb_password ~__context ~self:pool
					else Xapi_secret.create ~__context ~secret:old_wlb_pwd
		in

		Db.Pool.set_wlb_password ~__context ~self:pool ~value:wlb_passwd_ref
	with e -> error "Could not upgrade WLB configuration: '%s'" (Printexc.to_string e)
