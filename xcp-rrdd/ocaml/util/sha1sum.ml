module D = Debug.Debugger(struct let name="sha1sum" end)
open D

(** Path to the sha1sum binary (used in the new import/export code to append checksums *)
let sha1sum = "/usr/bin/sha1sum"

open Pervasiveext
open Stringext

(** Helper function to prevent double-closes of file descriptors *)
let close to_close fd = 
  if List.mem fd !to_close then Unix.close fd;
  to_close := List.filter (fun x -> fd <> x) !to_close 

(** Fork a slave sha1sum process, execute a function with the input file descriptor
    and return the result of sha1sum, guaranteeing to reap the process. *)
let sha1sum f = 
    let input_out, input_in = Unix.pipe () in
    let result_out, result_in = Unix.pipe () in

    Unix.set_close_on_exec result_out;
    Unix.set_close_on_exec input_in;
    
    let to_close = ref [ input_out; input_in; result_out; result_in ] in
    let close = close to_close in

    finally
      (fun () ->
	 let args = [] in
	 let pid = Forkhelpers.safe_close_and_exec
	  [ Forkhelpers.Dup2(result_in, Unix.stdout);
	    Forkhelpers.Dup2(input_out, Unix.stdin) ]
	  [ Unix.stdout; Unix.stdin; ] (* close all but these *)
	  sha1sum args in

	 close result_in;
	 close input_out;

	 finally
	   (fun () -> 
	      finally
		(fun () -> f input_in)
		(fun () -> close input_in);
	      let buffer = String.make 1024 '\000' in
	      let n = Unix.read result_out buffer 0 (String.length buffer) in
	      let raw = String.sub buffer 0 n in
	      let result = match String.split ' ' raw with
		| result :: _ -> result
		| _ -> failwith (Printf.sprintf "Unable to parse sha1sum output: %s" raw) in
	      close result_out;
	      result)
	   (fun () ->
	      match Unix.waitpid [] pid with
	      | _, Unix.WEXITED 0 -> ()
	      | _, _ -> 
		  let msg = "sha1sum failed (non-zero error code or signal?)" in
		  error "%s" msg;
		  failwith msg
	   )
      ) (fun () -> List.iter close !to_close)


