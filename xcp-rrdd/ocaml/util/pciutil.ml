(*
 * Util to parse pciids
 *)

open Stringext

(* defaults, if we can't find better information: *)
let unknown_vendor vendor = Some (Printf.sprintf "Unknown vendor %s" vendor)
let unknown_device device = Some (Printf.sprintf "Unknown device %s" device)

let parse_from file vendor device =
	let vendor_str = ref (unknown_vendor vendor) and device_str = ref (unknown_device device) in
	(* CA-26771: As we parse the file we keep track of the current vendor.
	   When we find a device match we only accept it if it's from the right vendor; it doesn't make 
	   sense to pair vendor 2's device with vendor 1. *)
	let current_xvendor = ref "" in
	Unixext.readfile_line (fun line ->
		if line = "" || line.[0] = '#' ||
		   (line.[0] = '\t' && line.[1] = '\t') then
			(* ignore subvendors/subdevices, blank lines and comments *)
			()
		else (
			if line.[0] = '\t' then (
				(* device *)
				(* ignore if this is some other vendor's device *)
				if !current_xvendor = vendor then (
					let xdevice = String.sub line 1 4 in
					if xdevice = device then (
						device_str := Some (String.sub line 7 (String.length line - 7));
						(* abort reading, we found what we want *)
						raise End_of_file
					)
				)
			) else (
				(* vendor *)
				current_xvendor := String.sub line 0 4;
				if !current_xvendor = vendor then
					vendor_str := Some (String.sub line 6 (String.length line - 6))
			)
		)
	) file;
	!vendor_str, !device_str

let parse vendor device =
	let access_list l perms =
		List.filter (fun path ->
			(try Unix.access path perms; true with _ -> false)) l
		in
	try
		(* is that the correct path ? *)
		let l = access_list [ "/usr/share/hwdata/pci.ids"; "/usr/share/misc/pci.ids" ] [ Unix.R_OK ] in
		parse_from (List.hd l) vendor device
	with _
		-> unknown_vendor vendor, unknown_device device
