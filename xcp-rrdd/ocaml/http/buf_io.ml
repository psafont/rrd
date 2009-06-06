(* Buffered IO with timeouts *)

module D=Debug.Debugger(struct let name="buf_io" end)
open D

type t = 
    { 
      fd : Unix.file_descr;
      mutable buf : string;
      mutable cur : int;
      mutable max : int;
    }

type err = 
    Too_long             (* Line input is > 1024 chars *)
  | No_newline           (* EOF found, with no newline *)

exception Timeout        (* Waited too long for data to appear *)
exception Eof           
exception Line of err    (* Raised by input_line only *)

let infinite_timeout = -1.


let of_fd fd =
  (* Unix.set_nonblock fd;*)
  { fd = fd;
    buf = String.create 1024; (* FIXME -- this should be larger. Low for testing *)
    cur = 0;
    max = 0;
  }

let fd_of t = t.fd

(* Internal functions *)

(* Return a copy of the data currently in the buffer *)
let get_data ic =
  let str = String.sub ic.buf ic.cur (ic.max - ic.cur) in
  str

(* Used as a temporary measure while converting from unbuffered to buffered
   I/O in the rest of the software. *)
let assert_buffer_empty ic = 
  if get_data ic <> "" then failwith "Buf_io buffer not empty"

(* Shift the unprocessed data to the beginning of the buffer *)
let shift ic =
  if ic.cur=String.length ic.buf  (* No unprocessed data!*)
  then 
    (ic.cur <- 0; ic.max <- 0;)
  else begin
      String.blit ic.buf ic.cur ic.buf 0 (ic.max - ic.cur);
      ic.max <- (ic.max - ic.cur);
      ic.cur <- 0;
  end

(* Check to see if we've got a line (ending in \n) in the buffer *)
let got_line ic =
  try
    let n = String.index_from ic.buf ic.cur '\n' in
    if n>=ic.max then -1 else n
  with
    Not_found -> -1

let is_full ic =
  ic.cur=0 && ic.max=String.length ic.buf

(* Fill the buffer with everything that's ready to be read (up to the limit of the buffer *)
let fill_buf ~buffered ic timeout =
  let buf_size = String.length ic.buf in

  let fill_no_exc timeout len =
    let l,_,_ = Unix.select [ic.fd] [] [] timeout in
    if List.length l <> 0 
    then 
      let n = Unix.read ic.fd ic.buf ic.max len in
      ic.max <- n+ic.max;
      if n=0 && len <> 0 then raise Eof;
      n 
    else
      -1
  in

  (* If there's no space to read, shift *)
  if ic.max=buf_size then shift ic;
  let space_left = buf_size - ic.max in
  
  (* Read byte one by one just do make sure we don't buffer too many chars *)
  let n = fill_no_exc timeout (if buffered then space_left else min space_left 1) in

  (* Select returned nothing to read *)
  if n= -1 then raise Timeout;

  if n = space_left then (
    shift ic;
    let tofillsz = if buffered then buf_size - ic.max else (min (buf_size - ic.max) 1) in
    ignore (fill_no_exc 0.0 tofillsz)
  )

(** Input one line terminated by \n *)
let input_line ?(timeout=60.0) ic =
  (* See if we've already input a line *)
  let n = got_line ic in

  let rec get_line () =
    fill_buf ~buffered:false ic timeout;
    let n = got_line ic in
    if n<0 && (not (is_full ic))
    then get_line ()
    else n
  in

  let n = if n<0 then get_line () else n in

  (* Still no \n? then either we've run out of data, or we've run out of space *)
  if n<0 
  then 
    if ic.max=String.length ic.buf 
    then raise (Line Too_long) 
    else (Printf.printf "got: '%s'\n" (String.sub ic.buf ic.cur (ic.max - ic.cur)); raise (Line No_newline));

  (* Return the line, stripping the newline *)
  let result = String.sub ic.buf ic.cur (n-ic.cur) in 
  ic.cur <- n + 1;
  result

(** Input 'len' characters from ic and put them into the string 'str' starting from 'from' *)
let rec really_input ?(timeout=15.0) ic str from len =
  if len=0 then () else begin 
    if ic.max - ic.cur < len then fill_buf ~buffered:true ic timeout;
    begin
      let blitlen = if ic.max - ic.cur < len then ic.max - ic.cur else len in
      String.blit ic.buf ic.cur str from blitlen;
      ic.cur <- ic.cur + blitlen;
      really_input ~timeout ic str (from+blitlen) (len-blitlen) 
    end
  end

let really_input_buf ?timeout ic len =
	let blksize = 2048 in
	let buf = Buffer.create blksize in
	let s = String.create blksize in
	let left = ref len in
	while !left > 0
	do
		let size = min blksize !left in
		really_input ?timeout ic s 0 size;
		Buffer.add_substring buf s 0 size;
		left := !left - size
	done;
	Buffer.contents buf
