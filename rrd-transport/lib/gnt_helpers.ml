open Gnt

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
