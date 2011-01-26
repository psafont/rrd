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

(** XML/RPC handler for the licensing daemon *)

(** The XML/RPC interface of the licensing daemon *)
module type V6api =
	sig
		(* edition -> additional_params -> enabled_features, additional_params *)
		val apply_edition : string -> (string * string) list ->
			string * Features.feature list * (string * string) list
		(* () -> list of editions *)
		val get_editions : unit -> (string * string * string * int) list
		(* () -> result *)
		val get_version : unit -> string
		(* () -> version *)
		val reopen_logs : unit -> bool
	end  
(** XML/RPC handler *)

module V6process : functor (V : V6api) ->
	sig
		(** Process an XML/RPC call *)
		val process : Rpc.call -> Rpc.response
	end

(** {2 Marshaling functions} *)

type apply_edition_in = {
	edition_in: string;
	additional_in: (string * string) list;
}

val apply_edition_in_of_rpc : Rpc.t -> apply_edition_in
val rpc_of_apply_edition_in : apply_edition_in -> Rpc.t

type apply_edition_out = {
	edition_out: string;
	features_out: Features.feature list;
	additional_out: (string * string) list;
}

val apply_edition_out_of_rpc : Rpc.t -> apply_edition_out
val rpc_of_apply_edition_out : apply_edition_out -> Rpc.t

type names = string * string * string * int
type get_editions_out = {
	editions: names list;
}

val get_editions_out_of_rpc : Rpc.t -> get_editions_out
val rpc_of_get_editions_out : get_editions_out -> Rpc.t

