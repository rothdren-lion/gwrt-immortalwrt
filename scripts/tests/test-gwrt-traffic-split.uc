import { new_state, update_state, public_state } from 'gwrt.traffic';

let fails = 0;
function check(cond, msg) {
	if (cond) printf('ok   %s\n', msg);
	else { printf('FAIL %s\n', msg); fails++; }
}

/* 复刻 traffic-daily.uc 的 sample_from_netdev()：/proc/net/dev 只有协议合并
   计数，Bandix 的 WAN v6 累计值被拆出去，剩余归 IPv4。 */
function sample(total_tx, total_rx, v6up, v6down, now, prev) {
	let up6 = v6up <= total_tx ? v6up : 0, down6 = v6down <= total_rx ? v6down : 0;
	let dt = prev ? now - prev.now : 0;
	let up = 0, down = 0, r_up6 = 0, r_down6 = 0;
	if (dt > 0) {
		up = total_tx - up6 >= prev.bytes.up4 ? (total_tx - up6 - prev.bytes.up4) / dt : 0;
		down = total_rx - down6 >= prev.bytes.down4 ? (total_rx - down6 - prev.bytes.down4) / dt : 0;
		if (prev.available.ipv6 && up6 >= prev.bytes.up6 && down6 >= prev.bytes.down6) {
			r_up6 = (up6 - prev.bytes.up6) / dt;
			r_down6 = (down6 - prev.bytes.down6) / dt;
		}
	}
	return { now, uptime: now, boot: 'b1', source: 'netdev:pon0.41',
		bytes: { up4: total_tx - up6, down4: total_rx - down6, up6, down6 },
		rates: { up4: up, down4: down, up6: r_up6, down6: r_down6 },
		available: { ipv4: true, ipv6: v6up > 0 || v6down > 0 } };
}

let T = 1795800000;

/* 双栈：Bandix 提供 WAN v6 累计值 */
let st = new_state();
let s1 = sample(10000, 20000, 1000, 3000, T, null);
st = update_state(st, s1, T);
let s2 = sample(12000, 26000, 1400, 3400, T + 5, s1);
st = update_state(st, s2, T + 5);
let p = public_state(st, T + 5);
check(p.families.ipv4.available == true, 'ipv4 family available');
check(p.families.ipv6.available == true, 'ipv6 family available when bandix sees wan v6');
check(p.history[length(p.history) - 1].ipv6 != null, 'history carries an ipv6 point');
check(int(p.families.ipv4.up + 0.5) == 320, 'ipv4 rate excludes v6 (' + int(p.families.ipv4.up + 0.5) + ' B/s)');
check(int(p.families.ipv6.up + 0.5) == 80, 'ipv6 rate from bandix (' + int(p.families.ipv6.up + 0.5) + ' B/s)');
check(p.total == 12000 + 26000, 'cumulative total keeps netdev volume (' + p.total + ')');
check(int(p.families.ipv4.down + 0.5) == 1120, 'ipv4 down excludes v6 (' + int(p.families.ipv4.down + 0.5) + ' B/s)');
check(int(p.families.ipv6.down + 0.5) == 80, 'ipv6 down from bandix (' + int(p.families.ipv6.down + 0.5) + ' B/s)');

/* 单栈：没有 Bandix WAN 数据，界面只显示一条合计 */
let st2 = new_state();
let u1 = sample(5000, 7000, 0, 0, T, null);
st2 = update_state(st2, u1, T);
let u2 = sample(6000, 9000, 0, 0, T + 5, u1);
st2 = update_state(st2, u2, T + 5);
let p2 = public_state(st2, T + 5);
check(p2.families.ipv6.available == false, 'ipv6 unavailable without bandix wan data');
check(p2.history[length(p2.history) - 1].ipv6 == null, 'history keeps ipv6 null');
check(int(p2.families.ipv4.up + 0.5) == 200, 'total flows into the single ipv4/合计 series (' + int(p2.families.ipv4.up + 0.5) + ' B/s)');
check(p2.total == 6000 + 9000, 'single-stack total complete (' + p2.total + ')');

printf('%s\n', fails ? ('FAILED ' + fails) : 'ALL PASS');
exit(fails ? 1 : 0);
