// SPDX-License-Identifier: GPL-2.0-or-later
// The wifiroam protocol supplies the pairing identity. The AP controller
// owns interface changes and consumes observations stamped with ingress.
'use strict';

import * as fs from "fs";
import * as socket from "socket";
import { unpack } from "struct";
import { sha256 } from "digest";
import * as uci from "uci";

const RUN = "/var/run/gwrt-mesh-apmode/";
const STA = "gwrt_mesh";
const SWITCH_REASONS = [
	"wired_verified", "wired_priority", "cable_lost", "wired_unavailable",
	"wired_unreachable", "wireless_verified", "wireless_lost", "search_timeout",
	"reconfigure_failed",
];

export function managed() {
	return fs.access("/usr/libexec/gwrt-mesh-apmode");
}

function switchReason(code) {
	return index(SWITCH_REASONS, code) >= 0 ? code : null;
}

function wirelessBand(band) {
	return band == "2g" || band == "5g" ? band : null;
}

export function readPhase() {
	let fields = split(trim(fs.readfile(RUN + "phase") ?? "idle 0"), " ");
	return {
		mode: fields[0], since: int(fields[1] ?? 0), ip: fields[2] == "-" ? null : fields[2],
		reason: switchReason(fields[3]), band: wirelessBand(fields[4]),
	};
}

export function ready(mode) {
	return mode == "wired" || mode == "wireless";
}

export function backhaulReport() {
	let phase = readPhase();
	return ready(phase.mode) ? { mode: phase.mode, reason: phase.reason, band: phase.band } : null;
}

export function peerBackhaul(role, peer, now) {
	let conn = peer.conn;
	// Beacons can continue after a control channel has gone away. Use a
	// status report from this authenticated TCP session, and its source IP.
	if (role != "cap" || peer.info?.role != "sap" || !peer.authed ||
	    !conn?.authed || !conn.address || conn.reported_at == null || now - conn.reported_at > 30)
		return null;
	let info = peer.info.backhaul;
	return {
		management_ip: conn.address,
		mode: ready(info?.mode) ? info.mode : null,
		reason: switchReason(info?.reason),
		band: info?.mode == "wireless" ? wirelessBand(info.band) : null,
	};
}

export function enableIngress(sock) {
	return sock.setopt(socket.IPPROTO_IP, socket.IP_PKTINFO, true);
}

export function receive(sock) {
	return sock.recvmsg(4096, 128);
}

function ingressIndex(pkt) {
	for (let c in pkt.ancillary ?? []) {
		if (c.level != socket.IPPROTO_IP || c.type != socket.IP_PKTINFO ||
		    type(c.data) != "string" || length(c.data) != 12)
			continue;
		// struct in_pktinfo: native int ifindex, then two IPv4 addresses.
		return unpack("=i", c.data)[0];
	}
	return 0;
}

export function pairingHash(token) {
	return substr(sha256("wifiroam:" + token), 0, 16);
}

export function observeCap(pkt, msg, cfg, sig) {
	if (cfg.role != "sap" || !cfg.token || msg.role != "cap" ||
	    msg.thash != sig || pkt.address?.address != cfg.cap_ip ||
	    !match(cfg.cap_ip ?? "", /^[0-9.]+$/) || !fs.access(RUN))
		return false;

	let idx = ingressIndex(pkt);
	if (idx <= 0) return false;
	let seq = "-";
	for (let f in fs.glob("/sys/class/net/*/ifindex") ?? []) {
		if (int(trim(fs.readfile(f) ?? "0")) != idx) continue;
		seq = trim(fs.readfile(replace(f, /ifindex$/, "carrier_down_count")) ?? "-");
		break;
	}
	let up = int(split(fs.readfile("/proc/uptime") ?? "0", " ")[0]);
	let path = RUN + "cap." + idx;
	if (!fs.writefile(path + ".next", sprintf("%d %s %s %s\n", up, cfg.cap_ip, sig, seq)))
		return false;
	return fs.rename(path + ".next", path);
}

export function localAddress(bus, role, mode) {
	let names = role == "cap" || mode == "wired" ? [ "lan" ] :
		mode == "wireless" ? [ STA ] : role == "unconfigured" ?
		[ STA, "wan", "wwan", "lan" ] : [ "lan" ];
	for (let name in names) {
		let s = bus.call("network.interface." + name, "status");
		let a = s?.["ipv4-address"]?.[0];
		if (a?.address) return a;
	}
	return null;
}

export function writeConfig(cur, pkg, role) {
	// SAP network/Wi-Fi changes must not commit the AP controller's staged
	// fields. Save only deltas; the router profile remains in /etc/config.
	if (managed() && (role == "sap" || fs.access(RUN + "managed") ||
	    fs.access(RUN + "prepair")) &&
	    index([ "network", "wireless", "firewall", "dhcp" ], pkg) >= 0)
		return cur.save(pkg);
	return cur.commit(pkg);
}

export function wirelessVersion() {
	return sprintf("%.J", uci.cursor().get_all("wireless") ?? {});
}

export function saveBackhaul(bh) {
	let cur = uci.cursor();
	cur.load("wifiroam");
	if (!cur.get("wifiroam", "backhaul")) cur.set("wifiroam", "backhaul", "backhaul");
	let ver = int(bh.config_ver ?? 0);
	let want = {
		enabled: bh.enabled ? "1" : "0",
		ssid: bh.ssid ?? "wifiroam-bh",
		key: bh.key ?? "",
		device: bh.device ?? "",
		config_ver: "" + ver,
	};
	for (let field in [ "band", "channel", "channel2g" ])
		if (bh[field] != null) want[field] = "" + bh[field];
	let changed = false;
	for (let k, v in want) {
		if (cur.get("wifiroam", "backhaul", k) == v) continue;
		if (!cur.set("wifiroam", "backhaul", k, v)) return { ok: false, error: "uci" };
		changed = true;
	}
	if (changed && !cur.commit("wifiroam")) return { ok: false, error: "uci" };
	return { ok: true, ver };
}

function seconds(v, fallback) {
	if (!match("" + v, /^[1-9][0-9]*$/)) return fallback;
	let n = int(v);
	return n >= 15 && n <= 3600 ? n : fallback;
}

export function getPolicy() {
	let cur = uci.cursor();
	let active = readPhase();
	let now = int(split(fs.readfile("/proc/uptime") ?? "0", " ")[0]);
	return {
		mode: active.mode, ip: active.ip, elapsed: max(0, now - active.since),
		search_seconds: seconds(cur.get("gwrt", "mesh_apmode", "search_seconds"), 120),
		router_seconds: seconds(cur.get("gwrt", "mesh_apmode", "router_seconds"), 60),
	};
}

export function setPolicy(args) {
	let search = seconds(args.search_seconds, 0);
	let router = seconds(args.router_seconds, 0);
	if (!search || !router) return { ok: false, error: "invalid_seconds" };
	let cur = uci.cursor();
	if (!cur.get("gwrt", "mesh_apmode")) return { ok: false, error: "not_configured" };
	if (!cur.set("gwrt", "mesh_apmode", "search_seconds", "" + search) ||
	    !cur.set("gwrt", "mesh_apmode", "router_seconds", "" + router) ||
	    !cur.commit("gwrt"))
		return { ok: false, error: "uci" };
	return { ok: true, search_seconds: search, router_seconds: router };
}
