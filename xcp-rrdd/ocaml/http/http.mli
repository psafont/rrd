(** Recognised HTTP methods *)
type method_t = Get | Post | Put | Connect | Unknown of string
val string_of_method_t : method_t -> string

(** Debug module *)
module D :
  sig
    val get_thread_id : unit -> int
    val name_thread : string -> unit
    val debug : ('a, unit, string, unit) format4 -> 'a
    val warn : ('a, unit, string, unit) format4 -> 'a
    val error : ('a, unit, string, unit) format4 -> 'a
  end

(** Exception raised when parsing start line of request *)
exception Http_parse_failure
exception Unauthorised of string

type authorization = 
    | Basic of string * string
    | UnknownAuth of string

(** Parsed form of the HTTP request line plus cookie info *)
type request = { m: method_t; 
		 uri: string; 
		 query: (string*string) list; 
		 version: string; 
		 transfer_encoding: string option;
		 content_length: int64 option;
		 auth: authorization option;
		 cookie: (string * string) list;
		 task: string option;
     subtask_of: string option;
		 user_agent: string option;
		 close: bool ref;
                 headers: string list;}
 
val nullreq : request
val authorization_of_string : string -> authorization
val request_of_string : string -> request
val pretty_string_of_request : request -> string

val http_request : ?version:string -> ?keep_alive:bool -> ?cookie:((string*string) list) -> ?length:(int64) -> user_agent:(string) -> method_t -> string -> string -> string list

val http_403_forbidden : string list
val http_200_ok : ?version:string -> ?keep_alive:bool -> unit -> string list

val http_200_ok_with_content : int64 -> ?version:string -> ?keep_alive:bool -> unit -> string list
val http_302_redirect : string -> string list
val http_404_missing : string list
val http_400_badrequest : string list
val http_401_unauthorised : ?realm:string -> unit -> string list
val http_406_notacceptable : string list
val http_500_internal_error : string list

(** Header used for task id *)
val task_id_hdr : string
val subtask_of_hdr : string

(** Header used for User-Agent string *)
val user_agent_hdr : string

val output_http : Unix.file_descr -> string list -> unit

val strip_cr : string -> string

(* debugging function: *)
val myprint : ('a, unit, string, unit) format4 -> 'a

val end_of_string : string -> int -> string
val parse_keyvalpairs : string -> (string * string) list

val escape : string -> string
val urlencode : string -> string

type 'a ll = End | Item of 'a * (unit -> 'a ll)
val ll_iter : ('a -> unit) -> 'a ll -> unit
