(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *)

open Network_utils

open Fun
open Stringext
open Listext
open Threadext

module D = Debug.Debugger(struct let name = "network_monitor_thread" end)
open D

let failed_again = ref false

(** Table for bonds status. *)
let bonds_status : (string, (int * int)) Hashtbl.t = Hashtbl.create 10
let bonds_status_update : (string * int) list ref = ref []
let bonds_status_update_m = Mutex.create ()

let add_bond_status bond links_up =
	Mutex.execute bonds_status_update_m (fun _ ->
		bonds_status_update := !bonds_status_update @ [(bond,links_up)]
	)

let xapi_rpc =
	let open Xmlrpc_client in
	XML_protocol.rpc ~http:(xmlrpc ~version:"1.0" "/")
		~transport:(Unix (Filename.concat Fhs.vardir "xapi"))

let send_bond_change_alert dev nb_links links_up nb_links_old links_up_old interfaces =
	let ifaces = String.concat "+" (List.sort String.compare interfaces) in
	let module XenAPI = Client.Client in
	let session_id = XenAPI.Session.slave_local_login_with_password
		~rpc:xapi_rpc ~uname:"" ~pwd:"" in
	Pervasiveext.finally
		(fun _ ->
			let obj_uuid = Util_inventory.lookup Util_inventory._installation_uuid in
			let body = Printf.sprintf
				"The status of the %s bond changed: %d/%d up (was %d/%d)"
				ifaces links_up nb_links links_up_old nb_links_old in
			try
				let (_: 'a Ref.t) = XenAPI.Message.create ~rpc:xapi_rpc ~session_id
					~name:Api_messages.bond_status_changed ~priority:1L ~cls:`Host
					~obj_uuid ~body in ()
			with _ ->
				warn "Exception sending a bond-status-change alert."
		)
		(fun _ -> XenAPI.Session.local_logout ~rpc:xapi_rpc ~session_id)

let check_for_changes ~(dev : string) ~(stat : Network_monitor.iface_stats) =
	let open Network_monitor in
	match String.startswith "vif" dev with false -> () | true ->
	if stat.nb_links > 1 then ( (* It is a bond. *)
		if Hashtbl.mem bonds_status dev then (
			let nb_links_old, links_up_old = Hashtbl.find bonds_status dev in
			if links_up_old <> stat.links_up then ( (* Seen before. *)
				info "Bonds status changed: %s nb_links %d up %d up_old %d" dev stat.nb_links
				stat.links_up links_up_old;
				send_bond_change_alert dev stat.nb_links stat.links_up nb_links_old
					links_up_old stat.interfaces;
				Hashtbl.replace bonds_status dev (stat.nb_links,stat.links_up);
				add_bond_status dev stat.links_up
			)
		) else ( (* Seen for the first time. *)
			info "New bonds status: %s nb_links %d up %d" dev stat.nb_links stat.links_up;
			Hashtbl.add bonds_status dev (stat.nb_links,stat.links_up);
			add_bond_status dev stat.links_up
		)
	)

let rec monitor () =
	let open Network_interface in
	let open Network_monitor in
	(try
		let devs = ref [] in

		let standardise_name name =
			try
				let (d1,d2) = Scanf.sscanf name "tap%d.%d"
					(fun d1 d2 -> d1,d2) in
				let newname = Printf.sprintf "vif%d.%d" d1 d2 in
				newname
			with _ -> name
		in

		let f line =
			if String.contains line ':' then (
				let flds = String.split_f (fun c -> c = ' ' || c = ':') line in
				let flds = List.filter (fun field -> field <> "") flds in
				let name = standardise_name (List.nth flds 0) in
				let vs = List.map (fun i ->
					try Int64.of_string (List.nth flds i) with _ -> 0L)
					[ 1; 2; 3; 9; 10; 11; ] in
				let eth_stat = {default_stats with
					rx_bytes = List.nth vs 0;
					rx_pkts = List.nth vs 1;
					rx_errors = List.nth vs 2;
					tx_bytes = List.nth vs 3;
					tx_pkts = List.nth vs 4;
					tx_errors = List.nth vs 5;
				} in
				(* CA-23291: no good can come of recording 'dummy' device stats *)
				if not(String.startswith "dummy" name) &&
					not(String.startswith "xenbr" name) &&
					not(String.startswith "xapi" name) &&
					not(String.startswith "eth" name && String.contains name '.')
				then devs := (name,eth_stat) :: (!devs)
			)
		in
		Unixext.readfile_line f "/proc/net/dev";

		let make_bond_info (name, interfaces) =
			let devs = List.filter (fun (name', _) -> List.mem name' interfaces) !devs in
			let eth_stat = {default_stats with
				rx_bytes = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.rx_bytes) 0L devs;
				rx_pkts = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.rx_pkts) 0L devs;
				rx_errors = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.rx_errors) 0L devs;
				tx_bytes = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.tx_bytes) 0L devs;
				tx_pkts = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.tx_pkts) 0L devs;
				tx_errors = List.fold_left (fun ac (_, stat) -> Int64.add ac stat.tx_errors) 0L devs;
			} in
			name, eth_stat
		in
		let bonds : (string * string list) list = Network_server.Bridge.get_all_bonds () ~from_cache:true () in
		devs := (List.map make_bond_info bonds) @ !devs;

		let transform_taps () =
			let newdevnames = List.setify (List.map fst !devs) in
			let newdevs = List.map (fun name ->
				let devs = List.filter (fun (n,x) -> n=name) !devs in
				let tot = List.fold_left (fun acc (_,b) ->
					{default_stats with
					 rx_bytes = Int64.add acc.rx_bytes b.rx_bytes;
					 rx_pkts = Int64.add acc.rx_pkts b.rx_pkts;
					 rx_errors = Int64.add acc.rx_errors b.rx_errors;
					 tx_bytes = Int64.add acc.tx_bytes b.tx_bytes;
					 tx_pkts = Int64.add acc.tx_pkts b.tx_pkts;
					 tx_errors = Int64.add acc.tx_errors b.tx_errors}) default_stats devs
				in
				(name,tot)
			) newdevnames
			in
			devs := newdevs
		in

		transform_taps ();

		devs := List.map (fun (dev, stat) ->
			if not (String.startswith "vif" dev) then begin
				let devs =
					if List.mem_assoc dev bonds then
						List.assoc dev bonds
					else
						[dev]
				in
				let vendor_id, device_id = if List.length devs = 1 then Sysfs.get_pci_ids dev else "", "" in
				let speed, duplex =
					let int_of_duplex = function
						| Duplex_half -> 1
						| Duplex_full -> 2
						| Duplex_unknown -> 0
					in
					let duplex_of_int = function
						| 1 -> Duplex_half
						| 2 -> Duplex_full
						| _ -> Duplex_unknown
					in
					let statuses = List.map (fun dev ->
						let speed, duplex =
							try
								Bindings.get_status dev
							with _ ->
								0,
								Duplex_unknown
						in
						speed, int_of_duplex duplex
					) devs in
					let speed, duplex =
						List.fold_left (fun (speed, duplex) (speed', duplex') -> (speed + speed'), (min duplex duplex')) (0, 2) statuses
					in
					speed, duplex_of_int duplex
				in
				let nb_links = List.length devs in
				let carrier = List.exists Sysfs.get_carrier devs in
				let get_interfaces name =
					let bonds = Network_server.Bridge.get_all_bonds () ~from_cache:true () in
					let interfaces = (try List.assoc dev bonds with _ -> []) in
					interfaces in
				let (links_up,interfaces) = (if nb_links > 1 then
						(Network_server.Bridge.get_bond_links_up () dev, get_interfaces dev)
					else
						((if carrier then 1 else 0), [dev]))
				in
				let pci_bus_path = if List.length devs = 1 then Sysfs.get_pcibuspath dev else "" in
				let stat = {stat with carrier; speed; duplex; pci_bus_path; vendor_id;
					device_id; nb_links; links_up; interfaces} in
				check_for_changes ~dev ~stat;
				dev, stat
			end else
				dev, stat
		) (!devs);

		write_stats !devs;
		failed_again := false
	with e ->
		if not !failed_again then begin
			failed_again := true;
			debug "Error while collecting stats (suppressing further errors): %s\n%s"
				(Printexc.to_string e) (Printexc.get_backtrace ())
		end
	);

	Thread.delay interval;
	monitor ()

let start () =
	debug "Starting network monitor";
	let (_ : Thread.t) = Thread.create monitor () in
	()

