// SPDX-License-Identifier: GPL-2.0-or-later
// wifiroamd - multi-AP topology & 802.11k/v/r roaming orchestration daemon
// Roles: cap (controller AP) / sap (satellite AP) / unconfigured
//
// ucode notes:
//  - for (v in array) iterates VALUES; for (k, v in obj) iterates key+value
//  - libubus.open_channel(sock, rx_cb, disconnect_cb); rx_cb(req) single arg
//  - channel.request({method, data, return:"ignore"}) fire & forget
//  - channel.defer({method, data, data_cb, cb}) request/response
'use strict';

import * as libubus from "ubus";
import * as uloop from "uloop";
import * as socket from "socket";
import * as fs from "fs";
import * as uci from "uci";
import { sha256 } from "digest";

// ---------------------------------------------------------------- constants
const UDP_PORT = 50607;
const TCP_PORT = 50608;
const MAGIC = "WIFIROAM1";
const ALIAS_DIR = "/etc/wifiroam";
const ALIAS_PATH = ALIAS_DIR + "/aliases.json";
const PEER_TTL = 30;        // s without hello -> offline
const DISCOVER_TTL = 180;   // s unconfigured device stays in discover list
const HELLO_INTERVAL = 5000;
const TICK_INTERVAL = 10000;
const MAX_EVENTS = 100;
const WIRED_TTL = 300;    // s wired client stays listed after last FDB sighting
const STEER_COOLDOWN = 60;  // s 同一终端两次 BSS Transition 引导的最小间隔
const MIN_STEER_ASSOC = 20; // s 终端入网后至少稳定这么久才允许被引导
const BACKHAUL_SECTION = "wifiroam_bh";
const BACKHAUL_DEFAULT_SSID = "wifiroam-bh";
// 协议/行为版本：LuCI 侧要求一致，不一致时「重启」会自动 stop+start 修复
const DAEMON_VERSION = 2;

const ROAM_KEYS = [
	"ieee80211r", "mobility_domain", "ft_over_ds", "ft_psk_generate_local",
	"nas_identifier", "pmk_r1_push", "r0kh", "r1kh", "reassociation_deadline",
	"ieee80211k", "rrm_neighbor_report", "rrm_beacon_report",
	"ieee80211v", "bss_transition",
];

// ------------------------------------------------------------------ globals
let daemon_started = time();  // 进程启动时刻，用于识别「重启后仍是旧进程」
let ubusc;              // ubus connection
let udp_sock;           // discovery socket
let tcp_srv;            // sync listen socket

// 前向声明：ucode 单遍编译不提升函数声明，使用点必须晚于绑定点
let sap_report, push_aliases_to, push_roam_to, push_backhaul_to, apply_result_update, apply_backhaul_result_update, ensure_token, reconfigure, conn_close;

let state = {
	cfg: {},            // uci wifiroam
	self: {},           // self system info
	brdev: "br-lan",
	peers: {},          // macnorm -> AP peer (hello + report merged)
	discovered: {},     // macnorm -> unconfigured device seen
	aliases: { ver: 0, map: {} },
	link: null,         // SAP: outgoing channel to CAP {sock,chan,authed}
	cap_learned: null,  // CAP ip learned from hello
	events: [],         // ring buffer
	last_apply: null,   // last roam push result summary
	last_backhaul: null, // last wireless-backhaul push result summary
	client_seen: {},    // macnorm -> first seen ts
	prev_clients: null, // for join/leave event diffing; null = 首轮扫描不产事件
	wired_seen: {},     // macnorm -> 最后一次出现在 FDB 的时间（有线存活依据+防抖）
	prev_owner: null,   // CAP 视角 macnorm -> 归属 AP（跨 AP 迁移事件；null = 首轮抑制）
	roam_ver_applied: 0,
	backhaul_ver_applied: 0,
	steer_last: {},     // macnorm -> 上次 BSS Transition 引导时间
	net_names: {},      // SAP: CAP 下发的 macnorm -> { hostname, ip }（SAP 无 DHCP，名称需由 CAP 提供）
	roster: null,       // SAP: CAP 下发的全网络 AP/SSID 概览（用于开启前检查一致展示）
};

// ------------------------------------------------------------------ helpers
function log(msg) { printf("wifiroam: %s\n", msg); }

function macnorm(m) { return lc(replace(m ?? "", /[^0-9a-fA-F]/g, "")); }

function maccolon(mn) {
	if (length(mn) != 12) return mn;
	return uc(substr(mn,0,2)+":"+substr(mn,2,2)+":"+substr(mn,4,2)+":"+
	          substr(mn,6,2)+":"+substr(mn,8,2)+":"+substr(mn,10,2));
}

// xorshift32 伪随机（避免依赖 ucode-mod-math 的 rand/srand）
let rng_state = 0;
function srand(seed) {
	rng_state = int(seed) & 0x7fffffff;
	if (rng_state == 0) rng_state = 0x9e3779b9;
}
function rand() {
	rng_state ^= (rng_state << 13) & 0x7fffffff;
	rng_state ^= rng_state >> 17;
	rng_state ^= (rng_state << 5) & 0x7fffffff;
	return rng_state & 0x7fffffff;
}

function randhex(n) {
	let s = "";
	for (let i = 0; i < n; i++)
		s += sprintf("%x", rand() % 16);
	return s;
}

function cmd_output(cmd) {
	let f = fs.popen(cmd, "r");
	if (!f) return "";
	let out = f.read("all");
	f.close();
	return out ?? "";
}

function push_event(type, mac, info, name) {
	push(state.events, { ts: time(), type, mac: mac ?? "", name: name ?? "", info: info ?? "" });
	if (length(state.events) > MAX_EVENTS)
		state.events = slice(state.events, length(state.events) - MAX_EVENTS);
	log(sprintf("event %s %s %s %s", type, mac ?? "-", name ?? "-", info ?? ""));
}

// 终端展示名：自定义别名 > 本机/对端主机名 > 本网络名称表 > MAC
// local 传入本次已有客户端表（local_clients / peer clients），避免重复扫描
function client_name_of(mn, local) {
	let al = state.aliases.map[mn];
	if (al?.name != null && al.name != "") return al.name;

	let c = local?.[mn];
	if (c?.hostname != null && c.hostname != "") return c.hostname;

	for (let pmn, p in state.peers) {
		let pc = p.clients?.[mn];
		if (pc?.hostname != null && pc.hostname != "") return pc.hostname;
	}

	let n = state.net_names?.[mn];
	if (n?.hostname != null && n.hostname != "") return n.hostname;

	return maccolon(mn);
}

function field_after(words, key) {
	let i = index(words, key);
	return i >= 0 ? words[i + 1] : null;
}

// ------------------------------------------------------------- uci handling
function load_config() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	state.cfg = {
		enabled: cur.get("wifiroam", "core", "enabled") != "0",
		role: cur.get("wifiroam", "core", "role") ?? "unconfigured",
		token: cur.get("wifiroam", "core", "token") ?? "",
		cap_ip: cur.get("wifiroam", "core", "cap_ip") ?? "",
		name: cur.get("wifiroam", "core", "name") ?? "",
	};
	state.roam_ver_applied = int(cur.get("wifiroam", "roam", "config_ver") ?? "0");
	state.backhaul_ver_applied = int(cur.get("wifiroam", "backhaul", "config_ver") ?? "0");
	let aver = int(cur.get("wifiroam", "alias_sync", "ver") ?? "0");
	if (aver > state.aliases.ver) state.aliases.ver = aver;
}

function save_config() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	cur.set("wifiroam", "core", "role", state.cfg.role);
	cur.set("wifiroam", "core", "token", state.cfg.token);
	cur.set("wifiroam", "core", "cap_ip", state.cfg.cap_ip);
	cur.set("wifiroam", "core", "name", state.cfg.name);
	cur.commit("wifiroam");
}

function rssi_preset(profile) {
	return { aggressive: -62, balanced: -70, conservative: -78 }[profile] ?? -70;
}

function current_roam_cfg() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let ssids = [];
	let raw = cur.get("wifiroam", "roam", "ssids");
	if (type(raw) == "array") ssids = raw;
	else if (type(raw) == "string" && raw != "") ssids = [ raw ];
	let profile = cur.get("wifiroam", "roam", "rssi_profile") ?? "balanced";
	if (index([ "aggressive", "balanced", "conservative", "custom" ], profile) < 0)
		profile = "balanced";
	let threshold = int(cur.get("wifiroam", "roam", "rssi_threshold") ?? rssi_preset(profile));
	if (profile != "custom") threshold = rssi_preset(profile);
	if (threshold > -30) threshold = -30;
	if (threshold < -95) threshold = -95;
	return {
		enabled: cur.get("wifiroam", "roam", "enabled") == "1",
		ssids,
		r_fast: cur.get("wifiroam", "roam", "r_fast") != "0",
		ft_mode: cur.get("wifiroam", "roam", "ft_mode") ?? "simple",
		ft_over_ds: cur.get("wifiroam", "roam", "ft_over_ds") != "0",
		k_neighbor: cur.get("wifiroam", "roam", "k_neighbor") != "0",
		k_beacon: cur.get("wifiroam", "roam", "k_beacon") != "0",
		v_bss_transition: cur.get("wifiroam", "roam", "v_bss_transition") != "0",
		rssi_profile: profile,
		rssi_threshold: threshold,
		config_ver: int(cur.get("wifiroam", "roam", "config_ver") ?? "0"),
	};
}

// 漫游配置内容签名：SAP 上报本地已落盘配置的签名，CAP 据此判断是否与主 AP 一致。
// 只比 ver 无法发现历史遗留的不一致（旧版 SAP 只落盘 ver/enabled，其他字段仍是默认值）。
function roam_sig(r) {
	return sha256(sprintf("%d|%s|%d|%s|%d|%d|%d|%d|%s|%d",
		r.enabled ? 1 : 0, join(",", r.ssids ?? []), r.r_fast ? 1 : 0,
		r.ft_mode ?? "simple",
		r.ft_over_ds ? 1 : 0, r.k_neighbor ? 1 : 0, r.k_beacon ? 1 : 0,
		r.v_bss_transition ? 1 : 0, r.rssi_profile ?? "balanced",
		r.rssi_threshold ?? rssi_preset(r.rssi_profile)));
}

function current_backhaul_cfg() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	return {
		enabled: cur.get("wifiroam", "backhaul", "enabled") == "1",
		ssid: cur.get("wifiroam", "backhaul", "ssid") ?? BACKHAUL_DEFAULT_SSID,
		key: cur.get("wifiroam", "backhaul", "key") ?? "",
		device: cur.get("wifiroam", "backhaul", "device") ?? "",
		band: cur.get("wifiroam", "backhaul", "band") ?? "auto",
		channel: int(cur.get("wifiroam", "backhaul", "channel") ?? "0"),
		channel2g: int(cur.get("wifiroam", "backhaul", "channel2g") ?? "0"),
		config_ver: int(cur.get("wifiroam", "backhaul", "config_ver") ?? "0"),
	};
}

// ------------------------------------------------------------ alias storage
function alias_load() {
	try {
		let data = json(fs.readfile(ALIAS_PATH));
		if (type(data) == "object") {
			state.aliases.map = data.map ?? {};
			if ((data.ver ?? 0) > state.aliases.ver)
				state.aliases.ver = data.ver;
		}
	} catch (e) { /* first boot */ }
}

function alias_save() {
	fs.mkdir(ALIAS_DIR);
	fs.writefile(ALIAS_PATH, sprintf("%.J", state.aliases));
	let cur = uci.cursor();
	cur.load("wifiroam");
	cur.set("wifiroam", "alias_sync", "ver", "" + state.aliases.ver);
	cur.commit("wifiroam");
}

function alias_apply(mac, name, icon, note) {
	let mn = macnorm(mac);
	if (length(mn) != 12) return false;
	if ((name ?? "") == "" && !icon && !note)
		delete state.aliases.map[mn];
	else
		state.aliases.map[mn] = {
			name: name ?? "", icon: icon ?? null, note: note ?? null,
		};
	state.aliases.ver = time();
	alias_save();
	return true;
}

function alias_broadcast() {
	if (state.cfg.role != "cap") return;
	for (let mn, p in state.peers) {
		if (!p.authed || !p.chan) continue;
		try {
			p.chan.defer({
				method: "push_aliases",
				data: { aliases: state.aliases },
				data_cb: function() {}, cb: function() {},
			});
		} catch (e) {
			p.authed = false;
			p.chan = null;
			if (p.conn) { let c = p.conn; p.conn = null; conn_close(c); }
		}
	}
}

// ---------------------------------------------------------- self / sys info
// 由 LAN ip/mask 计算定向广播地址。网关设备默认路由走 WAN，
// 发 255.255.255.255 会被路由到 WAN 侧，必须用定向广播才能落在 LAN。
function lan_broadcast(ip, mask) {
	let parts = split(ip ?? "", ".");
	if (length(parts) != 4) return "255.255.255.255";
	let v = 0;
	for (let p in parts) v = (v << 8) | (int(p) & 255);
	let m = int(mask);
	// ucode 无 >>> 运算符；0xffffffff 在 int64 下为正数，>> 等效逻辑右移
	let hostmask = (m > 0 && m < 32) ? (0xffffffff >> m) : 0xff;
	let b = (v | hostmask) & 0xffffffff;
	return sprintf("%d.%d.%d.%d", (b >> 24) & 255, (b >> 16) & 255,
	               (b >> 8) & 255, b & 255);
}

// 本机所有网络接口 MAC：用于把 AP 自身的接口（如无线回程 STA 口）
// 从"下挂终端"中排除，避免 AP 被同时计为终端导致数量虚高
function local_iface_macs() {
	let out = {};
	for (let f in fs.glob("/sys/class/net/*/address")) {
		if (index(f, "/lo/") >= 0) continue;
		let m = macnorm(trim(fs.readfile(f) ?? ""));
		if (length(m) == 12 && m != "000000000000") out[m] = true;
	}
	return out;
}

function detect_self() {
	let st = ubusc.call("network.interface.lan", "status");
	let dev = st?.device ?? st?.l3_device ?? "br-lan";
	state.brdev = dev;
	let ip = st?.["ipv4-address"]?.[0]?.address ?? null;
	let mask = st?.["ipv4-address"]?.[0]?.mask ?? 24;
	state.bcast = lan_broadcast(ip, mask);
	let mac = trim(fs.readfile(`/sys/class/net/${dev}/address`) ?? "");
	if (length(macnorm(mac)) != 12) {
		for (let f in fs.glob("/sys/class/net/*/address")) {
			if (index(f, "/lo/") >= 0) continue;
			let m = trim(fs.readfile(f) ?? "");
			if (length(macnorm(m)) == 12) { mac = m; break; }
		}
	}
	let rel = fs.readfile("/etc/openwrt_release") ?? "";
	let fw = "OpenWrt";
	let m = match(rel, /DISTRIB_DESCRIPTION='([^']+)'/);
	if (m) fw = m[1];

	state.self = {
		mac: uc(mac),
		ip,
		hostname: trim(fs.readfile("/proc/sys/kernel/hostname") ?? "OpenWrt"),
		model: trim(fs.readfile("/tmp/sysinfo/model") ?? "OpenWrt device"),
		firmware: fw,
		nonce: randhex(16),
		ifaces: local_iface_macs(),
	};
	state.self.name = state.cfg.name != "" ? state.cfg.name : state.self.hostname;
	log(sprintf("self: %s %s %s", state.self.mac, state.self.ip ?? "?", state.self.name));
}

// 无线回程检测：优先看本插件托管的 STA 接口，其次看其它已关联的 STA。
// 仅当 STA 真实关联（iw link 显示 Connected）才算无线上行，避免把
// "配置了但没连上" 的接口误报成回程。
function wireless_uplink() {
	let ws = ubusc.call("network.wireless", "status") ?? {};
	let fallback = null;
	for (let rname, r in ws) {
		for (let ifc in r.interfaces ?? []) {
			if (ifc.config?.mode != "sta" || !ifc.ifname) continue;
			let link = cmd_output(sprintf("iw dev %s link 2>/dev/null", ifc.ifname));
			if (index(link, "Connected to") < 0) continue;
			let m = match(link, /Connected to ([0-9a-fA-F:]+)/);
			let s = match(link, /signal:\s*(-?[0-9]+)/);
			let info = {
				type: "wireless", port: ifc.ifname,
				ssid: ifc.config?.ssid ?? null,
				bssid: m ? lc(m[1]) : null,
				rssi: s ? int(s[1]) : null,
			};
			if (ifc.section == BACKHAUL_SECTION) return info;
			if (!fallback) fallback = info;
		}
	}
	return fallback;
}

function detect_uplink() {
	let out = cmd_output("ip route show default 2>/dev/null");
	let words = split(trim(split(out, "\n")[0] ?? ""), " ");
	let gw = field_after(words, "via");
	let dev = field_after(words, "dev");
	let wireless = dev && (fs.access(`/sys/class/net/${dev}/wireless`) ||
	                       index(dev, "wlan") == 0 || index(dev, "wl") == 0);
	let wl = wireless_uplink();
	// 本插件托管的无线回程已关联时，回程类型以它为准（即使物理上还有网线）
	if (wl && (wl.port == BACKHAUL_SECTION || current_backhaul_cfg().enabled))
		return { type: "wireless", port: wl.port, gw, ssid: wl.ssid,
		         bssid: wl.bssid, rssi: wl.rssi };
	return { type: wireless ? "wireless" : "wired", port: dev, gw };
}

function self_uptime() {
	return int(split(trim(fs.readfile("/proc/uptime") ?? "0"), " ")[0]);
}

// 回传段（隐藏 WDS AP wifiroam_bh / wifiroam_bh2）：既不是用户热点，也不参与漫游/FT
function is_backhaul_sec(name) {
	return (name == BACKHAUL_SECTION || name == BACKHAUL_SECTION + "2");
}

function wifi_ifaces() {
	let out = [];
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.disabled == "1") return;
		if (is_backhaul_sec(s[".name"])) return;   // 隐藏回传 AP 不进漫游 SSID 组
		push(out, {
			ssid: s.ssid ?? "",
			encryption: s.encryption ?? "none",
			band: cur.get("wireless", s.device, "band") ?? "?",
			device: s.device,
			section: s[".name"],
		});
	});
	return out;
}

// 主AP 下发用：用户 SSID + 密码（不含回传 SSID mesh-gwrt）
function wifi_export() {
	let out = [];
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.disabled == "1") return;
		if (is_backhaul_sec(s[".name"])) return;   // bh 和 bh2 都不能当用户 SSID 下发
		if ((s.ssid ?? "") == "") return;
		push(out, {
			ssid: s.ssid,
			key: s.key ?? "",
			encryption: s.encryption ?? "none",
			band: cur.get("wireless", s.device, "band") ?? "?",
			isolate: s.isolate ?? "0",
		});
	});
	return out;
}

function self_info() {
	return {
		mac: state.self.mac, ip: state.self.ip,
		name: state.self.name, hostname: state.self.hostname,
		model: state.self.model, firmware: state.self.firmware,
		role: state.cfg.role, uptime: self_uptime(),
		ifaces: state.self.ifaces ?? {},
		wifi: wifi_ifaces(), uplink: detect_uplink(),
	};
}

// ------------------------------------------------------- client collection
function freq_band(f) {
	if (!f) return null;
	if (f < 3000) return "2g";
	if (f < 5900) return "5g";
	return "6g";
}

function parse_leases() {
	let out = {};
	let data = fs.readfile("/tmp/dhcp.leases");
	if (!data) return out;
	for (let line in split(data, "\n")) {
		let f = split(trim(line), " ");
		if (length(f) < 4) continue;
		let mn = macnorm(f[1]);
		if (length(mn) != 12) continue;
		out[mn] = { ip: f[2], hostname: f[3] != "*" ? f[3] : null };
	}
	return out;
}

function parse_neigh() {
	let out = {};
	let data = cmd_output(`ip neigh show dev ${state.brdev} 2>/dev/null`);
	for (let line in split(data, "\n")) {
		let f = split(trim(line), " ");
		if (length(f) < 3) continue;
		let ip = f[0];
		let mac = field_after(f, "lladdr");
		let st = f[length(f) - 1];
		if (!mac || index(ip, ":") >= 0) continue;      // ipv4 only
		if (st == "FAILED" || st == "INCOMPLETE") continue;
		out[macnorm(mac)] = { ip };
	}
	return out;
}

// CAP 下发的终端名称表：SAP 上没有 DHCP 服务，/tmp/dhcp.leases 为空，
// 只能由 CAP 把租约里的主机名/IP 同步过来，子 AP 拓扑才能显示名称
function client_names() {
	let out = {};
	for (let mn, n in parse_neigh())
		out[mn] = { ip: n.ip };
	for (let mn, l in parse_leases())
		out[mn] = { hostname: l.hostname, ip: l.ip };
	return out;
}

// brctl showstp 输出 "lan6 (7)"：端口号 → 接口名。
// ImmortalWrt 默认不装 iproute2 的 bridge 命令，只能走 brctl 读 MAC 表。
function bridge_port_names() {
	let map = {};
	let data = cmd_output(`brctl showstp ${state.brdev} 2>/dev/null`);
	for (let line in split(data, "\n")) {
		let m = match(line, /^([^\s]+) \(([0-9]+)\)/);
		if (m) map[m[2]] = m[1];
	}
	return map;
}

function parse_fdb() {
	let out = {};
	let data = cmd_output(`bridge fdb show br ${state.brdev} 2>/dev/null`);
	if (data != "") {
		for (let line in split(data, "\n")) {
			let f = split(trim(line), " ");
			if (length(f) < 3) continue;
			let mn = macnorm(f[0]);
			if (length(mn) != 12) continue;
			if (index(f, "self") >= 0 || index(f, "permanent") >= 0) continue;
			let port = field_after(f, "dev");
			if (!port) continue;
			out[mn] = port;
		}
		return out;
	}

	let pnames = bridge_port_names();
	data = cmd_output(`brctl showmacs ${state.brdev} 2>/dev/null`);
	// brctl 的列分隔符是 TAB（且年龄列前有额外空格），必须按任意空白分割
	for (let line in split(data, "\n")) {
		let f = split(trim(line), /[ \t]+/);
		if (length(f) < 3) continue;
		let mn = macnorm(f[1]);
		if (length(mn) != 12) continue;
		if (f[2] == "yes") continue;   // 网桥自身接口 MAC
		out[mn] = pnames[f[0]] ?? f[0];
	}
	return out;
}

function local_clients() {
	let clients = {};
	let now = time();

	// AP 自身接口 MAC（含无线回程 STA 口）不是终端：对端 AP 用无线回程接入时，
	// 其 STA 口会在本机 hostapd 客户端表里出现，若不排除会与 AP 节点重复计数
	let excl = {};
	for (let m in keys(state.self.ifaces ?? {})) excl[m] = true;
	for (let pmn, p in state.peers)
		for (let m in keys(p.info?.ifaces ?? {})) excl[m] = true;

	// wireless stations via hostapd ubus
	let ifmap = {};
	let ws = ubusc.call("network.wireless", "status");
	for (let rname, r in ws ?? {}) {
		let band = r.config?.band;
		for (let ifc in r.interfaces ?? []) {
			if (ifc.ifname)
				ifmap[ifc.ifname] = { ssid: ifc.config?.ssid, band };
		}
	}
	// hostapd ubus 对象名为 hostapd.<ifname>；ubus list(pattern) 在本平台
	// 返回签名表而非名称，故按 ifname 直接拼装
	for (let ifname in keys(ifmap)) {
		let res = ubusc.call("hostapd." + ifname, "get_clients");
		if (!res?.clients) continue;
		for (let mac, ci in res.clients) {
			let mn = macnorm(mac);
			if (excl[mn]) continue;   // AP 自身接口，不是终端
			clients[mn] = {
				mac: uc(mac), type: "wifi", ifname,
				ssid: ifmap[ifname]?.ssid,
				band: ifmap[ifname]?.band ?? freq_band(res.freq),
				rssi: ci.signal ?? null,
				connected_time: ci.connected_time ?? null,
				// hostapd 上报的 rate 单位是 100 kbit/s（驱动速率 ×100），
				// 除以 100000 换算为 Mbps（如 7220000 -> 72.2 Mbps）
				tx_rate: ci.rate?.tx != null ? ci.rate.tx / 100000 : null,
				rx_rate: ci.rate?.rx != null ? ci.rate.rx / 100000 : null,
			};
		}
	}

	// ip/hostname enrichment + wired clients
	let leases = parse_leases();
	let neigh = parse_neigh();
	let fdb = parse_fdb();

	for (let mn, l in leases) {
		if (clients[mn]) {
			clients[mn].ip = l.ip;
			clients[mn].hostname = l.hostname;
		}
	}
	for (let mn, n in neigh) {
		if (clients[mn] && !clients[mn].ip) clients[mn].ip = n.ip;
	}
	// SAP：用 CAP 下发的名称表补全主机名/IP（本机无 DHCP 租约）
	for (let mn, n in state.net_names ?? {}) {
		if (!clients[mn]) continue;
		if (clients[mn].hostname == null && n.hostname != null)
			clients[mn].hostname = n.hostname;
		if (clients[mn].ip == null && n.ip != null)
			clients[mn].ip = n.ip;
	}

	let self_mn = macnorm(state.self.mac);

	// 级联/上行口：其他 AP（peers/discovered）的 MAC 在 FDB 中所处的端口，
	// 其下游终端由对端 AP 自行上报，本机不再计为终端
	// （否则对端 WiFi 终端会被本机 FDB 从上行口学成 wired 幻影，漫游后长期挂在旧 AP 下）
	let cascade = {};
	for (let mn, p in state.peers) {
		let pt = fdb[mn];
		if (pt) cascade[pt] = true;
		// 无线回程/桥接的 SAP 可能只暴露其 STA/AP 接口 MAC，
		// 这些 MAC 所在的网桥端口同样是"通往对端 AP"的级联口
		for (let m in keys(p.info?.ifaces ?? {})) {
			let q = fdb[m];
			if (q) cascade[q] = true;
		}
	}
	for (let mn in keys(state.discovered)) {
		let pt = fdb[mn];
		if (pt) cascade[pt] = true;
	}

	// 有线终端在线依据只用 FDB（帧级存活，~5min 老化）：
	// DHCP lease（12h）与 ARP STALE 长期残留，会把已离线设备算进来；
	// wired_seen 提供 WIRED_TTL 滞后，防止 FDB 老化边缘抖动
	let seen = state.wired_seen;
	for (let mn, port in fdb) {
		if (mn == self_mn) continue;
		if (excl[mn]) { delete seen[mn]; continue; }      // AP 自身接口
		if (substr(mn, 0, 6) == "01005e" || substr(mn, 0, 4) == "3333") continue;
		if (substr(mn, 0, 6) == "0180c2") continue;       // L2 控制帧（STP/LLDP 等）
		// AP 节点或级联口下游：立即从有线表清除，避免重启初期对端尚未
		// 上报时被记成有线终端后残留 WIRED_TTL 那么久
		if (state.peers[mn] || state.discovered[mn]) { delete seen[mn]; continue; }
		if (cascade[port]) { delete seen[mn]; continue; } // 对端 AP 下游
		seen[mn] = now;
	}
	for (let mn in keys(seen)) {
		if (now - seen[mn] > WIRED_TTL) {
			delete seen[mn];
			continue;
		}
		if (clients[mn]) continue;                        // already wifi
		clients[mn] = {
			mac: maccolon(mn), type: "wired",
			ip: leases[mn]?.ip ?? neigh[mn]?.ip ?? state.net_names?.[mn]?.ip ?? null,
			hostname: leases[mn]?.hostname ?? state.net_names?.[mn]?.hostname ?? null,
			port: fdb[mn] ?? null,
		};
	}

	// first-seen tracking
	for (let mn in keys(clients)) {
		if (!state.client_seen[mn]) state.client_seen[mn] = now;
		clients[mn].since = state.client_seen[mn];
	}
	return clients;
}

function diff_events(prev, cur, apname) {
	for (let mn in keys(cur))
		if (!prev[mn]) push_event("client_join", maccolon(mn), apname, client_name_of(mn, cur));
	for (let mn in keys(prev))
		if (!cur[mn]) push_event("client_leave", maccolon(mn), apname, client_name_of(mn, prev));
}

// ------------------------------------------------------------- UDP discovery
function udp_send(obj) {
	if (!udp_sock) return;
	let payload = sprintf("%.J", obj);
	udp_sock.send(payload, 0,
		{ address: state.bcast ?? "255.255.255.255", port: UDP_PORT });
	// 再发一次受限广播：br-lan 的广播出不了 WAN 口，
	// 主路由在 WAN 侧时就发现不了本机（配对失败）
	if ((state.bcast ?? "") != "255.255.255.255")
		udp_sock.send(payload, 0, { address: "255.255.255.255", port: UDP_PORT });
}

// 主路由要能回连：优先用默认路由的源地址（WAN/无线回传口的 IP），
// 不能用 br-lan 的 192.168.3.3（主路由根本路由不到）
function advertise_ip() {
	let src = trim(cmd_output("ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \\([0-9.]*\\).*/\\1/p'"));
	if (src != "" && src != "1.1.1.1") return src;
	return state.self.ip;
}

function send_hello() {
	// 强制退出 AP（gwrt.mesh_apmode.enabled=0）时停止广播：
	// 避免主AP 的自动配对又把它拉回组网状态
	let gc = uci.cursor();
	gc.load("gwrt");
	if (gc.get("gwrt", "mesh_apmode", "enabled") == "0") return;
	udp_send({
		magic: MAGIC, ver: 1, role: state.cfg.role,
		mac: state.self.mac, ip: advertise_ip(), lan_ip: state.self.ip,
		name: state.self.name, model: state.self.model,
		nonce: state.self.nonce,
		thash: substr(sha256("wifiroam:" + state.cfg.token), 0, 16),
		alias_ver: state.aliases.ver, ts: time(),
	});
}

function udp_rx() {
	while (true) {
		let peer = {};
		let data = udp_sock.recv(4096, 0, peer);
		if (!data) break;
		let msg;
		try { msg = json(data); } catch (e) { continue; }
		if (type(msg) != "object" || msg.magic != MAGIC) continue;
		let mn = macnorm(msg.mac);
		if (length(mn) != 12 || mn == macnorm(state.self.mac)) continue;

		if (msg.role == "unconfigured") {
			state.discovered[mn] = {
				mac: uc(msg.mac), ip: msg.ip ?? peer.address,
				name: msg.name, model: msg.model,
				nonce: msg.nonce, last_seen: time(),
			};
			continue;
		}

		let my_th = substr(sha256("wifiroam:" + state.cfg.token), 0, 16);
		if (state.cfg.token == "" || msg.thash != my_th) continue; // foreign net

		let p = state.peers[mn] ??= { clients: null }; // null = 未收过 report，首轮 diff 抑制
		p.mac = uc(msg.mac);
		p.ip = msg.ip ?? peer.address;
		p.name = msg.name;
		p.model = msg.model;
		p.role = msg.role;
		p.last_seen = time();
		if (msg.role == "cap" && msg.ip)
			state.cap_learned = msg.ip;
	}
}

function expire_tick() {
	let now = time();
	for (let mn in keys(state.peers)) {
		if (now - (state.peers[mn].last_seen ?? 0) > PEER_TTL) {
			let p = state.peers[mn];
			push_event("ap_offline", maccolon(mn), p.name ?? "");
			if (p.chan) p.chan.disconnect();
			delete state.peers[mn];
		}
	}
	for (let mn in keys(state.discovered))
		if (now - state.discovered[mn].last_seen > DISCOVER_TTL)
			delete state.discovered[mn];
}

function setup_udp() {
	udp_sock = socket.create(socket.AF_INET,
		socket.SOCK_DGRAM | socket.SOCK_NONBLOCK, 0);
	if (!udp_sock) { log("udp create failed"); return; }
	udp_sock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	udp_sock.setopt(socket.SOL_SOCKET, socket.SO_BROADCAST, true);
	if (!udp_sock.bind("0.0.0.0:" + UDP_PORT)) {
		log("udp bind failed: " + socket.error());
		udp_sock.close(); udp_sock = null;
		exit(1);   // 传输不可用 = 守护进程无意义，fail-fast 交 procd 处置
	}
	uloop.handle(udp_sock.fileno(), udp_rx, uloop.ULOOP_READ);
}

// ---------------------------------------------------------- topology build
function ap_display(mn) {
	if (mn == macnorm(state.self.mac)) return state.self.name;
	let p = state.peers[mn];
	return p ? (p.info?.name ?? p.name ?? maccolon(mn)) : maccolon(mn);
}

// 终端归属表：同一终端可能被多个 AP 的 FDB 学到（对端 WiFi 终端会被
// SAP 侧报成 wired），按 mac 去重，归属优先级：wifi > wired，本机 > 对端
function compute_owner(my, self_mn) {
	let owner = {};
	for (let pass in [ "wifi", "wired" ]) {
		for (let mn, c in my)
			if (!owner[mn] && (c.type ?? "wired") == pass)
				owner[mn] = self_mn;
		for (let pmn, p in state.peers)
			for (let mn, c in p.clients ?? {})
				if (!owner[mn] && (c.type ?? "wired") == pass)
					owner[mn] = pmn;
	}
	return owner;
}

// CAP 视角跨 AP 迁移事件：归属从一台 AP 变到另一台 => roam_move
//（各 AP 本地的 join/leave 事件照旧保留，roam_move 是网络视角的结论）
function owner_events(my) {
	if (state.cfg.role != "cap") return;
	let owner = compute_owner(my, macnorm(state.self.mac));
	if (state.prev_owner != null)
		for (let mn, ap in owner) {
			let old = state.prev_owner[mn];
			if (old != null && old != ap)
				push_event("roam_move", maccolon(mn),
					sprintf("%s → %s", ap_display(old), ap_display(ap)),
					client_name_of(mn, my));
		}
	state.prev_owner = owner;
}

function client_node(mn, c, parent) {
	let al = state.aliases.map[mn];
	return {
		id: mn, type: "client",
		name: (al?.name != null && al.name != "") ? al.name :
		      (c.hostname ?? maccolon(mn)),
		custom_name: (al?.name != null && al.name != "") ? al.name : null,
		hostname: c.hostname ?? null,
		ip: c.ip ?? null, mac: c.mac ?? maccolon(mn),
		parent,
		conn: {
			type: c.type, band: c.band ?? null, ssid: c.ssid ?? null,
			rssi: c.rssi ?? null,
			tx_rate: c.tx_rate ?? null, rx_rate: c.rx_rate ?? null,
			port: c.port ?? null, since: c.since ?? null,
		},
		icon: al?.icon ?? null, note: al?.note ?? null,
	};
}

function build_topology() {
	let nodes = [];
	let self_mn = macnorm(state.self.mac);
	let myclients = local_clients();

	let ap_nodes = {};
	let self_al = state.aliases.map[self_mn];
	let self_node = {
		id: self_mn, type: "ap", role: state.cfg.role,
		name: (self_al?.name != null && self_al.name != "") ? self_al.name : state.self.name,
		custom_name: (self_al?.name != null && self_al.name != "") ? self_al.name : null,
		model: state.self.model,
		ip: state.self.ip, mac: state.self.mac,
		parent: null, uplink: detect_uplink(),
		firmware: state.self.firmware, uptime: self_uptime(),
		clients: [],
	};
	push(nodes, self_node);
	ap_nodes[self_mn] = self_node;

	let peer_clients = {};
	for (let mn, p in state.peers) {
		let pal = state.aliases.map[mn];
		let pname = (pal?.name != null && pal.name != "") ? pal.name
		                                                 : (p.info?.name ?? p.name ?? mn);
		let n = {
			id: mn, type: "ap",
			role: p.info?.role ?? p.role ?? "sap",
			name: pname,
			custom_name: (pal?.name != null && pal.name != "") ? pal.name : null,
			model: p.info?.model ?? p.model ?? null,
			ip: p.info?.ip ?? p.ip, mac: p.mac ?? maccolon(mn),
			parent: self_mn,
			uplink: p.info?.uplink ?? null,
			firmware: p.info?.firmware ?? null,
			uptime: p.info?.uptime ?? null,
			authed: !!p.authed,
			clients: [],
		};
		push(nodes, n);
		ap_nodes[mn] = n;
		peer_clients[mn] = p.clients ?? {};
	}

	// 按 mac 去重归属（规则见 compute_owner）
	let owner = compute_owner(myclients, self_mn);
	// 对端（SAP）无 DHCP 服务，其上报终端可能缺 ip/hostname，
	// 用本机 leases/ARP 补全，保证各 AP 下挂设备信息一致
	let leases = parse_leases();
	let neigh = parse_neigh();
	for (let mn, ap in owner) {
		let c = (ap == self_mn ? myclients : peer_clients[ap])[mn];
		if (c.ip == null)
			c.ip = leases[mn]?.ip ?? neigh[mn]?.ip ?? state.net_names?.[mn]?.ip ?? null;
		if (c.hostname == null)
			c.hostname = leases[mn]?.hostname ?? state.net_names?.[mn]?.hostname ?? null;
		push(nodes, client_node(mn, c, ap));
		push(ap_nodes[ap].clients, mn);
	}
	return { nodes, self: self_mn, role: state.cfg.role, now: time() };
}

// --------------------------------------------------------- roam configurator
function roam_md(ssid) { return substr(sha256("md:" + ssid), 0, 4); }
function roam_key0(mac) { return substr(sha256(state.cfg.token + ":r0:" + macnorm(mac)), 0, 32); }
function roam_key1(mac) { return substr(sha256(state.cfg.token + ":r1:" + macnorm(mac)), 0, 32); }

function member_list() {
	let members = [ { mac: state.self.mac, name: state.self.name } ];
	for (let mn, p in state.peers)
		if (p.authed)
			push(members, { mac: p.mac ?? maccolon(mn),
			                name: p.info?.name ?? p.name ?? mn });
	return members;
}

function apply_roam_local(roam, members) {
	let cur = uci.cursor();
	cur.load("wireless");
	let touched = [];
	let self_nasid = uc(macnorm(state.self.mac));

	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		let sid = s[".name"];
		let in_group = roam.enabled && index(roam.ssids ?? [], s.ssid) >= 0;

		if (in_group) {
			// R（802.11r）可单独关闭：关闭时移除全部 FT 相关键，只保留 K/V
			if (roam.r_fast) {
				cur.set("wireless", sid, "ieee80211r", "1");
				cur.set("wireless", sid, "mobility_domain", roam_md(s.ssid));
				cur.set("wireless", sid, "ft_over_ds", roam.ft_over_ds ? "1" : "0");
				cur.set("wireless", sid, "reassociation_deadline", "2000");
				if (roam.ft_mode == "explicit") {
					cur.set("wireless", sid, "ft_psk_generate_local", "0");
					cur.set("wireless", sid, "nas_identifier", self_nasid + "-" + s.ssid);
					cur.set("wireless", sid, "pmk_r1_push", "1");
					let r0 = [], r1 = [];
					for (let m in members) {
						let mm = m.mac;
						push(r0, sprintf("%s,%s-%s,%s", mm, uc(macnorm(mm)), s.ssid, roam_key0(mm)));
						push(r1, sprintf("%s,%s,%s", mm, mm, roam_key1(mm)));
					}
					cur.set("wireless", sid, "r0kh", r0);
					cur.set("wireless", sid, "r1kh", r1);
				} else {
					cur.set("wireless", sid, "ft_psk_generate_local", "1");
					for (let k in [ "nas_identifier", "pmk_r1_push", "r0kh", "r1kh" ])
						cur.delete("wireless", sid, k);
				}
			} else {
				for (let k in [ "ieee80211r", "mobility_domain", "ft_over_ds",
				                "ft_psk_generate_local", "reassociation_deadline",
				                "nas_identifier", "pmk_r1_push", "r0kh", "r1kh" ])
					cur.delete("wireless", sid, k);
			}
			cur.set("wireless", sid, "ieee80211k", "1");
			cur.set("wireless", sid, "rrm_neighbor_report", roam.k_neighbor ? "1" : "0");
			cur.set("wireless", sid, "rrm_beacon_report", roam.k_beacon ? "1" : "0");
			cur.set("wireless", sid, "ieee80211v", "1");
			cur.set("wireless", sid, "bss_transition", roam.v_bss_transition ? "1" : "0");
			push(touched, s.ssid);
		} else {
			// only strip keys we manage, and only if present
			if (cur.get("wireless", sid, "ieee80211r") != null ||
			    cur.get("wireless", sid, "ieee80211k") != null ||
			    cur.get("wireless", sid, "ieee80211v") != null) {
				for (let k in ROAM_KEYS)
					cur.delete("wireless", sid, k);
			}
		}
	});

	cur.commit("wireless");
	state.roam_ver_applied = roam.config_ver ?? state.roam_ver_applied;
	// 整份漫游配置落盘：SAP 的设置页读取本地 uci，只写 ver/enabled 会让
	// 子 AP 显示与主 AP 不一致（SSID 组、FT 模式、k/v 开关等仍是默认值）
	let wc = uci.cursor();
	wc.load("wifiroam");
	let dirty = false;
	let want_ssids = roam.ssids ?? [];
	if (type(want_ssids) != "array") want_ssids = want_ssids == "" ? [] : [ want_ssids ];
	let cur_ssids = wc.get("wifiroam", "roam", "ssids") ?? [];
	if (type(cur_ssids) != "array") cur_ssids = cur_ssids == "" ? [] : [ cur_ssids ];
	let want = {
		enabled: roam.enabled ? "1" : "0",
		r_fast: roam.r_fast ? "1" : "0",
		ft_mode: roam.ft_mode == "explicit" ? "explicit" : "simple",
		ft_over_ds: roam.ft_over_ds ? "1" : "0",
		k_neighbor: roam.k_neighbor ? "1" : "0",
		k_beacon: roam.k_beacon ? "1" : "0",
		v_bss_transition: roam.v_bss_transition ? "1" : "0",
		rssi_profile: roam.rssi_profile ?? "balanced",
		rssi_threshold: "" + (roam.rssi_threshold ?? rssi_preset(roam.rssi_profile)),
		config_ver: "" + state.roam_ver_applied,
	};
	if (join("\n", cur_ssids) != join("\n", want_ssids)) {
		wc.set("wifiroam", "roam", "ssids", want_ssids);
		dirty = true;
	}
	for (let k, v in want) {
		if ((wc.get("wifiroam", "roam", k) ?? "") != v) {
			wc.set("wifiroam", "roam", k, v);
			dirty = true;
		}
	}
	if (dirty) wc.commit("wifiroam");
	uloop.process("/sbin/wifi", [ "reload" ], null,
		function(res) { log("wifi reload rc=" + res); });
	push_event("roam_apply", "",
		sprintf("ver=%d ssids=%d", roam.config_ver ?? 0, length(touched)));
	return { ok: true, touched, ver: state.roam_ver_applied };
}

// 子AP：按频段套用主AP 的 SSID/密码（同一 ESS 才能无缝漫游）
function apply_wifi_from_cap(list) {
	if (type(list) != "array" || length(list) == 0)
		return { ok: true, changed: 0 };
	// 强制退出 AP 模式时忽略主AP 的 SSID/密码下发，保持路由模式自己的 SSID
	let gc = uci.cursor();
	gc.load("gwrt");
	if (gc.get("gwrt", "mesh_apmode", "enabled") == "0")
		return { ok: true, changed: 0 };
	// 第一次同步前，把「路由模式」的无线配置存一份；
	// 回退路由模式时用它恢复原 SSID/密码（否则子AP 一直广播主路由 SSID，回退后连不上）
	if (!fs.access("/etc/gwrt-wireless-orig")) {
		let raw = fs.readfile("/etc/config/wireless");
		if (raw) fs.writefile("/etc/gwrt-wireless-orig", raw);
	}
	let by_band = {};
	for (let w in list) {
		if (!w || (w.ssid ?? "") == "") continue;
		let b = w.band ?? "?";
		if (!by_band[b]) by_band[b] = w;
	}
	let cur = uci.cursor();
	cur.load("wireless");
	let changed = 0;
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (is_backhaul_sec(s[".name"])) return;   // 隐藏回传 AP（bh/bh2）不是用户热点
		let band = cur.get("wireless", s.device, "band") ?? "?";
		let w = by_band[band];
		if (!w) return;
		let sid = s[".name"];
		if ((s.ssid ?? "") != w.ssid) {
			cur.set("wireless", sid, "ssid", w.ssid);
			changed++;
		}
		if ((w.encryption ?? "") != "" && (s.encryption ?? "") != w.encryption) {
			cur.set("wireless", sid, "encryption", w.encryption);
			changed++;
		}
		if ((w.key ?? "") != "" && (s.key ?? "") != w.key) {
			cur.set("wireless", sid, "key", w.key);
			changed++;
		}
		if ((w.isolate ?? "0") != (s.isolate ?? "0")) {
			cur.set("wireless", sid, "isolate", w.isolate);
			changed++;
		}
	});
	if (changed > 0) {
		cur.commit("wireless");
		log(sprintf("wifi sync from CAP: %d changes", changed));
	}
	return { ok: true, changed };
}

// 本机实际落盘的 K/V/R：随 push_roam_config 回执上报，主AP可显示各 AP 生效状态
function applied_kvr(ssids) {
	let r = true, k = true, v = true, seen = 0;
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.disabled == "1") return;
		if (index(ssids ?? [], s.ssid) < 0) return;
		seen++;
		if (s.ieee80211r != "1" || (s.mobility_domain ?? "") == "") r = false;
		if (s.ieee80211k != "1" || (s.rrm_neighbor_report ?? "0") != "1") k = false;
		if (s.ieee80211v != "1" || (s.bss_transition ?? "0") != "1") v = false;
	});
	return { r: seen > 0 && r, k: seen > 0 && k, v: seen > 0 && v, seen };
}

// ----------------------------------------------------- wireless backhaul
function wifi_radios() {
	let out = [];
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-device", function(s) {
		push(out, {
			name: s[".name"], band: s.band ?? "?",
			disabled: s.disabled == "1",
		});
	});
	return out;
}

function pick_radio_by_band(band) {
	let radios = wifi_radios();
	for (let r in radios)
		if (!r.disabled && r.band == band) return r.name;
	return null;
}

function radio_running_channel(dev) {
	let ch = 0;
	let cur = uci.cursor();
	cur.load("wireless");
	let c = cur.get("wireless", dev, "channel") ?? "";
	if (match(c, /^[0-9]+$/)) ch = int(c);
	if (ch > 0) return ch;
	// channel=auto：从运行中的 AP 接口读
	let ws = ubusc.call("network.wireless", "status") ?? {};
	for (let rname, r in ws) {
		if (rname != dev) continue;
		for (let ifc in r.interfaces ?? {}) {
			if (!ifc.ifname) continue;
			let info = cmd_output(sprintf("iw dev %s info 2>/dev/null", ifc.ifname));
			let m = match(info, /channel ([0-9]+)/);
			if (m) return int(m[1]);
		}
	}
	return 0;
}

function pick_radio(prefer) {
	let radios = wifi_radios();
	for (let r in radios)
		if (!r.disabled && r.name == prefer) return r.name;
	for (let r in radios)
		if (!r.disabled && r.band == "5g") return r.name;
	for (let r in radios)
		if (!r.disabled) return r.name;
	return null;
}

// 上级 AP 的 MAC 若出现在以太网口上，说明当前仍有有线回程。
// 此时不能把 STA 桥进 br-lan，否则会形成二层环路；只暂存配置待拔线后自动启用。
function ethernet_uplink_port() {
	let fdb = parse_fdb();
	for (let mn, p in state.peers) {
		let role = p.info?.role ?? p.role;
		if (role != "cap") continue;
		let port = fdb[mn];
		if (port && index(port, "phy") != 0 && index(port, "wl") != 0 &&
		    index(port, "vap") != 0 && index(port, "br") != 0)
			return port;
	}
	return null;
}

function apply_backhaul_local(bh, role) {
	let cur = uci.cursor();
	cur.load("wireless");
	let exists = cur.get("wireless", BACKHAUL_SECTION) != null;
	let band = bh.band ?? "auto";
	if (role != "cap") {
		// 子AP：运行期降级优先（state.bh_band=2g），否则显式 5g 才用 5G。
		// 默认 2.4G：与 gwrt-mesh-apmode 的默认一致（两处代码抢写同一段会反复重配），
		// 且 2.4G 穿透好、信道天然对齐，无线回传更稳。
		if (state.bh_band) band = state.bh_band;
		else band = (band == "5g") ? "5g" : "2g";
	}

	if (bh.enabled && (bh.ssid ?? "") != "" && (bh.key ?? "") != "") {
		if (role == "cap") {
			// 主AP：5G + 2.4G 都开隐藏回传 AP，子AP 可任选（5G 优先，2.4G 兜底）
			let r5 = pick_radio_by_band("5g");
			let r2 = pick_radio_by_band("2g");
			let ch = r5 ? radio_running_channel(r5) : 0;
			let ch2 = r2 ? radio_running_channel(r2) : 0;
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
			let wc0 = uci.cursor(); wc0.load("wifiroam");
			wc0.set("wifiroam", "backhaul", "channel", "" + ch);
			// 2.4G 回传也要告诉子AP 本机 2.4G 信道：AP+STA 共用射频，
			// 子AP 的 2.4G 热点不在同一信道时 STA 根本起不来
			wc0.set("wifiroam", "backhaul", "channel2g", "" + ch2);
			wc0.commit("wifiroam");
			bh.channel = ch;
			log(sprintf("backhaul APs: 5g=%s ch=%d, 2g=%s", r5 ?? "-", ch, r2 ?? "-"));
		} else {
			// 子AP：按 band 选射频；5G 时把本机 5G 热点信道对齐主AP
			let dev = (band == "2g") ? pick_radio_by_band("2g") : pick_radio_by_band("5g");
			if (!dev) dev = pick_radio_by_band("2g");
			if (!dev) return { ok: false, error: "no_radio" };
			if (band != "2g" && (bh.channel ?? 0) > 0) {
				let curch = int(cur.get("wireless", dev, "channel") ?? "0");
				if (curch != bh.channel) {
					cur.set("wireless", dev, "channel", "" + bh.channel);
					cur.set("wireless", dev, "htmode", "HE80");
					log(sprintf("align %s to channel %d", dev, bh.channel));
				}
			}
			// 2.4G 回传：AP+STA 共用同一个射频，本机 2.4G 热点必须和主AP 同信道，
			// 否则 STA 起不来（主AP 把 2.4G 改成 6/11 时就会碰）
			if (band == "2g" && (bh.channel2g ?? 0) > 0 && bh.channel2g <= 14) {
				let curch2 = int(cur.get("wireless", dev, "channel") ?? "0");
				if (curch2 != bh.channel2g) {
					cur.set("wireless", dev, "channel", "" + bh.channel2g);
					log(sprintf("align %s to 2g channel %d", dev, bh.channel2g));
				}
			}
			if (cur.get("wireless", BACKHAUL_SECTION) == null)
				cur.set("wireless", BACKHAUL_SECTION, "wifi-iface");
			cur.set("wireless", BACKHAUL_SECTION, "device", dev);
			cur.set("wireless", BACKHAUL_SECTION, "mode", "sta");
			cur.set("wireless", BACKHAUL_SECTION, "ssid", bh.ssid);
			cur.set("wireless", BACKHAUL_SECTION, "encryption", "psk2+ccmp");
			cur.set("wireless", BACKHAUL_SECTION, "key", bh.key);
			cur.set("wireless", BACKHAUL_SECTION, "network", "lan");
			// 3-addr（wds=0）：4-addr 在 JDCloud 主AP 上四步握手容易超时
			// （子AP 侧还会被 apmode 写成 wds=0，两边不一致时 4WAY_HANDSHAKE_TIMEOUT）
			cur.set("wireless", BACKHAUL_SECTION, "wds", "0");
			cur.delete("wireless", BACKHAUL_SECTION, "hidden");
			cur.set("wireless", BACKHAUL_SECTION, "disabled",
				ethernet_uplink_port() ? "1" : "0");
			if (cur.get("wireless", BACKHAUL_SECTION + "2") != null)
				cur.delete("wireless", BACKHAUL_SECTION + "2");
		}
	} else {
		if (exists) cur.delete("wireless", BACKHAUL_SECTION);
		if (cur.get("wireless", BACKHAUL_SECTION + "2") != null)
			cur.delete("wireless", BACKHAUL_SECTION + "2");
	}
	cur.commit("wireless");

	let ver = bh.config_ver ?? 0;
	let wc = uci.cursor();
	wc.load("wifiroam");
	wc.set("wifiroam", "backhaul", "enabled", bh.enabled ? "1" : "0");
	wc.set("wifiroam", "backhaul", "ssid", bh.ssid ?? BACKHAUL_DEFAULT_SSID);
	wc.set("wifiroam", "backhaul", "key", bh.key ?? "");
	wc.set("wifiroam", "backhaul", "device", bh.device ?? "");
	wc.set("wifiroam", "backhaul", "channel", "" + (bh.channel ?? 0));
	// 只有当对方真的带了 channel2g 才写（老版本主AP 推送里没这个字段，别把本机已有值抹成 0）
	if (bh.channel2g != null)
		wc.set("wifiroam", "backhaul", "channel2g", "" + bh.channel2g);
	wc.set("wifiroam", "backhaul", "config_ver", "" + ver);
	wc.commit("wifiroam");
	state.backhaul_ver_applied = ver;

	uloop.process("/sbin/wifi", [ "reload" ], null,
		function(res) { log("backhaul wifi reload rc=" + res); });
	push_event("backhaul_apply", "",
		sprintf("ver=%d %s band=%s", ver, bh.enabled ? "wireless" : "off", band));
	return { ok: true, ver };
}

// SAP 侧：有线/无线回程互斥。网线在位时 STA 保持 disabled，拔线后自动启用；
// 重新插回网线则暂停 STA，避免二层环路。
function backhaul_tick() {
	if (state.cfg.role != "sap") return;
	let bh = current_backhaul_cfg();
	if (!bh.enabled) return;
	let cur = uci.cursor();
	cur.load("wireless");
	if (cur.get("wireless", BACKHAUL_SECTION) == null) return;
	let wired = ethernet_uplink_port();
	let want = wired ? "1" : "0";
	if ((cur.get("wireless", BACKHAUL_SECTION, "disabled") ?? "0") != want) {
		cur.set("wireless", BACKHAUL_SECTION, "disabled", want);
		cur.commit("wireless");
		push_event("backhaul_link", "",
			want == "1" ? "wired uplink detected, wireless STA paused"
			            : "cable removed, wireless backhaul enabled");
		uloop.process("/sbin/wifi", [ "reload" ], null,
			function(res) { log("backhaul switch rc=" + res); });
		state.bh_fail = 0;
		return;
	}
	if (wired) return;

	// 无线回传：5G 连续 60s 没连上 -> 降级 2.4G（只在本会话内，重启后重试 5G）
	let band = state.bh_band ?? ((bh.band == "2g") ? "2g" : "5g");
	if (band == "2g") return;
	let ws = ubusc.call("network.wireless", "status") ?? {};
	let ifn = null;
	for (let rname, r in ws)
		for (let ifc in r.interfaces ?? {})
			if (ifc.section == BACKHAUL_SECTION) ifn = ifc.ifname;
	if (!ifn) return;
	let link = cmd_output(sprintf("iw dev %s link 2>/dev/null", ifn));
	if (index(link, "Not connected") < 0 && index(link, "Connected to") >= 0) {
		state.bh_fail = 0;
		return;
	}
	state.bh_fail = (state.bh_fail ?? 0) + 1;
	if (state.bh_fail >= 6) {
		log("5G backhaul not connected for 60s, falling back to 2.4G");
		state.bh_band = "2g";
		state.bh_fail = 0;
		// 持久化频段，apmode 服务按 uci band 重建回传
		let wcb = uci.cursor();
		wcb.load("wifiroam");
		wcb.set("wifiroam", "backhaul", "band", "2g");
		wcb.commit("wifiroam");
		apply_backhaul_local(current_backhaul_cfg(), "sap");
		push_event("backhaul_fallback", "", "5g -> 2g");
	}
}

// --------------------------------------------------------------- prechecks
function ssid_groups() {
	let groups = {};
	let self_mn = macnorm(state.self.mac);
	for (let w in wifi_ifaces()) {
		let g = groups[w.ssid] ??= { ssid: w.ssid, aps: {}, encs: {}, bands: {} };
		g.aps[self_mn] = true;
		g.encs[self_mn] = w.encryption;
		g.bands[w.band] = true;
	}
	for (let mn, p in state.peers) {
		for (let w in p.info?.wifi ?? []) {
			let g = groups[w.ssid] ??= { ssid: w.ssid, aps: {}, encs: {}, bands: {} };
			g.aps[mn] = true;
			g.encs[mn] = w.encryption;
			g.bands[w.band] = true;
		}
	}
	let out = [];
	for (let ssid, g in groups) {
		let encset = {};
		for (let mn, e in g.encs) encset[e] = true;
		let enc_list = keys(encset);
		let enc_ok = true;
		for (let e in enc_list)
			if (index(e, "psk") < 0 && index(e, "sae") < 0) enc_ok = false;
		push(out, {
			ssid, ap_count: length(keys(g.aps)),
			bands: keys(g.bands), encryptions: enc_list,
			consistent: length(enc_list) == 1,
			enc_ok,
		});
	}
	return out;
}

// 全网络 AP 概览：CAP 汇总后下发给 SAP，子 AP 的“开启前检查”与主 AP 保持一致
function ap_overview() {
	let self_mn = macnorm(state.self.mac);
	let aps = [ {
		id: self_mn, name: state.self.name, role: state.cfg.role,
		ip: state.self.ip, online: true, self: true,
		ssids: map(wifi_ifaces(), function(w) { return w.ssid; }),
		// 本机实际落盘的 K/V/R，便于主 AP 与子 AP 看到一致的生效状态
		kvr: applied_kvr(current_roam_cfg().ssids),
	} ];
	for (let mn, p in state.peers) {
		let list = [];
		for (let w in p.info?.wifi ?? [])
			if (index(list, w.ssid) < 0) push(list, w.ssid);
		push(aps, {
			id: mn, name: p.info?.name ?? p.name ?? maccolon(mn),
			role: p.info?.role ?? p.role ?? "sap",
			ip: p.info?.ip ?? p.ip, online: !!p.authed, self: false,
			ssids: list,
			kvr: p.kvr ?? null,
		});
	}
	return { groups: ssid_groups(), aps };
}

function precheck() {
	let checks = [];

	// apk (24.10+) / opkg (legacy) 双栈检测
	let wp = "";
	if (fs.access("/usr/bin/apk") || fs.access("/sbin/apk"))
		wp = trim(cmd_output("apk list --installed 2>/dev/null | awk '{print $1}' | grep -E '^wpad' | head -1"));
	if (wp == "")
		wp = trim(cmd_output("opkg list-installed 2>/dev/null | grep -E '^wpad' | head -1"));
	push(checks, { id: "wpad", ok: wp != "" && index(wp, "basic") < 0,
		info: wp != "" ? wp : "none" });

	// SAP 用 CAP 下发的全网络概览，避免子 AP 只看到本机接口导致计数/状态不一致
	let overview = (state.cfg.role == "sap" && state.roster?.aps) ? state.roster
	                                                               : ap_overview();
	let groups = overview.groups;
	let n_multi = 0;
	for (let g in groups) if (g.ap_count >= 2) n_multi++;
	push(checks, { id: "ssid_group", ok: n_multi > 0,
		info: sprintf("%d", n_multi) });

	for (let g in groups) {
		push(checks, { id: "enc_consistent", ok: g.consistent,
			info: sprintf("%s: %s", g.ssid, join(",", g.encryptions)) });
		push(checks, { id: "enc_allowed", ok: g.enc_ok,
			info: sprintf("%s: %s", g.ssid, join(",", g.encryptions)) });
	}
	push(checks, { id: "role", ok: state.cfg.role == "cap", info: state.cfg.role });

	// 成员 AP 概览：让"开启前检查"能直接看出子路由上报的 SSID/频段是否正确，
	// 而不是只显示一个汇总计数
	// self 标记必须按本机 MAC 重新计算：CAP 下发的 roster 里 "self" 指 CAP 自己
	let self_mn = macnorm(state.self.mac);
	let aps = [];
	for (let a in overview.aps) {
		push(aps, {
			id: a.id, name: a.name, role: a.role, ip: a.ip,
			online: a.online, self: a.id == self_mn, ssids: a.ssids,
			kvr: a.kvr ?? null,
		});
	}
	return { checks, groups, role: state.cfg.role, aps };
}

// ------------------------------------------------------- SAP -> CAP uplink
function sap_rx(req) {
	let link = state.link;
	if (!link || !link.chan) return 0;

	if (!link.authed) {
		if (req.type == "hello") {
			link.cap_mac = macnorm(req.args?.mac ?? "");
			let digest = sha256(state.cfg.token + ":" + (req.args?.nonce ?? ""));
			link.chan.defer({
				method: "auth",
				data: {
					mac: state.self.mac, role: state.cfg.role,
					name: state.self.name, digest,
					alias_ver: state.aliases.ver,
					roam_ver: state.roam_ver_applied,
					roam_sig: roam_sig(current_roam_cfg()),
					backhaul_ver: state.backhaul_ver_applied,
				},
				data_cb: function(m) {
					if (m?.ok) {
						link.authed = true;
						link.last_pong = time();
						state.net_names = m.names ?? {};
						if (m.roster) state.roster = m.roster;
						// 让 SAP 侧 status/peers_online 反映 CAP 在线
						if (link.cap_mac) {
							let cp = state.peers[link.cap_mac] ??= { clients: {} };
							cp.authed = true;
						}
						push_event("cap_connected", "", state.cfg.cap_ip);
						log("link to CAP established");
						sap_report();
					} else {
						log("CAP auth rejected");
						link.chan.disconnect();
					}
				},
				// cb 为 complete 回调（成功也触发），仅 rc != 0 表示失败/超时
				cb: function(rc) {
					if (rc != 0 && state.link == link) {
						log("CAP auth request failed");
						sap_disconnect();
					}
				},
			});
		}
		return 0;
	}

	switch (req.type) {
	case "push_roam_config": {
		let w = apply_wifi_from_cap(req.args.wifi ?? []);
		let r = apply_roam_local(req.args.roam, req.args.members ?? []);
		req.reply({ ok: r.ok, ver: r.ver, wifi: w.changed,
		            kvr: applied_kvr(req.args.roam?.ssids ?? []) });
		break;
	}
	case "push_aliases": {
		let a = req.args.aliases;
		if (a && (a.ver ?? 0) > state.aliases.ver) {
			state.aliases = a;
			alias_save();
		}
		req.reply({ ok: true, ver: state.aliases.ver });
		break;
	}
	case "push_backhaul_config": {
		let r = apply_backhaul_local(req.args.backhaul ?? {}, "sap");
		req.reply({ ok: r.ok, ver: r.ver, error: r.error });
		break;
	}
	case "get_client_detail": {
		let mn = macnorm(req.args.mac);
		let c = local_clients()[mn];
		if (c)
			req.reply({ ok: true, client: client_node(mn, c, macnorm(state.self.mac)) });
		else
			req.reply({ ok: false });
		break;
	}
	case "get_topology":
		req.reply(build_topology());
		break;
	case "leave":
		req.reply({ ok: true });
		push_event("unpaired", "", "");
		uloop.timer(300, function() {
			apply_roam_local({ enabled: false, ssids: [], config_ver: 0 }, []);
			state.cfg.role = "unconfigured";
			state.cfg.token = "";
			state.cfg.cap_ip = "";
			save_config();
			reconfigure();
		});
		break;
	}
	return 0;
}

function sap_disconnect() {
	let link = state.link;
	if (!link) return;
	log("link to CAP closed");
	try { link.chan.disconnect(); } catch (e) {}
	try { link.sock.close(); } catch (e) {}
	if (link.cap_mac && state.peers[link.cap_mac])
		state.peers[link.cap_mac].authed = false;
	state.link = null;
}

function sap_connect(cap_ip) {
	sap_disconnect();
	let addr = socket.sockaddr({ address: cap_ip, port: TCP_PORT });
	if (!addr) return;
	let sock = socket.create(socket.AF_INET,
		socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
	if (!sock) return;
	sock.connect(addr); // nonblocking: completes via channel machinery
	let link = { sock, authed: false, ts: time(), last_pong: time() };
	link.chan = libubus.open_channel(sock, sap_rx, sap_disconnect);
	state.link = link;
	log(sprintf("connecting to CAP %s", cap_ip));
}

function sap_tick() {
	if (state.cfg.role != "sap") return;
	if (state.link?.authed) {
		// 心跳看门狗：ucode 通道可能感知不到对端死亡（CLOSE_WAIT 半开），
		// 以 report_status 回执刷新 last_pong，超时主动断开重连
		if (time() - (state.link.last_pong ?? state.link.ts) > 45) {
			log("CAP link timeout, reconnecting");
			sap_disconnect();
		} else {
			return;
		}
	}
	let cap = state.cfg.cap_ip != "" ? state.cfg.cap_ip : state.cap_learned;
	if (cap) sap_connect(cap);
}

sap_report = function() {
	if (state.cfg.role != "sap" || !state.link?.authed) return;
	let clients = local_clients();
	if (state.prev_clients != null)
		diff_events(state.prev_clients, clients, state.self.name);
	state.prev_clients = clients;
	let link = state.link;
	try {
		link.chan.defer({
			method: "report_status",
			data: {
				info: self_info(),
				clients,
				alias_ver: state.aliases.ver,
				roam_ver: state.roam_ver_applied,
				roam_sig: roam_sig(current_roam_cfg()),
				backhaul_ver: state.backhaul_ver_applied,
				// 本机落盘的 K/V/R 生效状态，CAP 汇总后展示给用户
				kvr: applied_kvr(current_roam_cfg().ssids),
			},
			data_cb: function(m) {
				link.last_pong = time();
				if (m?.names) state.net_names = m.names;
				if (m?.roster) state.roster = m.roster;
			},
			cb: function(rc) {
				// complete 回调：rc == 0 为成功，仅失败/超时才断开重连
				if (rc != 0) {
					log("CAP link report failed");
					if (state.link == link) sap_disconnect();
				}
			},
		});
	} catch (e) {
		log("CAP link report error");
		if (state.link == link) sap_disconnect();
	}
};

// ------------------------------------------------------- TCP server (all)
conn_close = function(conn) {
	if (conn.chan) { try { conn.chan.disconnect(); } catch (e) {} }
	if (conn.sock) { try { conn.sock.close(); } catch (e) {} }
	if (conn.mac) {
		let mn = macnorm(conn.mac);
		let p = state.peers[mn];
		if (p && p.conn == conn) {
			p.conn = null;
			p.chan = null;
			p.authed = false;
		}
	}
};

function srv_rx(conn, req) {
	let args = req.args ?? {};

	if (!conn.authed) {
		if (req.type == "join" && state.cfg.role == "unconfigured") {
			// pairing: CAP pushes credentials to an unconfigured device
			if (args.nonce_echo != state.self.nonce || !args.token) {
				req.reply({ ok: false, error: "bad_nonce" });
				return 0;
			}
			state.cfg.token = args.token;
			state.cfg.cap_ip = args.cap_ip ?? "";
			state.cfg.role = "sap";
			save_config();
			req.reply({ ok: true });
			push_event("paired", "", args.cap_ip ?? "");
			uloop.timer(300, reconfigure);
			return 0;
		}
		if (req.type == "auth") {
			let expect = sha256(state.cfg.token + ":" + conn.nonce);
			if (state.cfg.token == "" || args.digest != expect) {
				req.reply({ ok: false, error: "auth" });
				conn_close(conn);
				return 0;
			}
			let mn = macnorm(args.mac);
			conn.authed = true;
			conn.mac = uc(args.mac ?? "");
			conn.name = args.name;
			let p = state.peers[mn] ??= { clients: null }; // null = 未收过 report，首轮 diff 抑制
			p.mac = conn.mac;
			if (args.name) p.name = args.name;
			p.authed = true;
			p.last_seen = time();
			p.chan = conn.chan;   // 存 channel 本体，conn 仅用于关闭时清理
			p.conn = conn;
			push_event("ap_online", conn.mac, conn.name ?? "");
			req.reply({
				ok: true, role: state.cfg.role,
				alias_ver: state.aliases.ver,
				roam_ver: current_roam_cfg().config_ver,
				backhaul_ver: current_backhaul_cfg().config_ver,
				// CAP 的 DHCP 租约表：SAP 无 DHCP，借此在子 AP 拓扑显示主机名
				names: state.cfg.role == "cap" ? client_names() : {},
				// 全网络 AP/SSID 概览：子 AP 的开启前检查与主 AP 保持一致
				roster: state.cfg.role == "cap" ? ap_overview() : null,
			});
			if ((args.alias_ver ?? 0) < state.aliases.ver)
				push_aliases_to(mn);
			let roam = current_roam_cfg();
			let rsig = roam_sig(roam);
			// ver 落后或内容签名不一致都重新下发：后者用于修复历史遗留的
			// SAP 本地配置与主 AP 不一致（例如只同步了 enabled/ver）
			if (state.cfg.role == "cap" &&
			    ((args.roam_ver ?? -1) < roam.config_ver ||
			     (args.roam_sig && args.roam_sig != rsig)))
				push_roam_to(mn);
			let bh = current_backhaul_cfg();
			if (state.cfg.role == "cap" && bh.enabled &&
			    (args.backhaul_ver ?? -1) < bh.config_ver)
				push_backhaul_to(mn);
			return 0;
		}
		return 0;
	}

	// authed dispatch
	let mn = macnorm(conn.mac);
	switch (req.type) {
	case "report_status": {
		let p = state.peers[mn] ??= { clients: null };
		let prev = p.clients;
		p.info = args.info;
		p.clients = args.clients ?? {};
		p.alias_ver = args.alias_ver ?? 0;
		p.roam_ver = args.roam_ver ?? 0;
		p.roam_sig = args.roam_sig ?? "";
		p.backhaul_ver = args.backhaul_ver ?? 0;
		p.kvr = args.kvr ?? null;
		p.last_seen = time();
		if (prev != null) // 首轮 report 不产 join/leave 事件
			diff_events(prev, p.clients, p.info?.name ?? conn.name ?? mn);
		owner_events(local_clients()); // SAP 终端表更新后立即重算归属（含跨 AP 迁移）
		if (p.alias_ver < state.aliases.ver)
			push_aliases_to(mn);
		let roam = current_roam_cfg();
		if (p.roam_ver < roam.config_ver ||
		    (p.roam_sig != "" && p.roam_sig != roam_sig(roam)))
			push_roam_to(mn);
		let bh = current_backhaul_cfg();
		if (bh.enabled && p.backhaul_ver < bh.config_ver)
			push_backhaul_to(mn);
		req.reply({ ok: true, alias_ver: state.aliases.ver,
		            roam_ver: roam.config_ver, backhaul_ver: bh.config_ver,
		            names: state.cfg.role == "cap" ? client_names() : {},
		            roster: state.cfg.role == "cap" ? ap_overview() : null });
		break;
	}
	case "report_event":
		push_event(args.etype ?? "peer_event", args.mac ?? "", args.info ?? "", args.name ?? "");
		req.reply({ ok: true });
		break;
	case "get_topology":
		req.reply(build_topology());
		break;
	case "get_client_detail": {
		let cmn = macnorm(args.mac);
		let c = local_clients()[cmn];
		if (c)
			req.reply({ ok: true, client: client_node(cmn, c, mn) });
		else
			req.reply({ ok: false });
		break;
	}
	case "alias_update":
		if (state.cfg.role == "cap" &&
		    alias_apply(args.mac, args.name, args.icon, args.note)) {
			alias_broadcast();
			req.reply({ ok: true, ver: state.aliases.ver });
		} else {
			req.reply({ ok: false });
		}
		break;
	default:
		req.reply({ ok: false, error: "unknown_method" });
	}
	return 0;
}

function srv_accept() {
	while (true) {
		let addr = {};
		let cs = tcp_srv.accept(addr);
		if (!cs) break;
		let conn = { sock: cs, authed: false, nonce: randhex(16) };
		conn.chan = libubus.open_channel(
			cs,
			function(req) { return srv_rx(conn, req); },
			function() { conn_close(conn); });
		conn.chan.request({
			method: "hello",
			data: { mac: state.self.mac, role: state.cfg.role,
			        nonce: conn.nonce },
			return: "ignore",
		});
	}
}

function setup_tcp() {
	tcp_srv = socket.create(socket.AF_INET,
		socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
	if (!tcp_srv) { log("tcp create failed"); return; }
	tcp_srv.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	if (!tcp_srv.bind("0.0.0.0:" + TCP_PORT) || !tcp_srv.listen(8)) {
		log("tcp bind/listen failed: " + socket.error());
		tcp_srv.close(); tcp_srv = null;
		exit(1);   // fail-fast：避免僵尸实例与正常实例竞争
	}
	uloop.handle(tcp_srv.fileno(), srv_accept, uloop.ULOOP_READ);
}

// ------------------------------------------------------- push helpers (CAP)
// 通道写失败时清理对端状态，避免僵尸连接导致守护进程崩溃
function peer_link_dead(mn, what) {
	let p = state.peers[mn];
	log(sprintf("%s to %s failed, marking peer offline", what, mn));
	if (!p) return;
	p.authed = false;
	p.chan = null;
	if (p.conn) { let c = p.conn; p.conn = null; conn_close(c); }
}

push_aliases_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return;
	try {
		p.chan.defer({
			method: "push_aliases",
			data: { aliases: state.aliases },
			data_cb: function() {}, cb: function() {},
		});
	} catch (e) {
		peer_link_dead(mn, "push_aliases");
	}
};

push_roam_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.roam_pushing) return true; // 推送在途，避免 auth+report 竞争重复下发
	let roam = current_roam_cfg();
	let name = p.info?.name ?? p.name ?? mn;
	p.roam_pushing = true;
	try {
		p.chan.defer({
			method: "push_roam_config",
			data: { roam, members: member_list(), wifi: wifi_export() },
			data_cb: function(m) {
				p.roam_pushing = false;
				apply_result_update(mn, name, m?.ok ?? false, m?.ver ?? null, null, m?.kvr ?? null);
			},
			cb: function(rc) {
				// 成功时 data_cb 已写入结果；仅失败/超时标记 timeout
				if (rc != 0) {
					p.roam_pushing = false;
					apply_result_update(mn, name, false, null, "timeout");
				}
			},
		});
	} catch (e) {
		p.roam_pushing = false;
		peer_link_dead(mn, "push_roam_config");
		return false;
	}
	return true;
};

apply_result_update = function(mn, name, ok, ver, err, kvr) {
	if (!state.last_apply) return;
	for (let r in state.last_apply.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.ver = ver; r.error = err;
			if (kvr) r.kvr = kvr;
		}
	}
};

push_backhaul_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.bh_pushing) return true;
	let bh = current_backhaul_cfg();
	let name = p.info?.name ?? p.name ?? mn;
	p.bh_pushing = true;
	try {
		p.chan.defer({
			method: "push_backhaul_config",
			data: { backhaul: bh },
			data_cb: function(m) {
				p.bh_pushing = false;
				apply_backhaul_result_update(mn, name, m?.ok ?? false, m?.ver ?? null, m?.error ?? null);
			},
			cb: function(rc) {
				if (rc != 0) {
					p.bh_pushing = false;
					apply_backhaul_result_update(mn, name, false, null, "timeout");
				}
			},
		});
	} catch (e) {
		p.bh_pushing = false;
		peer_link_dead(mn, "push_backhaul_config");
		return false;
	}
	return true;
};

apply_backhaul_result_update = function(mn, name, ok, ver, err) {
	if (!state.last_backhaul) return;
	for (let r in state.last_backhaul.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.ver = ver; r.error = err;
		}
	}
};

// ------------------------------------------------------------------ ubus API
function find_client(mn) {
	let local = local_clients();
	if (local[mn])
		return { node: client_node(mn, local[mn], macnorm(state.self.mac)),
		         ap: state.self.name };
	for (let pmn, p in state.peers) {
		let c = p.clients?.[mn];
		if (c) {
			// SAP 上报可能缺 ip/hostname，用本机 leases/ARP 补全
			if (c.ip == null || c.hostname == null) {
				let leases = parse_leases();
				let neigh = parse_neigh();
				if (c.ip == null)
					c.ip = leases[mn]?.ip ?? neigh[mn]?.ip ?? null;
				if (c.hostname == null)
					c.hostname = leases[mn]?.hostname ?? null;
			}
			return { node: client_node(mn, c, pmn),
			         ap: p.info?.name ?? p.name ?? pmn };
		}
	}
	return null;
}

let api_obj = {
	status: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let online = 0, nclients = 0;
			for (let mn, p in state.peers) {
				if (p.authed) online++;
				nclients += length(keys(p.clients ?? {}));
			}
			nclients += length(keys(local_clients()));
			// SAP 以 CAP 下发的概览为准，成员 AP 计数与主AP保持一致
			let peers_total = length(keys(state.peers));
			if (state.cfg.role == "sap" && type(state.roster?.aps) == "array") {
				let o = 0, t = 0;
				let self_mn = macnorm(state.self.mac);
				for (let a in state.roster.aps) {
					if (a.id == self_mn) continue;
					t++;
					if (a.online) o++;
				}
				online = o; peers_total = t;
			}
			return {
				version: DAEMON_VERSION,
				daemon_started: daemon_started,
				kvr: applied_kvr(current_roam_cfg().ssids),
				role: state.cfg.role, name: state.self.name,
				mac: state.self.mac, ip: state.self.ip,
				cap_ip: state.cfg.cap_ip != "" ? state.cfg.cap_ip : state.cap_learned,
				model: state.self.model, firmware: state.self.firmware,
				uptime: self_uptime(),
				peers_online: online, peers_total,
				clients_total: nclients,
				roam: current_roam_cfg(),
				backhaul: current_backhaul_cfg(),
				alias_ver: state.aliases.ver,
				last_apply: state.last_apply,
				last_backhaul: state.last_backhaul,
			};
		},
	},
	topology: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return build_topology(); },
	},
	client_detail: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			let r = find_client(macnorm(mac));
			if (!r) return libubus.STATUS_NOT_FOUND;
			return { ok: true, client: r.node, ap: r.ap };
		},
	},
	set_alias: {
		args: { ubus_rpc_session: "", mac: "", name: "", icon: "", note: "" },
		call: function(req) {
			let a = req.args;
			if (!a.mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role == "sap" && state.link?.authed) {
				// forward to CAP; CAP broadcasts the new alias table
				try {
					state.link.chan.defer({
						method: "alias_update",
						data: { mac: a.mac, name: a.name, icon: a.icon, note: a.note },
						data_cb: function() {}, cb: function() {},
					});
				} catch (e) {
					sap_disconnect();
					return { ok: false, error: "link_down" };
				}
				return { ok: true, forwarded: true };
			}
			if (!alias_apply(a.mac, a.name, a.icon, a.note))
				return { ok: false, error: "invalid_mac" };
			alias_broadcast();
			return { ok: true, ver: state.aliases.ver };
		},
	},
	set_role: {
		args: { ubus_rpc_session: "", role: "" },
		call: function(req) {
			let r = req.args.role;
			if (index([ "cap", "sap", "unconfigured" ], r) < 0)
				return libubus.STATUS_INVALID_ARGUMENT;
			if (r == "sap")
				return { ok: false, error: "sap_via_pairing" };
			state.cfg.role = r;
			if (r == "cap") ensure_token();
			if (r == "unconfigured") {
				state.cfg.token = "";
				state.cfg.cap_ip = "";
			}
			save_config();
			reconfigure();
			return { ok: true, role: r };
		},
	},
	get_roam: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			// SAP 侧用 CAP 下发的全网络概览，避免 SSID 组 AP 数量与成员列表
			// 只看到本机（显示 1 台）而与主AP不一致
			let use_roster = (state.cfg.role == "sap" && state.roster?.groups);
			let members = member_list();
			if (use_roster && type(state.roster.aps) == "array") {
				members = [];
				for (let a in state.roster.aps)
					push(members, { mac: maccolon(a.id), name: a.name ?? a.id });
			}
			return {
				roam: current_roam_cfg(),
				groups: use_roster ? state.roster.groups : ssid_groups(),
				members,
				kvr: applied_kvr(current_roam_cfg().ssids),
			};
		},
	},
	set_roam: {
		args: {
			ubus_rpc_session: "",
			enabled: false, ssids: [], r_fast: true, ft_mode: "",
			ft_over_ds: false, k_neighbor: false,
			k_beacon: false, v_bss_transition: false,
			rssi_profile: "", rssi_threshold: 0,
		},
		call: function(req) {
			let a = req.args;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let profile = a.rssi_profile ?? "balanced";
			if (index([ "aggressive", "balanced", "conservative", "custom" ], profile) < 0)
				profile = "balanced";
			let threshold = int(a.rssi_threshold ?? 0);
			if (profile != "custom" || threshold == 0)
				threshold = rssi_preset(profile);
			if (threshold > -30) threshold = -30;
			if (threshold < -95) threshold = -95;
			let cur = uci.cursor();
			cur.load("wifiroam");
			let ver = int(cur.get("wifiroam", "roam", "config_ver") ?? "0") + 1;
			cur.set("wifiroam", "roam", "enabled", a.enabled ? "1" : "0");
			cur.set("wifiroam", "roam", "ssids", a.ssids ?? []);
			cur.set("wifiroam", "roam", "r_fast", a.r_fast ? "1" : "0");
			cur.set("wifiroam", "roam", "ft_mode",
				a.ft_mode == "explicit" ? "explicit" : "simple");
			cur.set("wifiroam", "roam", "ft_over_ds", a.ft_over_ds ? "1" : "0");
			cur.set("wifiroam", "roam", "k_neighbor", a.k_neighbor ? "1" : "0");
			cur.set("wifiroam", "roam", "k_beacon", a.k_beacon ? "1" : "0");
			cur.set("wifiroam", "roam", "v_bss_transition",
				a.v_bss_transition ? "1" : "0");
			cur.set("wifiroam", "roam", "rssi_profile", profile);
			cur.set("wifiroam", "roam", "rssi_threshold", "" + threshold);
			cur.set("wifiroam", "roam", "config_ver", "" + ver);
			cur.commit("wifiroam");

			let roam = current_roam_cfg();
			let members = member_list();
			let results = [];
			let lr = apply_roam_local(roam, members);
			push(results, { ap: state.self.mac, name: state.self.name,
			                ok: lr.ok, ver: lr.ver, kvr: applied_kvr(roam.ssids) });
			// 先落 last_apply，再推送，才能收集到各 SAP 的异步回执
			state.last_apply = { ts: time(), ver, results };
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_roam_to(mn);
			}
			return { ok: true, ver, results };
		},
	},
	precheck: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return precheck(); },
	},
	get_backhaul: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			return {
				backhaul: current_backhaul_cfg(),
				radios: wifi_radios(),
				self: { mac: state.self.mac, name: state.self.name },
			};
		},
	},
	set_backhaul: {
		args: {
			ubus_rpc_session: "", enabled: false,
			ssid: "", key: "", device: "",
		},
		call: function(req) {
			let a = req.args;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let prev = current_backhaul_cfg();
			let ssid = (a.ssid ?? "") != "" ? a.ssid : BACKHAUL_DEFAULT_SSID;
			let key = a.key ?? "";
			if (key == "" && a.enabled)
				key = prev.key != "" ? prev.key : randhex(16);
			let ver = (prev.config_ver ?? 0) + 1;

			let cur = uci.cursor();
			cur.load("wifiroam");
			cur.set("wifiroam", "backhaul", "enabled", a.enabled ? "1" : "0");
			cur.set("wifiroam", "backhaul", "ssid", ssid);
			cur.set("wifiroam", "backhaul", "key", key);
			cur.set("wifiroam", "backhaul", "device", a.device ?? "");
			cur.set("wifiroam", "backhaul", "config_ver", "" + ver);
			cur.commit("wifiroam");

			let bh = current_backhaul_cfg();
			let results = [];
			let lr = apply_backhaul_local(bh, "cap");
			push(results, { ap: state.self.mac, name: state.self.name,
			                ok: lr.ok, ver: lr.ver, error: lr.error ?? null });
			state.last_backhaul = { ts: time(), ver, results };
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_backhaul_to(mn);
			}
			return { ok: true, ver, results, backhaul: bh };
		},
	},
	discover: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let out = [];
			for (let mn, d in state.discovered)
				push(out, {
					mac: d.mac, ip: d.ip, name: d.name,
					model: d.model, last_seen: d.last_seen,
				});          // 不下发 nonce，配对所需凭据仅留在守护进程内
			return { devices: out };
		},
	},
	pair: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let mn = macnorm(mac);
			let d = state.discovered[mn];
			if (!d) return { ok: false, error: "not_found" };
			if (!d.ip) return { ok: false, error: "no_ip" };

			let addr = socket.sockaddr({ address: d.ip, port: TCP_PORT });
			let sock = socket.create(socket.AF_INET,
				socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
			if (!addr || !sock) return { ok: false, error: "socket" };
			sock.connect(addr);
			let done = false;
			let chan = null;
			chan = libubus.open_channel(sock,
				function(req2) {
					if (req2.type == "hello" && chan) {
						try {
							chan.defer({
								method: "join",
								data: {
									token: state.cfg.token,
									cap_ip: state.self.ip,
									nonce_echo: d.nonce,
								},
								data_cb: function(m) {
									done = true;
									if (m?.ok) {
										push_event("paired", d.mac, d.ip);
										delete state.discovered[mn];
									}
									chan.disconnect();
								},
								cb: function(rc) {
									// 成功时 data_cb 已处理并断开；仅失败时兜底断开
									if (rc != 0 && chan)
										try { chan.disconnect(); } catch (e) {}
								},
							});
						} catch (e) {
							try { chan.disconnect(); } catch (e2) {}
						}
					}
					return 0;
				},
				function() {});
			uloop.timer(8000, function() {
				if (!done && chan) { try { chan.disconnect(); } catch (e) {} }
			});
			return { ok: true, ip: d.ip };
		},
	},
	unpair: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let mn = macnorm(mac);
			let p = state.peers[mn];
			if (!p) return { ok: false, error: "not_found" };
			if (p.authed && p.chan)
				try {
					p.chan.defer({
						method: "leave", data: {},
						data_cb: function() {}, cb: function() {},
					});
				} catch (e) {}
			delete state.peers[mn];
			push_event("unpaired", maccolon(mn), p.name ?? "");
			return { ok: true };
		},
	},
	roam_log: {
		args: { ubus_rpc_session: "", limit: 0 },
		call: function(req) {
			let limit = int(req.args.limit ?? 50);
			if (limit <= 0) limit = 50;
			if (limit > MAX_EVENTS) limit = MAX_EVENTS;
			let ev = state.events;
			if (length(ev) > limit)
				ev = slice(ev, length(ev) - limit);
			return { events: ev };
		},
	},
};

// ------------------------------------------------------- RSSI steering (11v)
// 信号低于阈值时，通过 hostapd 的 BSS Transition Management 主动引导终端
// 切换到更合适的 AP。CAP/SAP 各自对自己下挂的终端执行，避免跨节点转发。
function steer_tick() {
	if (state.cfg.role == "unconfigured") return;
	let roam = current_roam_cfg();
	if (!roam.enabled || !roam.v_bss_transition) return;
	let threshold = roam.rssi_threshold;
	if (threshold == null || threshold >= 0) return;
	if (!length(roam.ssids)) return;

	let has_peer = false;
	for (let mn, p in state.peers)
		if (p.authed) { has_peer = true; break; }
	if (!has_peer) return;   // 单 AP 无处分流，引导只会让终端掉线

	let now = time();
	let clients = local_clients();
	for (let mn, c in clients) {
		if (c.type != "wifi" || !c.ifname) continue;
		if (c.ssid == null || index(roam.ssids, c.ssid) < 0) continue;
		let rssi = c.rssi;
		if (rssi == null) continue;
		rssi = int(rssi);
		if (rssi >= threshold) continue;
		if (c.connected_time != null && int(c.connected_time) < MIN_STEER_ASSOC) continue;
		if (now - (state.steer_last[mn] ?? 0) < STEER_COOLDOWN) continue;
		try {
			ubusc.call("hostapd." + c.ifname, "bss_transition_request", {
				addr: maccolon(mn),
				disassociation_imminent: true,
				disassociation_timer: 5,
				validity_period: 10,
			});
			state.steer_last[mn] = now;
			push_event("roam_steer", maccolon(mn),
				sprintf("rssi=%d < %d", rssi, threshold),
				client_name_of(mn, clients));
		} catch (e) {
			log("steer " + mn + " failed");
		}
	}
}

// ---------------------------------------------------------------- lifecycle
ensure_token = function() {
	if (state.cfg.role == "cap" && state.cfg.token == "") {
		state.cfg.token = sha256(sprintf("wifiroam-%d-%d-%s",
			time(), rand(), state.self.mac));
		save_config();
		log("generated new network token");
	}
};

reconfigure = function() {
	load_config();
	state.self.name = state.cfg.name != "" ? state.cfg.name : state.self.hostname;
	sap_disconnect();
	state.peers = {};
	state.cap_learned = null;
	state.prev_clients = null;
	state.wired_seen = {};
	state.prev_owner = null;
	state.steer_last = {};
	send_hello();
};

function main() {
	srand(time());
	uloop.init();

	ubusc = libubus.connect(null, 60);
	if (!ubusc) {
		log("ubus connect failed");
		exit(1);
	}

	load_config();
	alias_load();
	detect_self();
	ensure_token();

	setup_udp();
	setup_tcp();

	ubusc.publish("wifiroam", api_obj);

	uloop.interval(HELLO_INTERVAL, send_hello);
	uloop.interval(TICK_INTERVAL, sap_tick);
	uloop.interval(TICK_INTERVAL, sap_report);
	uloop.interval(TICK_INTERVAL, expire_tick);
	uloop.interval(TICK_INTERVAL, backhaul_tick);
	uloop.interval(TICK_INTERVAL, steer_tick);
	uloop.interval(TICK_INTERVAL, function() {
		if (state.cfg.role != "cap") return;
		let cur = local_clients();
		if (state.prev_clients != null)
			diff_events(state.prev_clients, cur, state.self.name);
		state.prev_clients = cur;
		owner_events(cur);
	});

	send_hello();
	log(sprintf("started role=%s", state.cfg.role));
	uloop.run();
}

main();
