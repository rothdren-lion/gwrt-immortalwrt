// Keep wire JSON serialization separate from shell command execution.
import * as fs from 'fs';

function object(s) {
	if (type(s) == 'string' && substr(s, 0, 1) == '@') s = fs.readfile(substr(s, 1));
	try { let v = json(s ?? ''); return type(v) == 'object' ? v : {}; }
	catch (e) { return {}; }
}
function array(v) { return type(v) == 'array' ? v : []; }
function mac(v) {
	let m = lc(replace('' + (v ?? ''), /[^0-9a-fA-F]/g, ''));
	return length(m) == 12 ? m : '';
}
function colon(id) {
	let parts = [];
	for (let i = 0; i < 12; i += 2) push(parts, substr(id, i, 2));
	return uc(join(':', parts));
}
function member(n, wanted) {
	return n.type == 'ap' && mac(n.mac ?? n.id) == wanted &&
		(n.authed == true || n.authed == 1) && n.online != false &&
		index(['cap', 'sap'], n.role) >= 0;
}
function mesh(st, disc, topo, apmode) {
	if (index(['cap', 'sap', 'unconfigured'], st.role) < 0)
		return { available: false };
	let devices = [], seen = {};
	if (st.role == 'cap') {
		for (let d in array(disc.devices)) {
			let id = mac(d.mac);
			if (id == '' || seen[id]) continue;
			seen[id] = true;
			push(devices, { mac: colon(id), ip: d.ip ?? '',
				name: d.name ?? '', model: d.model ?? '', last_seen: d.last_seen ?? 0,
				role: 'unconfigured', pairable: true });
		}
	}
	let nodes = array(topo.nodes), members = [];
	for (let n in nodes) {
		let id = mac(n.mac ?? n.id);
		if (id == '' || id == mac(topo.self ?? st.mac) || !member(n, id)) continue;
		let clients = 0;
		for (let c in nodes)
			if (c.type == 'client' && mac(c.parent) == id) clients++;
		push(members, { mac: n.mac ?? n.id, ip: n.ip ?? '', name: n.name ?? '',
			model: n.model ?? '', role: n.role, online: true, clients,
			uplink: { type: n.uplink?.type ?? 'unknown' } });
	}
	return { available: true, role: st.role, cap_ip: st.cap_ip ?? '',
		peers_online: st.peers_online ?? 0, peers_total: st.peers_total ?? 0,
		apmode: apmode == '1' ? 1 : 0, ssids: array(st.roam?.ssids),
		discover: map(devices, d => d.mac), discovered_devices: devices, members,
		firmware: st.firmware ?? '', refresh_interval: 5 };
}

let mode = ARGV[0], result;
if (mode == 'quote') {
	let s = sprintf('%.J', ARGV[1] ?? '');
	print(substr(s, 1, length(s) - 2));
	exit(0);
}
else if (mode == 'mesh' || mode == 'mesh-status') {
	result = mesh(object(ARGV[1]), object(ARGV[2]), object(ARGV[3]), ARGV[4]);
	if (mode == 'mesh-status') {
		let st = object(ARGV[1]);
		result.backend = 'wifiroam';
		result.version = st.version ?? 2;
		result.hostname = st.name ?? '';
		result.portal = st.role == 'cap';
		result.host_ipv4 = ARGV[5] ?? st.ip ?? '';
		result.host_ipv6 = ARGV[6] ?? '';
		result.active_node_count = result.peers_online ?? 0;
		result.system_time = ARGV[7] ?? '';
		result.peers = result.members ?? [];
	}
}
else if (mode == 'member') {
	let id = mac(ARGV[2]), found = false;
	for (let n in array(object(ARGV[1]).nodes))
		if (id != '' && member(n, id)) found = true;
	print(found ? '1\n' : '0\n');
	exit(0);
}
else if (mode == 'payload') {
	let raw = fs.readfile(ARGV[1]);
	result = object(raw);
	delete result.hardware_id;
	result.device_id = ARGV[2];
	result.agent_version = 1712;
	result.arch = ARGV[3];
	result.firmware_version ??= ARGV[4];
	result.telemetry ??= {};
	result.clients ??= [];
	result.packages ??= {};
	result.containers ??= {};
	result.oaf ??= {};
	result.topology ??= {};
	result.gwrt_mesh = object(ARGV[5]);
}
else {
	exit(1);
}
printf('%.J\n', result);
