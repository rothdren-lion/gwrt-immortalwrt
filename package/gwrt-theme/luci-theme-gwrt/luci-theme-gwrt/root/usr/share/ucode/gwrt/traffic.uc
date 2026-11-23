// All byte accounting is independent of the browser and of flash writes.
const fields = [ 'up4', 'down4', 'up6', 'down6' ];
export function empty_bytes() { return { up4: 0, down4: 0, up6: 0, down6: 0 }; }
export function day_key(now) {
	let d = localtime(now);
	return sprintf('%04d-%02d-%02d', d.year, d.mon, d.mday);
}
export function month_key(now) {
	let d = localtime(now);
	return sprintf('%04d-%02d', d.year, d.mon);
}
export function year_key(now) {
	let d = localtime(now);
	return sprintf('%04d', d.year);
}
function midnight(now) {
	let d = localtime(now);
	d.hour = 0; d.min = 0; d.sec = 0;
	return timelocal(d);
}
function month_start(now) {
	let d = localtime(now);
	d.mday = 1; d.hour = 0; d.min = 0; d.sec = 0;
	return timelocal(d);
}
function year_start(now) {
	let d = localtime(now);
	d.mon = 1; d.mday = 1; d.hour = 0; d.min = 0; d.sec = 0;
	return timelocal(d);
}
function valid_number(n) { return (type(n) == 'int' || type(n) == 'double') && n >= 0; }

// Prefer the primary WAN's real/netifd device. PPPoE commonly reports a
// physical "wan" entry with zone "unknown"; never add LAN to the same traffic.
export function select_sample(snapshot, network, now, uptime, boot) {
	let data = snapshot?.ok == true ? snapshot.data : null;
	if (type(data?.interfaces) != 'array') return null;
	let wan = null;
	for (let item in (network?.interface || []))
		if (item.interface == 'wan') { wan = item; break; }
	let selected = null;
	for (let name in [ wan?.l3_device, wan?.device ]) {
		if (!name) continue;
		for (let item in data.interfaces)
			if (item.ifname == name && type(item.cumulative) == 'object') { selected = item; break; }
		if (selected) break;
	}
	if (!selected)
		for (let item in data.interfaces)
			if (item.zone == 'wan' && type(item.cumulative) == 'object') { selected = item; break; }
	if (!selected) return null;
	let c = selected.cumulative, m = selected.metrics || {}, bytes = empty_bytes(), rates = {}, available = {};
	for (let family in [ '4', '6' ]) {
		let up = c['up_v' + family + '_bytes'], down = c['down_v' + family + '_bytes'];
		available['ipv' + family] = valid_number(up) && valid_number(down);
		if (!available['ipv' + family]) continue;
		bytes['up' + family] = up; bytes['down' + family] = down;
		for (let direction in [ 'up', 'down' ]) {
			let rate = m[direction + '_v' + family + '_bps'];
			rates[direction + family] = valid_number(rate) ? rate / 8.0 : null;
			if (wan?.up == false) rates[direction + family] = 0;
		}
	}
	if (!available.ipv4 && !available.ipv6) return null;
	return { now, uptime, boot, source: 'bandix:' + selected.ifname, bytes, rates, available };
}

// Only these aggregates and their counter baseline are stored on flash.
// Short graph history belongs exclusively to the runtime state in /tmp.
export function week_key(now) {
	let d = localtime(now);
	d.mday -= (d.wday + 6) % 7;
	d.hour = 0; d.min = 0; d.sec = 0;
	return day_key(timelocal(d));
}
function week_start(now) {
	let d = localtime(now);
	d.mday -= (d.wday + 6) % 7;
	d.hour = 0; d.min = 0; d.sec = 0;
	return timelocal(d);
}
function bytes_valid(bytes) {
	if (type(bytes) != 'object') return false;
	for (let k in fields) if (!valid_number(bytes[k])) return false;
	return true;
}
function bytes_copy(bytes) {
	let copy = empty_bytes();
	for (let k in fields) copy[k] = bytes[k];
	return copy;
}
export function new_state() {
	return { version: 3, first: 0, coverage_start: 0, totals: empty_bytes(),
		day_key: '', today: empty_bytes(), week_key: '', week: empty_bytes(),
		month_key: '', month: empty_bytes(), year_key: '', year: empty_bytes(),
		history: [], last: null, sampled: 0, ok: false,
		persisted_at: 0, persisted_boot: '', persisted_uptime: 0 };
}
export function restore_state(raw, now) {
	if ((raw?.version != 1 && raw?.version != 2 && raw?.version != 3) || !bytes_valid(raw.totals)) return null;
	let state = new_state();
	state.totals = bytes_copy(raw.totals);
	state.first = valid_number(raw.first) ? raw.first : 0;
	state.coverage_start = valid_number(raw.coverage_start) ? raw.coverage_start : state.first;
	if (raw.version == 1) {
		// Compact the previous daily map once. Keep the lifetime total and the
		// current calendar periods; discard all per-day detail afterwards.
		if (now >= 1704067200 && type(raw.days) == 'object') {
			state.day_key = day_key(now); state.week_key = week_key(now);
			state.month_key = month_key(now); state.year_key = year_key(now);
			for (let key, bytes in raw.days)
				if (bytes_valid(bytes)) {
					if (key == state.day_key)
						for (let k in fields) state.today[k] += bytes[k];
					if (key >= state.week_key && key <= state.day_key)
						for (let k in fields) state.week[k] += bytes[k];
					if (substr(key, 0, 7) == state.month_key && key <= state.day_key)
						for (let k in fields) state.month[k] += bytes[k];
					if (substr(key, 0, 4) == state.year_key && key <= state.day_key)
						for (let k in fields) state.year[k] += bytes[k];
				}
		}
	} else if (raw.version == 2) {
		if (!bytes_valid(raw.today) || !bytes_valid(raw.week)) return null;
		state.today = bytes_copy(raw.today); state.week = bytes_copy(raw.week);
		state.day_key = type(raw.day_key) == 'string' ? raw.day_key : '';
		state.week_key = type(raw.week_key) == 'string' ? raw.week_key : '';
		// Version 2 did not store monthly/yearly totals. Start their coverage
		// clock at migration so a partial period is never presented as complete.
		state.coverage_start = now;
	} else {
		if (!bytes_valid(raw.today) || !bytes_valid(raw.week) ||
			!bytes_valid(raw.month) || !bytes_valid(raw.year)) return null;
		state.today = bytes_copy(raw.today); state.week = bytes_copy(raw.week);
		state.month = bytes_copy(raw.month); state.year = bytes_copy(raw.year);
		state.day_key = type(raw.day_key) == 'string' ? raw.day_key : '';
		state.week_key = type(raw.week_key) == 'string' ? raw.week_key : '';
		state.month_key = type(raw.month_key) == 'string' ? raw.month_key : '';
		state.year_key = type(raw.year_key) == 'string' ? raw.year_key : '';
		state.persisted_at = valid_number(raw.persisted_at) ? raw.persisted_at : 0;
		state.persisted_boot = type(raw.persisted_boot) == 'string' ? raw.persisted_boot : '';
		state.persisted_uptime = valid_number(raw.persisted_uptime) ? raw.persisted_uptime : 0;
	}
	let last = raw.last;
	if (type(last) == 'object' && bytes_valid(last.bytes) && type(last.available) == 'object' &&
		type(last.source) == 'string' && type(last.boot) == 'string' && valid_number(last.now) && valid_number(last.uptime)) {
		state.last = { now: last.now, uptime: last.uptime, boot: last.boot, source: last.source,
			bytes: bytes_copy(last.bytes), available: { ipv4: last.available.ipv4 == true, ipv6: last.available.ipv6 == true }, rates: {} };
		for (let k in fields) state.last.rates[k] = valid_number(last.rates?.[k]) ? last.rates[k] : null;
	}
	state.sampled = valid_number(raw.sampled) ? raw.sampled : 0;
	state.ok = raw.ok == true;
	if (type(raw.history) == 'array') state.history = slice(raw.history, -60);
	return state;
}
export function persistent_state(state, now, uptime, boot) {
	let last = state.last;
	return { version: 3, first: state.first, coverage_start: state.coverage_start,
		totals: bytes_copy(state.totals), day_key: state.day_key, today: bytes_copy(state.today),
		week_key: state.week_key, week: bytes_copy(state.week),
		month_key: state.month_key, month: bytes_copy(state.month),
		year_key: state.year_key, year: bytes_copy(state.year),
		last: last ? { now: last.now, uptime: last.uptime, boot: last.boot, source: last.source,
			bytes: bytes_copy(last.bytes), available: last.available } : null,
		persisted_at: now, persisted_boot: boot || last?.boot || '',
		persisted_uptime: valid_number(uptime) ? uptime : last?.uptime || 0 };
}
function add_bytes(target, bytes, ratio) {
	for (let k in fields) target[k] += int(bytes[k] * ratio);
}
export function update_state(state, sample, now) {
	state.ok = sample != null;
	if (!sample) return state; // A failed probe must not erase any counters.
	let prev = state.last, delta = empty_bytes();
	let dated = now >= 1704067200;
	let compatible = prev && prev.source == sample.source && prev.boot == sample.boot && sample.uptime >= prev.uptime;
	if (!state.first && dated) { state.first = now; state.coverage_start = now; }
	let coverage_lost = prev && !compatible;
	if (prev && compatible) {
		for (let family in [ 'ipv4', 'ipv6' ])
			if (prev.available[family] != sample.available[family]) coverage_lost = true;
		for (let k in fields) {
			let family = index(k, '4') >= 0 ? 'ipv4' : 'ipv6';
			if (prev.available[family] && sample.available[family] && sample.bytes[k] < prev.bytes[k]) coverage_lost = true;
		}
	}
	if (dated && (coverage_lost || (!prev && state.sampled))) state.coverage_start = now;
	if (!prev && !state.sampled && !state.first) {
		for (let k in fields) state.totals[k] += sample.bytes[k];
	} else if (!prev && !state.sampled) {
		// Adopt existing counter totals once, without fabricating dated usage.
		for (let k in fields) if (!state.totals[k]) state.totals[k] = sample.bytes[k];
	} else if (compatible) {
		for (let k in fields) {
			let family = index(k, '4') >= 0 ? 'ipv4' : 'ipv6';
			if (!prev.available[family] || !sample.available[family]) continue;
			// A source/counter restart establishes a baseline, never a negative delta.
			if (sample.bytes[k] >= prev.bytes[k]) delta[k] = sample.bytes[k] - prev.bytes[k];
		}
		for (let k in fields) state.totals[k] += delta[k];
	}
	let span = prev ? now - prev.now : 0;
	let monotonic_span = prev ? sample.uptime - prev.uptime : 0;
	let clock_ok = compatible && span > 0 && (span - monotonic_span >= -10 && span - monotonic_span <= 10) && prev.now >= 1704067200;
	if (dated) {
		let key = day_key(now), week = week_key(now), month = month_key(now), year = year_key(now);
		if (state.day_key != key) { state.day_key = key; state.today = empty_bytes(); }
		if (state.week_key != week) { state.week_key = week; state.week = empty_bytes(); }
		if (state.month_key != month) { state.month_key = month; state.month = empty_bytes(); }
		if (state.year_key != year) { state.year_key = year; state.year = empty_bytes(); }
		if (clock_ok) {
			if (day_key(prev.now) == key) add_bytes(state.today, delta, 1);
			else if (span <= 120) add_bytes(state.today, delta, (now - midnight(now)) * 1.0 / span);
			if (week_key(prev.now) == week) add_bytes(state.week, delta, 1);
			else if (span <= 120) add_bytes(state.week, delta, (now - week_start(now)) * 1.0 / span);
			if (month_key(prev.now) == month) add_bytes(state.month, delta, 1);
			else if (span <= 120) add_bytes(state.month, delta, (now - month_start(now)) * 1.0 / span);
			if (year_key(prev.now) == year) add_bytes(state.year, delta, 1);
			else if (span <= 120) add_bytes(state.year, delta, (now - year_start(now)) * 1.0 / span);
		}
		if (prev && (span < 0 || (compatible && !clock_ok) || (span > 120 && day_key(prev.now) != key))) state.coverage_start = now;
	}
	state.last = sample; state.sampled = now;
	push(state.history, { t: now * 1000, ipv4: sample.available.ipv4 ? { up: sample.rates.up4, down: sample.rates.down4 } : null, ipv6: sample.available.ipv6 ? { up: sample.rates.up6, down: sample.rates.down6 } : null });
	while (length(state.history) > 60) shift(state.history);
	return state;
}
export function checkpoint_due(state, now, uptime, boot) {
	if (!state.first || now < 1704067200 || !state.last) return false;
	if (!state.persisted_at) return true; // Initial baseline or one-time v1 compaction.
	// Use router uptime across wall-clock changes and service restarts.
	let current_uptime = valid_number(uptime) ? uptime : state.last.uptime;
	let current_boot = boot || state.last.boot;
	if (current_boot == state.persisted_boot && current_uptime >= state.persisted_uptime)
		return current_uptime - state.persisted_uptime >= 1800;
	// Across a router reboot use elapsed wall time, or one new-boot interval
	// if the wall clock moved back. A stop/restart never forces a flash write.
	return now >= state.persisted_at ? now - state.persisted_at >= 1800 : current_uptime >= 1800;
}
export function public_state(state, now) {
	let dated = now >= 1704067200, periods = [];
	if (dated && state.first) {
		push(periods, { key: 'today', label: '今天', bytes: state.day_key == day_key(now) ? state.today : empty_bytes() });
		if (now - state.coverage_start >= 7 * 86400 && state.coverage_start <= week_start(now))
			push(periods, { key: 'week', label: '本周', bytes: state.week_key == week_key(now) ? state.week : empty_bytes() });
		if (now - state.coverage_start >= 30 * 86400 && state.coverage_start <= month_start(now))
			push(periods, { key: 'month', label: '本月', bytes: state.month_key == month_key(now) ? state.month : empty_bytes() });
		if (now - state.coverage_start >= 365 * 86400 && state.coverage_start <= year_start(now))
			push(periods, { key: 'year', label: '本年', bytes: state.year_key == year_key(now) ? state.year : empty_bytes() });
	}
	let families = {};
	for (let family in [ '4', '6' ]) {
		let name = 'ipv' + family;
		families[name] = { available: state.last?.available[name] == true, up: state.last?.rates['up' + family], down: state.last?.rates['down' + family], total: state.totals['up' + family] + state.totals['down' + family] };
	}
	return { version: 3, ok: state.ok && now - state.sampled <= 20 && now >= state.sampled, sampled: state.sampled, first: state.first, source: state.last?.source, families, total: state.totals.up4 + state.totals.down4 + state.totals.up6 + state.totals.down6, history: state.history, periods, persisted_at: state.persisted_at };
}
