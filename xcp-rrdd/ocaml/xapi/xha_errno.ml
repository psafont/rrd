(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(* Autogenerated by ./scripts/mtcerrno-to-ocaml.py -- do not edit *)
type code = 
| Mtc_exit_success
| Mtc_exit_invalid_parameter
| Mtc_exit_system_error
| Mtc_exit_transient_system_error
| Mtc_exit_watchdog_error
| Mtc_exit_improper_license
| Mtc_exit_can_not_read_config_file
| Mtc_exit_invalid_config_file
| Mtc_exit_can_not_access_statefile
| Mtc_exit_invalid_state_file
| Mtc_exit_generation_uuid_mismatch
| Mtc_exit_invalid_pool_state
| Mtc_exit_bootjoin_timeout
| Mtc_exit_can_not_join_existing_liveset
| Mtc_exit_daemon_is_not_present
| Mtc_exit_daemon_is_present
| Mtc_exit_invalid_environment
| Mtc_exit_invalid_localhost_state
| Mtc_exit_boot_blocked_by_excluded
| Mtc_exit_set_excluded
| Mtc_exit_internal_bug
let to_string : code -> string = function
| Mtc_exit_success -> "MTC_EXIT_SUCCESS"
| Mtc_exit_invalid_parameter -> "MTC_EXIT_INVALID_PARAMETER"
| Mtc_exit_system_error -> "MTC_EXIT_SYSTEM_ERROR"
| Mtc_exit_transient_system_error -> "MTC_EXIT_TRANSIENT_SYSTEM_ERROR"
| Mtc_exit_watchdog_error -> "MTC_EXIT_WATCHDOG_ERROR"
| Mtc_exit_improper_license -> "MTC_EXIT_IMPROPER_LICENSE"
| Mtc_exit_can_not_read_config_file -> "MTC_EXIT_CAN_NOT_READ_CONFIG_FILE"
| Mtc_exit_invalid_config_file -> "MTC_EXIT_INVALID_CONFIG_FILE"
| Mtc_exit_can_not_access_statefile -> "MTC_EXIT_CAN_NOT_ACCESS_STATEFILE"
| Mtc_exit_invalid_state_file -> "MTC_EXIT_INVALID_STATE_FILE"
| Mtc_exit_generation_uuid_mismatch -> "MTC_EXIT_GENERATION_UUID_MISMATCH"
| Mtc_exit_invalid_pool_state -> "MTC_EXIT_INVALID_POOL_STATE"
| Mtc_exit_bootjoin_timeout -> "MTC_EXIT_BOOTJOIN_TIMEOUT"
| Mtc_exit_can_not_join_existing_liveset -> "MTC_EXIT_CAN_NOT_JOIN_EXISTING_LIVESET"
| Mtc_exit_daemon_is_not_present -> "MTC_EXIT_DAEMON_IS_NOT_PRESENT"
| Mtc_exit_daemon_is_present -> "MTC_EXIT_DAEMON_IS_PRESENT"
| Mtc_exit_invalid_environment -> "MTC_EXIT_INVALID_ENVIRONMENT"
| Mtc_exit_invalid_localhost_state -> "MTC_EXIT_INVALID_LOCALHOST_STATE"
| Mtc_exit_boot_blocked_by_excluded -> "MTC_EXIT_BOOT_BLOCKED_BY_EXCLUDED"
| Mtc_exit_set_excluded -> "MTC_EXIT_SET_EXCLUDED"
| Mtc_exit_internal_bug -> "MTC_EXIT_INTERNAL_BUG"
let to_description_string : code -> string = function
| Mtc_exit_success -> ""
| Mtc_exit_invalid_parameter -> "Invalid parameter"
| Mtc_exit_system_error -> "Fatal system error"
| Mtc_exit_transient_system_error -> "Transient system error"
| Mtc_exit_watchdog_error -> "Watchdog error"
| Mtc_exit_improper_license -> "Improper license"
| Mtc_exit_can_not_read_config_file -> "Config-file is inaccessible"
| Mtc_exit_invalid_config_file -> "Invalid config-file contents"
| Mtc_exit_can_not_access_statefile -> "State-File is inaccessible"
| Mtc_exit_invalid_state_file -> "Invalid State-File contents"
| Mtc_exit_generation_uuid_mismatch -> "Generation UUID mismatch"
| Mtc_exit_invalid_pool_state -> "Invalid pool state"
| Mtc_exit_bootjoin_timeout -> "Join timeout during start"
| Mtc_exit_can_not_join_existing_liveset -> "Join is not allowed"
| Mtc_exit_daemon_is_not_present -> "Daemon is not present"
| Mtc_exit_daemon_is_present -> "Daemon is (already) present"
| Mtc_exit_invalid_environment -> "Invalid operation environment"
| Mtc_exit_invalid_localhost_state -> "Invalid local host state"
| Mtc_exit_boot_blocked_by_excluded -> "Start failed"
| Mtc_exit_set_excluded -> "Exclude flag is set while the daemon is operating"
| Mtc_exit_internal_bug -> "Internal bug"
let of_int : int -> code = function
| 0 -> Mtc_exit_success
| 1 -> Mtc_exit_invalid_parameter
| 2 -> Mtc_exit_system_error
| 3 -> Mtc_exit_transient_system_error
| 4 -> Mtc_exit_watchdog_error
| 5 -> Mtc_exit_improper_license
| 6 -> Mtc_exit_can_not_read_config_file
| 7 -> Mtc_exit_invalid_config_file
| 8 -> Mtc_exit_can_not_access_statefile
| 9 -> Mtc_exit_invalid_state_file
| 10 -> Mtc_exit_generation_uuid_mismatch
| 11 -> Mtc_exit_invalid_pool_state
| 12 -> Mtc_exit_bootjoin_timeout
| 13 -> Mtc_exit_can_not_join_existing_liveset
| 14 -> Mtc_exit_daemon_is_not_present
| 15 -> Mtc_exit_daemon_is_present
| 16 -> Mtc_exit_invalid_environment
| 17 -> Mtc_exit_invalid_localhost_state
| 18 -> Mtc_exit_boot_blocked_by_excluded
| 19 -> Mtc_exit_set_excluded
| 127 -> Mtc_exit_internal_bug
| x -> failwith (Printf.sprintf "Unrecognised MTC exit code: %d" x)
