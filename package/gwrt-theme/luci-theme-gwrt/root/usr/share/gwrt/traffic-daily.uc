import * as fs from 'fs';
import { select_sample, new_state, update_state, checkpoint_due, public_state, restore_state, persistent_state, empty_bytes } from 'gwrt.traffic';

const runtime = '/tmp/gwrt-theme';
const memory_file = runtime + '/traffic-state.json';
const permanent_dir = '/etc/gwrt';
const permanent_file = permanent_dir + '/traffic-daily.json';
const action = ARGV[0];

function read_json(path) {
	try { return json(fs.readfile(path)); } catch (e) { return null; }
}
function load_state() {
	return restore_state(read_json(memory_file), time()) || restore_state(read_json(permanent_file), time()) || new_state();
}
function atomic_write(path, value) {
	let tmp = path + '.new', text = sprintf('%J\n', value);
	if (fs.writefile(tmp, text) != length(text) || !fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}
	return true;
}
function checkpoint(state, now, uptime, boot) {
	if (!state.first) return false;
	let st = fs.lstat(permanent_dir);
	if (!st) { fs.mkdir(permanent_dir, 0700); st = fs.lstat(permanent_dir); }
	if (st?.type != 'directory' || st.uid != 0) return false;
	let saved = persistent_state(state, now, uptime, boot);
	if (!atomic_write(permanent_file, saved)) return false;
	state.persisted_at = saved.persisted_at;
	state.persisted_boot = saved.persisted_boot;
	state.persisted_uptime = saved.persisted_uptime;
	let sync = fs.popen('/bin/sync', 'r');
	if (sync) sync.close();
	return true;
}
function read_command(command) {
	let pipe = fs.popen(command, 'r');
	if (!pipe) return null;
	let raw = pipe.read('all'), code = pipe.close();
	try { return code == 0 ? json(raw) : null; } catch (e) { return null; }
}
function ubus_call(object, method) {
	// Both arguments are compile-time constants, with bounded ubus waits.
	return read_command('/bin/ubus -t 3 call ' + object + ' ' + method + ' 2>/dev/null');
}
function bandix_snapshot() {
	let snapshot = ubus_call('luci.bandix_plus', 'getSnapshot');
	if (snapshot?.ok == true && type(snapshot?.data?.interfaces) == 'array') return snapshot;
	// Some rpcd installations do not register the Bandix object, even though
	// its executable and local service are present. The fixed plugin command
	// also reads Bandix's configured port; no browser input enters the command.
	return read_command('if [ -x /usr/bin/timeout ]; then /usr/bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; elif [ -x /bin/timeout ]; then /bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; else /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; fi 2>/dev/null');
}
let bandix_wan_checked = false, bandix_wan_ok = false;
function bandix_wan_v6_from(snapshot) {
	let ifaces = snapshot?.data?.interfaces;
	if (type(ifaces) != 'array') return null;
	for (let it in ifaces) {
		if (it?.ifname != 'wan' && it?.zone != 'wan') continue;
		let cum = it?.cumulative;
		let up6 = cum?.up_v6_bytes, down6 = cum?.down_v6_bytes;
		if (valid_num(up6) && valid_num(down6)) return { up6, down6 };
	}
	return null;
}
function bandix_wan_v6(now) {
	if (!bandix_wan_checked) {
		bandix_wan_checked = true;
		let first = bandix_wan_v6_from(bandix_snapshot());
		bandix_wan_ok = first != null;
		return first;
	}
	return bandix_wan_ok ? bandix_wan_v6_from(bandix_snapshot()) : null;
}
function wan_netdev_name(network) {
	for (let item in (network?.interface || []))
		if (item.interface == 'wan') {
			let name = item.device || item.l3_device || '';
			if (type(name) != 'string') name = '';
			name = trim(name);
			if (name && name != 'lo') return name;
		}
	return 'wan';
}
function valid_num(n) { return type(n) == 'int' || type(n) == 'double' ? n >= 0 : false; }
function netdev_counters(ifname) {
	let raw = fs.readfile('/proc/net/dev');
	if (!raw) return null;
	for (let line in split(raw, '\n')) {
		let parts = [], fields = split(trim(line), ' ');
		for (let field in fields)
			if (field != '') push(parts, field);
		if (length(parts) < 10 || parts[0] != ifname + ':') continue;
		let rx = +parts[1], tx = +parts[9];
		if (!valid_num(rx) || !valid_num(tx)) continue;
		return { rx: rx, tx: tx };
	}
	return null;
}
function sample_from_netdev(network, now, uptime, boot, prev) {
	let ifname = wan_netdev_name(network);
	let c = netdev_counters(ifname);
	if (!c) return null;
	let source = 'netdev:' + ifname;
	let dt = prev && prev.source == source && prev.boot == boot && now > prev.now ? now - prev.now : 0;
	// /proc/net/dev 只有协议合并计数：把 Bandix 看得见的 WAN IPv6 累计值
	// 拆出来，剩余（含硬件卸载的 v4 流量）归到 IPv4/合计。没有 Bandix WAN
	// 数据时 ipv6 不可用，界面只显示一条合计曲线。
	let v6 = bandix_wan_v6(now), up6 = 0, down6 = 0, v6_reset = false;
	if (v6) {
		// Bandix 重启后 IPv6 累计值从 0 重新开始。若照旧直接相减，历史 IPv6
		// 字节会被一次性记到 IPv4/合计上；这里把本轮视为基线重置，合并计数
		// 全额算 IPv4，并跳过本轮 v6 速率（不产生负增量）。
		v6_reset = !!(prev && prev.source == source && prev.boot == boot &&
			(v6.up6 < prev.bytes.up6 || v6.down6 < prev.bytes.down6));
		if (v6_reset) {
			up6 = 0; down6 = 0;
		} else {
			up6 = v6.up6 <= c.tx ? v6.up6 : 0;
			down6 = v6.down6 <= c.rx ? v6.down6 : 0;
		}
	}
	let up = 0, down = 0, r_up6 = 0, r_down6 = 0;
	if (dt > 0) {
		up = c.tx - up6 >= prev.bytes.up4 ? (c.tx - up6 - prev.bytes.up4) / dt : 0;
		down = c.rx - down6 >= prev.bytes.down4 ? (c.rx - down6 - prev.bytes.down4) / dt : 0;
		if (v6 && !v6_reset && prev?.available?.ipv6 && up6 >= prev.bytes.up6 && down6 >= prev.bytes.down6) {
			r_up6 = (up6 - prev.bytes.up6) / dt;
			r_down6 = (down6 - prev.bytes.down6) / dt;
		}
	}
	return { now, uptime, boot, source,
		bytes: { up4: c.tx - up6, down4: c.rx - down6, up6, down6 },
		rates: { up4: up, down4: down, up6: r_up6, down6: r_down6 },
		available: { ipv4: true, ipv6: !!v6 }, v6_reset };
}
function probe(state) {
	let network = ubus_call('network.interface', 'dump');
	let uptime = +split(fs.readfile('/proc/uptime') || '0', ' ')[0];
	let boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
	let now = time();
	// Physical WAN counters stay complete when hardware flow offloading
	// bypasses the Linux bridge and the eBPF-based Bandix monitor.
	let sample = sample_from_netdev(network, now, uptime, boot, state?.last);
	if (sample) return sample;

	let snapshot = bandix_snapshot();
	return select_sample(snapshot, network, now, uptime, boot);
}

if (action == 'read') {
	// This path only reads: refreshing LuCI never samples or writes to flash.
	printf('%J\n', public_state(load_state(), time()));
	exit(0);
}
if (action != 'daemon') exit(1);

let lock = fs.open(runtime + '/traffic-daemon.lock', 'w', 0600);
if (!lock || !lock.lock('xn')) exit(1);
let state = load_state(), stopping = false;
signal('TERM', function() { stopping = true; });
signal('INT', function() { stopping = true; });
while (!stopping) {
	let sample = probe(state), now = time();
	// Switching to physical WAN counters: adopt their cumulative baseline once,
	// so totals match the port counters instead of only counting traffic seen
	// after the switch.
	let adopt = sample && index(sample.source, 'netdev:') == 0 &&
		(!state.last || state.last.source != sample.source);
	if (adopt) {
		state.totals = { up4: sample.bytes.up4, down4: sample.bytes.down4,
			up6: sample.bytes.up6, down6: sample.bytes.down6 };
		// 端口计数是开机以来的累计值，不能当成“今天”的增量。
		state.today = empty_bytes();
		state.last = sample;
		state.sampled = now;
		state.ok = true;
		atomic_write(memory_file, state);
	} else if (sample?.v6_reset) {
		// IPv6 累计值复位：只重对齐基线，不把历史 IPv6 字节补记成 IPv4，
		// 也不累加增量（代价是丢失本轮约 5 秒的流量）。
		state.last = sample;
		state.sampled = now;
		state.ok = true;
		atomic_write(memory_file, state);
	} else {
		update_state(state, sample, now);
	}
	// Checkpoint timing follows the router, even when the traffic probe fails.
	let uptime = +split(fs.readfile('/proc/uptime') || '0', ' ')[0];
	let boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
	if (checkpoint_due(state, now, uptime, boot)) checkpoint(state, now, uptime, boot);
	atomic_write(memory_file, state);
	if (!stopping) sleep(5000);
}
// Preserve final runtime state on a service restart without bypassing the
// half-hour flash interval. Power loss can discard the last 30 minutes.
atomic_write(memory_file, state);
