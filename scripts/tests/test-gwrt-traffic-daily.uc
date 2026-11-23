import { select_sample, new_state, update_state, checkpoint_due, public_state, day_key } from 'gwrt.traffic';
let checks = 0;
function check(ok, message) { if (!ok) die('FAIL: ' + message + '\n'); checks++; }
const t = timegm({ year: 2026, mon: 11, mday: 17, hour: 12 });
function sample(n, now, uptime, boot, source) {
	return { now, uptime, boot: boot || 'a', source: source || 'bandix:wan', bytes: { up4: n, down4: n * 2, up6: n * 3, down6: n * 4 }, rates: { up4: 1, down4: 2, up6: 3, down6: 4 }, available: { ipv4: true, ipv6: true } };
}
let snapshot = { ok: true, data: { interfaces: [
	{ ifname: 'br-lan', zone: 'lan', cumulative: { up_v4_bytes: 999999, down_v4_bytes: 999999, up_v6_bytes: 999999, down_v6_bytes: 999999 } },
	{ ifname: 'wan', zone: 'unknown', cumulative: { up_v4_bytes: 10, down_v4_bytes: 20, up_v6_bytes: 30, down_v6_bytes: 40, up_v4_bps: 88888888 }, metrics: { up_v4_bps: 800, down_v4_bps: 1600, up_v6_bps: 2400, down_v6_bps: 3200 } }
] } };
let picked = select_sample(snapshot, { interface: [ { interface: 'wan', l3_device: 'pppoe-wan', device: 'wan', up: true } ] }, t, 100, 'a');
check(picked.source == 'bandix:wan', 'PPPoE physical WAN with unknown zone');
check(picked.bytes.up4 == 10 && picked.bytes.down6 == 40, 'WAN only, do not duplicate LAN');
check(picked.rates.up4 == 100 && picked.rates.down6 == 400, 'metrics bps converted to bytes/s');
check(select_sample(null, {}, t, 100, 'a') == null, 'failed snapshot unavailable');
check(select_sample(snapshot, {}, t, 100, 'a') == null, 'unknown-zone entry needs netifd WAN match');
delete snapshot.data.interfaces[1].cumulative.up_v6_bytes;
picked = select_sample(snapshot, { interface: [ { interface: 'wan', device: 'wan' } ] }, t, 100, 'a');
check(picked.available.ipv4 && !picked.available.ipv6, 'missing family stays unavailable');

let s = new_state();
update_state(s, sample(100, t, 100), t);
check(s.totals.up4 == 100 && s.days[day_key(t)].up4 == 0, 'old totals do not fabricate today');
check(checkpoint_due(s, t), 'first valid baseline is persisted');
s.persisted_day = day_key(t);
update_state(s, sample(150, t + 5, 105), t + 5);
check(s.days[day_key(t)].up4 == 50 && s.totals.up4 == 150, 'daily delta');
update_state(s, sample(150, t + 10, 110), t + 10);
check(s.days[day_key(t)].up4 == 50, 'same counters do not count twice');
check(!checkpoint_due(s, t + 10), 'no repeated same-day flash checkpoint');
let before = sprintf('%J', s.totals);
update_state(s, null, t + 15);
check(!s.ok && sprintf('%J', s.totals) == before, 'probe failure keeps totals');
check(length(s.history) == 3, 'probe failure does not append fake zeros');
check(public_state(s, t + 100).ok == false, 'stale sampling is not live');
update_state(s, sample(5, t + 20, 120), t + 20);
check(s.totals.up4 == 150, 'counter reset establishes baseline');
update_state(s, sample(15, t + 25, 125), t + 25);
check(s.totals.up4 == 160, 'counter reset continues incrementally');
update_state(s, sample(900, t + 30, 130, 'a', 'bandix:wan2'), t + 30);
check(s.totals.up4 == 160, 'source switch does not double totals');
update_state(s, sample(1, t + 35, 1, 'b', 'bandix:wan2'), t + 35);
check(s.totals.up4 == 160, 'reboot keeps the saved aggregate');
update_state(s, sample(6, t + 40, 6, 'b', 'bandix:wan2'), t + 40);
check(s.totals.up4 == 165, 'reboot new counters resume');

let boundary = timegm({ year: 2026, mon: 11, mday: 18, hour: 0 });
s = new_state();
update_state(s, sample(100, boundary - 5, 100), boundary - 5);
s.persisted_day = day_key(boundary - 5);
update_state(s, sample(200, boundary + 5, 110), boundary + 5);
check(s.days['2026-11-17'].up4 == 50 && s.days['2026-11-18'].up4 == 50, 'midnight delta belongs to both dates');
check(checkpoint_due(s, boundary + 5), 'new date checkpoints');
s.persisted_day = day_key(boundary + 5);
check(!checkpoint_due(s, boundary + 6), 'new date is overwritten only once');
let restored = json(sprintf('%J', s));
update_state(restored, sample(210, boundary + 10, 115), boundary + 10);
check(restored.days['2026-11-18'].up4 == 60, 'checkpoint and previous baseline restore together');
update_state(restored, sample(220, boundary + 3 * 86400, 110 + 3 * 86400 - 5), boundary + 3 * 86400);
check(restored.days['2026-11-21'].up4 == 0, 'unobserved multi-day gap is not all assigned to today');

s = new_state(); update_state(s, sample(100, t, 100), t);
check(length(public_state(s, t).periods) == 1, 'short history shows today only');
s.first = t - 370 * 86400; s.coverage_start = s.first;
check(length(public_state(s, t).periods) == 4, 'old enough history shows week/month/year');
s.coverage_start = t - 10 * 86400;
let p = public_state(s, t).periods;
check(length(p) == 2 && p[1].key == 'week', 'month/year remain hidden without history');
let state_text = sprintf('%J', s);
public_state(s, t); public_state(s, t);
check(sprintf('%J', s) == state_text, 'read-only projection does not mutate persisted state');
let early = new_state();
update_state(early, sample(10, 1000, 10), 1000);
check(!early.first && !checkpoint_due(early, 1000), 'unset clock does not create dates or flash snapshots');
update_state(early, sample(20, t, 20), t);
check(early.first == t && early.days[day_key(t)].up4 == 0, 'NTP jump starts a clean dated baseline');
printf('PASS traffic accounting: %d checks\n', checks);
