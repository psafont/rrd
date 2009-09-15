val populate: Parse_db_conf.db_connection -> unit
val flush_dirty: Parse_db_conf.db_connection -> bool
val force_flush_all: Parse_db_conf.db_connection -> Db_cache_types.cache option -> unit
val read_schema_vsn: Parse_db_conf.db_connection -> int*int
val create_empty_db: Parse_db_conf.db_connection -> unit
val populate_and_read_manifest: Parse_db_conf.db_connection -> Db_cache_types.db_dump_manifest
val notify_delete: Parse_db_conf.db_connection -> string -> string -> unit
val flush_db_to_redo_log: Db_cache_types.cache -> unit
