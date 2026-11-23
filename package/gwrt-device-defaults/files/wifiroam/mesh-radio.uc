// SPDX-License-Identifier: GPL-2.0-or-later
// Hidden backhaul radios on the main AP; satellites are configured separately.
'use strict';

import * as uci from "uci";
import * as mesh from "./mesh-state.uc";
const BACKHAUL_SECTION = "wifiroam_bh";

function pick_radio_by_band(band, preferred) {
	let first = null;
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-device", function(r) {
		if (r.disabled == "1" || r.band != band) return;
		if (r[".name"] == preferred || first == null) first = r[".name"];
	});
	return first;
}

function radio_running_channel(bus, dev) {
	let ch = 0;
	let cur = uci.cursor();
	cur.load("wireless");
	let c = cur.get("wireless", dev, "channel") ?? "";
	if (match(c, /^[0-9]+$/)) ch = int(c);
	if (ch > 0) return ch;
	// channel=auto：从运行中的 AP 接口读
	let ws = bus.call("network.wireless", "status") ?? {};
	for (let rname, r in ws) {
		if (rname != dev) continue;
		for (let ifc in r.interfaces ?? {}) {
			if (!ifc.ifname) continue;
			let info = bus.call("iwinfo", "info", { device: ifc.ifname });
			if ((info?.channel ?? 0) > 0) return int(info.channel);
		}
	}
	return 0;
}

export function applyCap(bh, bus, reloadWifi) {
	let cur = uci.cursor();
	cur.load("wireless");
	let before = mesh.wirelessVersion();
	if (bh.enabled && bh.ssid && bh.key) {
		// Keep a three-address hidden AP on each available band.
		let r5 = pick_radio_by_band("5g", bh.device);
		let r2 = pick_radio_by_band("2g", bh.device);
		let ch = r5 ? radio_running_channel(bus, r5) : 0;
		let ch2 = r2 ? radio_running_channel(bus, r2) : 0;
		for (let spec in [ [BACKHAUL_SECTION, r5], [BACKHAUL_SECTION + "2", r2] ]) {
			let sec = spec[0], dev = spec[1];
			if (!dev) {
				if (cur.get("wireless", sec) != null) cur.delete("wireless", sec);
				continue;
			}
			if (cur.get("wireless", sec) == null)
				cur.set("wireless", sec, "wifi-iface");
			cur.set("wireless", sec, "device", dev);
			cur.set("wireless", sec, "mode", "ap");
			cur.set("wireless", sec, "ssid", bh.ssid);
			cur.set("wireless", sec, "encryption", "psk2+ccmp");
			cur.set("wireless", sec, "key", bh.key);
			cur.set("wireless", sec, "network", "lan");
			cur.set("wireless", sec, "wds", "0");
			cur.set("wireless", sec, "hidden", "1");
			cur.set("wireless", sec, "disabled", "0");
		}
		bh.channel = ch;
		bh.channel2g = ch2;
	} else {
		cur.delete("wireless", BACKHAUL_SECTION);
		cur.delete("wireless", BACKHAUL_SECTION + "2");
	}
	if (!mesh.writeConfig(cur, "wireless", "cap")) return { ok: false, error: "uci" };
	let result = mesh.saveBackhaul(bh);
	if (mesh.wirelessVersion() != before)
		reloadWifi();
	return result;
}
