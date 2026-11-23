// SPDX-License-Identifier: GPL-2.0-or-later
'use strict';

import * as uci from "uci";
import * as mesh from "./mesh-state.uc";

function userAP(s) {
	return s.mode == "ap" && s.wifiroam_guest != "1" &&
	       index(s[".name"], "wifiroam_bh") != 0;
}

export function settings() {
	let out = [];
	let cur = uci.cursor();
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (!userAP(s) || s.disabled == "1" || !s.ssid) return;
		push(out, {
			band: cur.get("wireless", s.device, "band") ?? "?",
			ssid: s.ssid, key: s.key ?? "", encryption: s.encryption ?? "none",
			isolate: s.isolate ?? "0",
		});
	});
	return out;
}

export function sync(list, role) {
	if (type(list) != "array" || !length(list)) return { ok: true, changed: 0 };
	let cur = uci.cursor();
	if (cur.get("gwrt", "mesh_apmode", "enabled") == "0")
		return { ok: true, changed: 0 };

	let bands = {};
	for (let item in list) {
		if (type(item) != "object" || type(item.ssid) != "string" ||
		    !length(item.ssid) || length(item.ssid) > 32) continue;
		if (item.encryption != null && !match(item.encryption, /^[a-zA-Z0-9+_-]+$/)) continue;
		bands[item.band ?? "?"] ??= item;
	}
	let changed = 0;
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (!userAP(s)) return;
		let w = bands[cur.get("wireless", s.device, "band") ?? "?"];
		if (!w) return;
		let want = { ssid: w.ssid };
		if (w.encryption) want.encryption = w.encryption;
		if (w.isolate != null) want.isolate = w.isolate == "1" ? "1" : "0";
		if (w.key) {
			want.key = w.key;
			if (!w.encryption && (!s.encryption || s.encryption == "none"))
				want.encryption = "psk2";
		}
		for (let k, v in want) {
			if (s[k] == v) continue;
			if (cur.set("wireless", s[".name"], k, v)) changed++;
		}
		if ((w.encryption == "none" || w.encryption == "owe") && s.key &&
		    cur.delete("wireless", s[".name"], "key")) changed++;
	});
	if (changed && !mesh.writeConfig(cur, "wireless", role))
		return { ok: false, error: "uci", changed: 0 };
	return { ok: true, changed };
}
