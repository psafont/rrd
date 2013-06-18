open Gnt

module type Writer = sig
	type id
	type handle

	val open_handle: id -> handle
	val cleanup: handle -> unit

	val write_data: handle -> string -> unit
end

module MakeWriter = functor (W: Writer) -> struct
	let state = ref None

	let setup_signals () =
		let cleanup _ =
			match !state with
			| Some handle -> W.cleanup handle
			| None -> ()
		in
		Sys.set_signal Sys.sigint (Sys.Signal_handle cleanup)

	let start interval id =
		setup_signals ();
		let handle = W.open_handle id in
		state := Some handle;
		while true do
			W.write_data handle "data goes here";
			Thread.delay 5.0
		done
end

let with_gntshr f =
	let handle = Gntshr.interface_open () in
	let result = try
		f handle
	with e ->
		Gntshr.interface_close handle;
		raise e
	in
	Gntshr.interface_close handle;
	result

let share = ref None

let cleanup _ =
	match !share with
	| None -> ()
	| Some s ->
		with_gntshr (fun handle -> Gntshr.munmap_exn handle s)

let setup_signals () =
	Sys.set_signal Sys.sigint (Sys.Signal_handle cleanup);
	Sys.set_signal Sys.sigkill (Sys.Signal_handle cleanup)

let () =
	setup_signals ();
	let target_domid = int_of_string Sys.argv.(1) in
	share :=
		Some (with_gntshr
			(fun handle -> Gntshr.share_pages_exn handle target_domid 1 false));
	while true do
		Thread.delay 5.0
	done
