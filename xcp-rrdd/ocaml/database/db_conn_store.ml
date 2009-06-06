(* ------------------- List of db connections that are active (read from db.conf file) *)

let db_connections : Parse_db_conf.db_connection list ref = ref [] (* initalised by ocaml/xapi/xapi.ml *)
exception Cannot_populate_database (* should never be thrown *)
exception No_db_connections_available

(* Locks for each db connection *)
let db_conn_locks_m = Mutex.create() (* mutex used to protect access to table of mutexes -- nice! *)
let db_conn_locks = Hashtbl.create 5

(* This fn is not threadsafe. We only call it on start of day, before parallel threads have been forked *)
let initialise_db_connections dbs =
  (* create a lock for each of our db connections *)
  Threadext.Mutex.execute db_conn_locks_m
    (fun () ->
     List.iter (fun dbconn->Hashtbl.replace db_conn_locks dbconn (Mutex.create())) dbs);
  db_connections := dbs
    
let read_db_connections() = !db_connections

let with_db_conn_lock db_conn f =
  let db_conn_m =
    Threadext.Mutex.execute db_conn_locks_m
      (fun () ->
	 try
	   Hashtbl.find db_conn_locks db_conn
	 with _ ->
	   (* If we don't have a lock already for this connection then go make one dynamically and use that from then on *)
	   begin
	     let new_dbconn_mutex = Mutex.create() in
	     Hashtbl.replace db_conn_locks db_conn new_dbconn_mutex;
	     new_dbconn_mutex
	   end
      ) in
  Threadext.Mutex.execute db_conn_m
    (fun () ->
       f ())
