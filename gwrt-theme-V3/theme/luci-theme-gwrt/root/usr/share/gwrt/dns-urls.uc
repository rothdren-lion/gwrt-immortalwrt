// Aggregate per-client DNS lookups into a small JSON snapshot for the theme.
// dnsmasq writes one line per query to /tmp/dnsq.log (log-queries + log-facility).
import * as fs from 'fs';

const log_path = '/tmp/dnsq.log';
const runtime = '/tmp/gwrt-theme';
const out_path = runtime + '/dns-urls.json';
const lock_path = runtime + '/dns-urls.lock';

const window_seconds = 900;        // keep domains seen within 15 minutes
const max_domains_per_device = 80; // bound the payload the theme parses
const max_devices = 64;
const rotate_bytes = 2 * 1024 * 1024;
const flush_ms = 5000;

let devices = {};
let offset = 0;

function atomic_write(path, value) {
	let tmp = path + '.new', text = sprintf('%J\n', value);
	if (fs.writefile(tmp, text) != length(text) || !fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}
	return true;
}

function prune_device(ip, now) {
	let dev = devices[ip];
	if (!dev) return;
	for (let domain in dev)
		if (now - dev[domain].last > window_seconds)
			delete dev[domain];
	if (!length(keys(dev))) delete devices[ip];
}

function prune(now) {
	for (let ip in devices) prune_device(ip, now);
	let ids = keys(devices);
	if (length(ids) <= max_devices) return;
	// Drop the stalest client first; the theme only ever shows recent activity.
	sort(ids, function(a, b) {
		let la = 0, lb = 0;
		for (let d in devices[a]) la = max(la, devices[a][d].last);
		for (let d in devices[b]) lb = max(lb, devices[b][d].last);
		return lb - la;
	});
	for (let i = max_devices; i < length(ids); i++) delete devices[ids[i]];
}

function ingest(text, now) {
	for (let line in split(text, '\n')) {
		let m = match(line, /query\[[A-Z]+\] ([^ ]+) from ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$/);
		if (!m) continue;
		let domain = lc(m[1]), ip = m[2];
		if (!domain || domain == '.' || match(domain, /(^|\.)(lan|local|localdomain|arpa)$/)) continue;
		// Query forwarding setups (daed, dnsmasq redirect rules) show every client
		// lookup as loopback. Keep those domains in a bucket without a device so the
		// dashboard still lists real sites instead of an empty card.
		if (ip == '127.0.0.1' || ip == '::1') ip = 'local';
		if (match(domain, /^(connectivitycheck\.|time[0-9]?\.|pool\.ntp\.|ntp\.|op\.gwrt\.uk$)/)) continue;
		let dev = devices[ip];
		if (!dev) dev = devices[ip] = {};
		let entry = dev[domain];
		if (!entry) entry = dev[domain] = { hits: 0, last: now };
		entry.hits++;
		entry.last = now;
	}
}

function snapshot(now) {
	let out = { ts: now, devices: {} };
	for (let ip in devices) {
		let rows = [];
		for (let domain in devices[ip]) {
			let e = devices[ip][domain];
			if (now - e.last <= window_seconds)
				push(rows, { name: domain, hits: e.hits, last: e.last });
		}
		if (!length(rows)) continue;
		sort(rows, function(a, b) { return b.last - a.last || b.hits - a.hits; });
		out.devices[ip] = { domains: slice(rows, 0, max_domains_per_device) };
	}
	return out;
}

let mode = ARGV[0];
if (mode != 'daemon') {
	// One-shot read for debugging: print the current snapshot.
	printf('%J\n', snapshot(time()));
	exit(0);
}

let st = fs.lstat(runtime);
if (!st) fs.mkdir(runtime, 0700);
let lock = fs.open(lock_path, 'w', 0600);
if (!lock || !lock.lock('xn')) exit(1);

let stopping = false;
signal('TERM', function() { stopping = true; });
signal('INT', function() { stopping = true; });

while (!stopping) {
	let text = fs.readfile(log_path) || '';
	if (length(text) < offset) offset = 0;      // file was rotated underneath us
	if (length(text) > offset) {
		ingest(substr(text, offset), time());
		offset = length(text);
	}
	let now = time();
	prune(now);
	atomic_write(out_path, snapshot(now));
	if (length(text) > rotate_bytes) {
		// dnsmasq keeps the log open in append mode, so truncation resumes at 0.
		fs.writefile(log_path, '');
		offset = 0;
	}
	if (!stopping) sleep(flush_ms);
}
