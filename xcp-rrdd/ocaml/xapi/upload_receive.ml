open Printf

(** Start the XML-RPC server. *)
let _ =
	let http_port = ref Xapi_globs.default_cleartext_port in
	Arg.parse ([
		"-log", Arg.String (fun s ->
			if s = "all" then
				Logs.set_default Log.Debug [ "stderr" ]
			else
				Logs.add s [ "stderr" ]),
		        "open a logger to stderr to the argument key name";
		"-http-port", Arg.Set_int http_port, "set http port";
	] @ Debug.args )(fun x -> printf "Warning, ignoring unknown argument: %s" x)
	  "Receive file uploads by HTTP";

	printf "Starting server on port %d\n%!" !http_port;
	try
	  Http_svr.add_handler Put "/upload" (Http_svr.BufIO Fileupload.upload_file);
	  let sockaddr = Unix.ADDR_INET(Unix.inet_addr_of_string Xapi_globs.ips_to_listen_on, !http_port) in
	  let inet_sock = Http_svr.bind sockaddr in
	  let threads = Http_svr.http_svr [ (inet_sock,"ur_inet") ]	in
	  print_endline "Receiving upload requests on:";
	  Printf.printf "http://%s:%d/upload\n" (Helpers.get_main_ip_address ()) !http_port;
	  flush stdout;
	  List.iter Thread.join threads
	with
	  | exn -> (eprintf "Caught exception: %s\n!"
		      (ExnHelper.string_of_exn exn))
