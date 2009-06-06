(* Make VDIs with ext2 filesystems on them *)
open Vmopshelpers
open Pervasiveext
open Client
open Printf

module D=Debug.Debugger(struct let name="xapi" end)
open D

let make_tmp_dir() =
	let tmp_file = Filename.temp_file "xapi_mount_" "" in
	Unix.unlink tmp_file;
	Unix.mkdir tmp_file 0o640;
	tmp_file

(** Block-attach a VDI to dom0 and run 'f' with the device name *)
let with_block_attached_device __context rpc session_id vdi mode f = 
  let dom0 = Helpers.get_domain_zero ~__context in
  Attach_helpers.with_vbds rpc session_id __context dom0 [ vdi ] mode
    (fun vbds ->
       let vbd = List.hd vbds in
       f ("/dev/" ^ (Db.VBD.get_device ~__context ~self:vbd)))

(** Execute a function with a list of device paths after attaching a bunch of VDIs to dom0 *)
let with_block_attached_devices (__context: Context.t) rpc (session_id: API.ref_session) (vdis: API.ref_VDI list) mode f = 
  let rec loop acc = function
    | [] -> f (List.rev acc)
    | vdi :: vdis -> with_block_attached_device __context rpc session_id vdi mode (fun path -> loop (path :: acc) vdis) in
  loop [] vdis


(** Catch those smint exceptions and convert into meaningful internal errors *)
let with_api_errors f x = 
  try f x
  with
  | Smint.Command_failed(ret, status, stdout_log, stderr_log)
  | Smint.Command_killed(ret, status, stdout_log, stderr_log) ->
      let msg = Printf.sprintf "Smint.Command_{failed,killed} ret = %d; status = %s; stdout = %s; stderr = %s"
	ret status stdout_log stderr_log in
      raise (Api_errors.Server_error (Api_errors.internal_error, [msg]))

(** Mount a filesystem somewhere, with optional type *)
let mount ?ty:(ty = None) src dest =
  let ty = match ty with None -> [] | Some ty -> [ "-t"; ty ] in
  ignore(Forkhelpers.execute_command_get_output "/bin/mount" (ty @ [ src; dest ]))
    
let timeout = 300. (* 5 minutes: something is seriously wrong if we hit this timeout *)
exception Umount_timeout
  
(** Unmount a mountpoint. Retries every 5 secs for a total of 5mins before returning failure *)
let umount ?(retry=true) dest =
  let finished = ref false in
  let start = Unix.gettimeofday () in
  
  while not(!finished) && (Unix.gettimeofday () -. start < timeout) do
    try
      ignore(Forkhelpers.execute_command_get_output "/bin/umount" [dest] ); 
      finished := true
    with e ->
      if not(retry) then raise e;
      debug "Caught exception (%s) while unmounting %s: pausing before retrying"
	(ExnHelper.string_of_exn e) dest;
      Thread.delay 5.
  done;
  if not(!finished) then raise Umount_timeout

let with_mounted_dir device mount_point rmdir f =
  finally 
    (fun () -> 
      debug "About to create mount point (perhaps)";
      let output, _ = Forkhelpers.execute_command_get_output "/bin/mkdir" ["-p"; mount_point] in
      debug "Mountpoint created (output=%s)" output;
      with_api_errors (mount ~ty:(Some "ext2") device) mount_point;
      debug "Mounted";
      f mount_point)
    (fun () ->
      Helpers.log_exn_continue ("with_fs_vdi: unmounting " ^ mount_point) 
	(fun () -> umount mount_point) ();
      Helpers.log_exn_continue ("with_fs_vdi: rmdir " ^ mount_point)
	(fun () -> if rmdir then Unix.rmdir mount_point) ())  
    
(** Block-attach a VDI to dom0, mount an ext2 filesystem and run 'f' with the mountpoint *)
let with_fs_vdi __context vdi f = 
  Helpers.call_api_functions ~__context
    (fun rpc session_id ->
     with_block_attached_device __context rpc session_id vdi `RW
       (fun device ->
	  let mount_point = make_tmp_dir () in
	  with_mounted_dir device mount_point true f
	 )
    )

(** Stick ext2 filesystem on VDI and turn off maximal mount count + checking interval *)
let mke2fs device =
  ignore(Forkhelpers.execute_command_get_output "/sbin/mkfs" ["-t"; "ext2"; device]);
  ignore(Forkhelpers.execute_command_get_output "/sbin/tune2fs"  ["-i"; "0"; "-c"; "0"; device])

(** Create a new VDI, block attach it to dom0, create an ext2 filesystem,
    run 'f' with the vdi_ref and the mountpoint. Leave the VDI around, unless there is
    an exception in which case we delete it. *)
let with_new_fs_vdi __context ~name_label ~name_description ~sR ~required_space ~_type ~sm_config f =
  	let add_fs_overhead req =
		let fs_overhead_factor = 1.05 (* allow 5% overhead for ext2 *) in
		(Int64.of_float ((Int64.to_float req)*.fs_overhead_factor))
		in
	Helpers.call_api_functions ~__context
	  (fun rpc session_id ->
	    let vdi_ref = Client.VDI.create ~rpc ~session_id
	      ~name_label ~name_description ~sR ~virtual_size:(add_fs_overhead required_space)
	      ~sharable:false ~read_only:false ~_type ~other_config:[] ~xenstore_data:[] ~sm_config ~tags:[] in	      
	    try
	      with_block_attached_device __context rpc session_id vdi_ref `RW
		(fun device ->
		  with_api_errors
		      (fun () ->
			mke2fs device;
			(* Mount it *)
			let mount_point = make_tmp_dir() in
			with_mounted_dir device mount_point true (f vdi_ref)
		      ) ()
		)
	    with e ->
	      debug "Caught error (%s) during with_new_fs_vdi: deleting created VDI" (ExnHelper.string_of_exn e);
	      Client.VDI.destroy ~rpc ~session_id ~self:vdi_ref;
	      raise e
	  )
	  
exception Cancelled
exception NonZero

(* dd with sparseness check *)
let sparse_dd refresh_session ~__context sparse ifd ofd size bs =
  let round v = int_of_float (v *. 50.0) in
  let update = 
    let oldvalue = ref (-1.0) in
    fun value ->  
      if round value <> round !oldvalue then begin
	TaskHelper.exn_if_cancelling ~__context;
	TaskHelper.operate_on_db_task ~__context 
	  (fun self -> 
	    Db.Task.set_progress ~__context ~self ~value);
      end;
      oldvalue := value
  in

  let buf = String.create bs in
  
  let allzero s n =
    try
      for i=0 to n-1 do
        if s.[i] <> '\000' then raise NonZero
      done;
      true
    with NonZero -> false
  in

  let rec do_block offset =
    refresh_session ();

    update ((Int64.to_float offset) /. (Int64.to_float size));   
    let remaining = Int64.sub size offset in
    if remaining=0L 
    then ()  (* EOF *)
    else
      begin
	let this_chunk = Int64.to_int (min remaining (Int64.of_int bs)) in
	Unixext.really_read ifd buf 0 this_chunk;
	begin
	  if sparse && (allzero buf this_chunk)
          then
	    ignore(Unix.LargeFile.lseek ofd (Int64.of_int this_chunk) Unix.SEEK_CUR)
	  else
	    let n = Unix.write ofd buf 0 this_chunk in
	    (if n<this_chunk then failwith "Error!")
	end;
	do_block (Int64.add offset (Int64.of_int this_chunk))
      end
  in
  do_block 0L;
  update 1.0
    
let copy_vdi ~__context vdi_src vdi_dst = 
  TaskHelper.set_cancellable ~__context;

  let rpc = Helpers.make_rpc ~__context in
  let session_id = Context.get_session_id __context in
  let refresh_session = Xapi_session.consider_touching_session rpc session_id in

  debug "copy vdi";

  (* Use the sparse copy if the src and dest are of type ext or nfs *)
  let sparse = 
    let sr_src = Db.VDI.get_SR ~__context ~self:vdi_src in
    let sr_dst = Db.VDI.get_SR ~__context ~self:vdi_dst in
    let src_ty = Db.SR.get_type ~__context ~self:sr_src in
    let dst_ty = Db.SR.get_type ~__context ~self:sr_dst in
    ((src_ty="nfs")||(src_ty="ext")) && ((dst_ty="nfs")||(dst_ty="ext"))
  in

  let size = Db.VDI.get_virtual_size ~__context ~self:vdi_src in
  
  debug "use sparse copy: %b" sparse;

  let dd = sparse_dd refresh_session ~__context sparse in

  with_block_attached_device __context rpc session_id vdi_src `RO
    (fun device_src ->
       with_block_attached_device __context rpc session_id vdi_dst `RW
	 (fun device_dst ->
	    let ifd=Unix.openfile device_src [Unix.O_RDONLY] 0o600 
	    and ofd=Unix.openfile device_dst [Unix.O_WRONLY] 0o600 in
	    try
	      dd ifd ofd size (1024*1024);
	      Unix.close ifd;
	      Unix.close ofd
	    with
	      e ->
		debug "Caught exception %s" (ExnHelper.string_of_exn e);
		log_backtrace ();
		Unix.close ifd;
		Unix.close ofd
	 )
    )
	      

