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
	let plugin = read_command('if [ -x /usr/bin/timeout ]; then /usr/bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; elif [ -x /bin/timeout ]; then /bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; else /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; fi 2>/dev/null');
	if (plugin?.ok == true && type(plugin?.data?.interfaces) == 'array') return plugin;
	// Last resort: query Bandix's local HTTP API directly.
	return read_command('/usr/bin/curl -s -m 5 http://127.0.0.1:8787/api/snapshot 2>/dev/null');
}
function valid_num(n) { return type(n) == 'int' || type(n) == 'double' ? n >= 0 : false; }
function sample_from_iface(item, now, uptime, boot) {
	let c = item.cumulative, m = item.metrics || {};
	let bytes = empty_bytes(), rates = {}, available = {};
	for (let family in ['4', '6']) {
		let up = c['up_v' + family + '_bytes'], down = c['down_v' + family + '_bytes'];
		available['ipv' + family] = valid_num(up) && valid_num(down);
		if (!available['ipv' + family]) continue;
		bytes['up' + family] = up; bytes['down' + family] = down;
		rates['up' + family] = valid_num(m['up_v' + family + '_bps']) ? m['up_v' + family + '_bps'] / 8.0 : null;
		rates['down' + family] = valid_num(m['down_v' + family + '_bps']) ? m['down_v' + family + '_bps'] / 8.0 : null;
	}
	if (!available.ipv4 && !available.ipv6) return null;
	return { now, uptime, boot, source: 'bandix:' + item.ifname, bytes, rates, available };
}
function probe() {
	let snapshot = bandix_snapshot();
	let network = ubus_call('network.interface', 'dump');
	let uptime = +split(fs.readfile('/proc/uptime') || '0', ' ')[0];
	let boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
	let sample = select_sample(snapshot, network, time(), uptime, boot);
	if (!sample && snapshot?.ok == true && type(snapshot?.data?.interfaces) == 'array') {
		// Bandix may not monitor WAN (e.g. only br-lan). Fall back to the first
		// interface with cumulative data so the traffic chart still shows data.
		for (let pass in [ 'wan', 'any' ]) {
			for (let item in snapshot.data.interfaces) {
				if (type(item.cumulative) != 'object') continue;
				if (pass == 'wan' && !match(item.ifname, /^(pppoe-wan|wan)([.@:].*)?$/)) continue;
				sample = sample_from_iface(item, time(), uptime, boot);
				if (sample) break;
			}
			if (sample) break;
		}
	}
	return sample;
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
	let sample = probe(), now = time();
	update_state(state, sample, now);
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
