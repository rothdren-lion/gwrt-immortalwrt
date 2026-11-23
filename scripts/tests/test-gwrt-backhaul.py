#!/usr/bin/env python3
"""Drive the actual mesh controller against real UCI and simulated link events."""
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "package/gwrt-mesh-apmode/files"
SYSROOT = Path(os.environ["GWRT_TEST_SYSROOT"]).resolve()
QEMU = shutil.which("qemu-aarch64")


CONFIG = {
    "network": """config device
 option name 'br-lan'
 list ports 'lan1'
config interface 'lan'
 option device 'br-lan'
 option proto 'static'
 list ipaddr '192.168.3.8/24'
 list dns '192.168.3.1'
 list dns '2001:db8::53'
config interface 'wan'
 option device 'wan'
 option proto 'dhcp'
 option metric '13'
config interface 'wan6'
 option device 'wan'
 option proto 'dhcpv6'
""",
    "dhcp": """config dhcp 'lan'
 option interface 'lan'
 option ra 'server'
 option dhcpv6 'server'
""",
    "wireless": """config wifi-device 'radio0'
 option band '2g'
 option channel '11'
config wifi-device 'radio1'
 option band '5g'
 option channel '149'
config wifi-iface 'localap'
 option device 'radio0'
 option mode 'ap'
 option ssid 'My Router WiFi'
 option encryption 'psk2'
 option key 'router-fixture'
config wifi-iface 'old_guest'
 option device 'radio0'
 option mode 'ap'
 option wifiroam_guest '1'
 option disabled '0'
""",
    "firewall": """config zone
 option name 'lan'
 list network 'lan'
config zone
 option name 'wan'
 list network 'wan'
""",
    "dropbear": "config dropbear 'main'\n option DirectInterface 'lan'\n",
    "gwrt": "config mesh_apmode 'mesh_apmode'\n option enabled '1'\n",
    "wifiroam": """config globals 'core'
 option enabled '1'
 option role 'sap'
 option cap_ip '198.51.100.1'
 option token 'fixture-token'
config backhaul 'backhaul'
 option enabled '1'
 option ssid 'mesh-fixture'
 option key 'fixture-password'
 option channel2g '6'
 option channel '44'
""",
}

SH = r'''
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
get() { uci -q get "$1" 2>/dev/null; }
sleep() { :; }
log() { printf '%s\n' "$*" >> "$ROOT/events"; }
uptime_s() { echo "$clock"; }
ping() {
	printf 'probe %s\n' "$*" >>"$ROOT/events"
	[ -f "$ROOT/cap-reachable" ]
}
relay_status() {
	[ "$1" != pid ] && [ -f "$ROOT/relayd.running" ] && echo true
}
service() {
	local name="$1" op="$2"
	case "$op" in
		running) [ -f "$ROOT/$name.running" ] ;;
		start|restart)
			case "$name" in
				dnsmasq) [ ! -e "$SYS_NET/br-lan/brif/wan" ] || fail 'DHCP started on bridged WAN' ;;
			esac
			: >"$ROOT/$name.running"
			echo "$name $op" >>"$ROOT/events" ;;
		stop) rm -f "$ROOT/$name.running"; echo "$name $op" >>"$ROOT/events" ;;
		reload) echo "$name $op" >>"$ROOT/events" ;;
	esac
}
network_reload() {
	[ ! -f "$ROOT/reload_fail" ] || return 1
	if [ "$(get wireless.wifiroam_bh.disabled)" = 1 ] || [ -z "$(get wireless.wifiroam_bh.device)" ]; then
		[ -f "$ROOT/stuck_sta" ] || echo 0 >"$SYS_NET/sta0/carrier"
	fi
	if bridge_port_configured; then
		[ ! -f "$ROOT/relayd.running" ] || fail 'bridge opened with relay active'
		expect "$(cat "$SYS_NET/sta0/carrier")" 0 'STA down before adding WAN'
		[ ! -f "$ROOT/dnsmasq.running" ] || fail 'bridge opened with local DHCP active'
		: >"$SYS_NET/br-lan/brif/wan"
	else
		[ -f "$ROOT/stuck_bridge" ] || rm -f "$SYS_NET/br-lan/brif/wan"
		if [ -e "$SYS_NET/br-lan/brif/wan" ]; then
			[ "$(get wireless.wifiroam_bh.disabled)" != 0 ] || fail 'STA enabled before WAN detach'
		fi
	fi
	echo "reload $(get network.lan.proto) $(get wireless.wifiroam_bh.disabled)" >>"$ROOT/events"
}
ubus() {
	[ "$1" = -t ] && shift 2
	case "$2:$3" in
		network.interface.*:status) cat "$ROOT/${2##*.}.status" 2>/dev/null ;;
		network.wireless:status)
			printf '{"%s":{"interfaces":[{"section":"wifiroam_bh","ifname":"sta0"}]}}\n' \
				"${active_radio:-$(get wireless.wifiroam_bh.device)}" ;;
		network.interface.*:down) echo "down $2" >>"$ROOT/events" ;;
		service:set)
			[ ! -f "$ROOT/relay_fail" ] || return 1
			: >"$ROOT/relayd.running"; echo "start relay $4" >>"$ROOT/events" ;;
		service:delete) rm -f "$ROOT/relayd.running"; echo 'stop relay' >>"$ROOT/events" ;;
	esac
}
clock=100
tick() {
	clock="$1"; shift
	step || [ "$phase" = recover ] || fail 'tick returned an unexpected error'
	expect "$phase" "$1" "phase at $clock"
	[ -z "$2" ] || expect "$phase_ip" "$2" 'published management IP'
}
lease() {
	printf '{"up":true,"proto":"%s","l3_device":"%s","ipv4-address":[{"address":"%s","mask":%s}]}' \
		"${5:-dhcp}" "$2" "$3" "${4:-24}" >"$ROOT/$1.status"
}
cap() {
	printf '%s %s %s %s\n' "$2" "${4:-198.51.100.1}" "${5:-$pair_hash}" "$3" >"$RUNDIR/cap.$1"
}
cable_event() {
	echo "$1" >"$SYS_NET/wan/carrier"
	echo "$2" >"$SYS_NET/wan/carrier_down_count"
}
connect_sta() {
	echo 1 >"$SYS_NET/sta0/carrier"
	lease gwrt_mesh sta0 198.51.100.42
	cap 7 "$1" 0
}
connect_wired() {
	cable_event 1 0
	lease wan wan 198.51.100.23
	tick 100 search
	cap 4 101 0
	tick 102 wired_pending
	cap 2 103 0
	lease lan br-lan 198.51.100.32
	tick 104 wired 198.51.100.32
}
prepare || fail prepare
'''


CASES = {
    "first pairing avoids a shared factory LAN subnet without saving changes": r'''
uci set wifiroam.core.role=unconfigured
cable_event 1 0
lease wan wan 192.168.3.20
lease lan br-lan 192.168.3.8 24 static
tick 100 idle
expect "$(get network.lan.ipaddr)" 192.168.4.1 'temporary conflict avoidance'
cable_event 0 1
rm "$ROOT/wan.status"
tick 102 idle
expect "$(get network.lan.ipaddr)" 192.168.3.8/24 'original address after removing conflicting uplink'
''',
    "unrelated cable stays isolated; verified cable takes over; unplug uses Wi-Fi": r'''
tick 100 search
expect "$(get wireless.wifiroam_bh.network)" gwrt_mesh 'station interface'
expect "$(get wireless.radio0.channel)" 6 'CAP channel'
expect "$(get wireless.old_guest.disabled)" 1 'local guest cannot advertise without DHCP'
connect_sta 101
tick 102 wireless 198.51.100.42
expect "$(get dropbear.main.Interface)" gwrt_mesh 'SSH listens on the STA address'
expect "$(get dropbear.main.DirectInterface)" '' 'SSH accepts LAN clients too'
cable_event 1 4
lease wan wan 198.51.100.23
cap 4 103 4 198.51.100.99
tick 104 wireless
cap 4 105 4 198.51.100.1 wrong
tick 106 wireless
cap 4 82 4
tick 108 wireless
cap 4 109 3
tick 110 wireless
cap 2 111 4
tick 112 wireless
[ ! -e "$SYS_NET/br-lan/brif/wan" ] || fail 'unverified wire bridged'
cap 7 113 0
cap 4 113 4
lease wan wan 203.0.113.23
tick 114 wireless
lease wan wan 198.51.100.23 24 static
tick 116 wireless
lease wan wan 198.51.100.23
tick 118 wired_pending
[ -e "$SYS_NET/br-lan/brif/wan" ] || fail 'verified wire not bridged'
expect "$(get wireless.radio0.channel)" 11 'channel restored after STA stops'
expect "$(get dhcp.lan.ra)" disabled 'local IPv6 RA off while bridged'
cap 2 119 0
lease lan br-lan 198.51.100.32
tick 120 wired 198.51.100.32
expect "$(get dropbear.main.DirectInterface)" lan 'SSH back on LAN'
cable_event 0 5
tick 122 search
[ ! -e "$SYS_NET/br-lan/brif/wan" ] || fail 'dead WAN remained bridged'
connect_sta 123
tick 124 wireless 198.51.100.42
expect "$(awk '{print $4, $5}' "$RUNDIR/phase")" 'cable_lost 2g' 'published reason and actual band'
''',
    "established wire survives missing broadcasts and isolated probe failures": r'''
connect_wired
touch "$ROOT/cap-reachable"
tick 120 wired
grep -q '^probe .* -I br-lan .*198\.51\.100\.1$' "$ROOT/events" || fail 'probe not bound to the established bridge'
rm "$ROOT/cap-reachable"
tick 124 wired
tick 128 wired
touch "$ROOT/cap-reachable"
tick 132 wired
rm "$ROOT/cap-reachable"
tick 136 wired
tick 140 wired
tick 144 search
expect "$(awk '{print $4}' "$RUNDIR/phase")" wired_unreachable 'lost wired reachability'
''',
    "a fresh beacon restores the wired failure budget": r'''
connect_wired
tick 120 wired
tick 124 wired
cap 2 125 0
tick 126 wired
tick 142 wired
tick 146 wired
tick 150 search
''',
    "pending handoff needs a fresh bridged beacon even when the CAP answers": r'''
tick 100 search
connect_sta 101
tick 102 wireless
cable_event 1 0
lease wan wan 198.51.100.23
touch "$ROOT/cap-reachable"
tick 104 wireless
cap 4 105 0
tick 106 wired_pending
lease lan br-lan 198.51.100.32
tick 108 wired_pending
tick 131 search
if grep -q '^probe ' "$ROOT/events"; then fail 'probe used to admit a new wire'; fi
''',
    "a replug cannot reuse the previous wired session": r'''
connect_wired
touch "$ROOT/cap-reachable"
cable_event 1 1
tick 120 search
if grep -q '^probe ' "$ROOT/events"; then fail 'probe used on a replugged cable'; fi
[ ! -e "$SYS_NET/br-lan/brif/wan" ] || fail 'replugged WAN remained bridged'
''',
    "a wire without a current on-link lease exits immediately": r'''
connect_wired
touch "$ROOT/cap-reachable"
lease lan br-lan 203.0.113.32
tick 120 search
if grep -q '^probe ' "$ROOT/events"; then fail 'probe used without a usable lease'; fi
''',
    "a wire removed from the bridge exits immediately": r'''
connect_wired
touch "$ROOT/cap-reachable"
rm "$SYS_NET/br-lan/brif/wan"
tick 120 search
if grep -q '^probe ' "$ROOT/events"; then fail 'probe used without bridge membership'; fi
''',
    "a validated 5 GHz association is tried first on reconnection": r'''
tick 100 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'initial configured default'
tick 130 search
expect "$(get wireless.wifiroam_bh.device)" radio1 'second frequency'
connect_sta 131
tick 132 wireless
expect "$(awk '{print $5}' "$RUNDIR/phase")" 5g 'actual successful frequency'
echo 0 >"$SYS_NET/sta0/carrier"
tick 134 wireless
tick 140 search
expect "$(get wireless.wifiroam_bh.device)" radio1 'last successful frequency first'
tick 170 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'retry on the other band'
''',
    "remembered frequency is scoped to the pair and ignores disabled radios": r'''
uci set wifiroam.backhaul.band=5g
tick 100 search
connect_sta 101
tick 102 wireless
uci revert wifiroam.backhaul.band
uci set wireless.radio1.disabled=1
echo 0 >"$SYS_NET/sta0/carrier"
tick 104 wireless
tick 110 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'disabled radio skipped'
uci revert wireless.radio1.disabled
uci set wifiroam.core.token=new-pair
tick 112 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'another pair uses its configured default'
''',
    "a failed wireless handoff does not set the preferred band": r'''
tick 100 search
tick 130 search
connect_sta 131
touch "$ROOT/relay_fail"
tick 132 search
connect_sta 219
tick 220 router
rm "$ROOT/relay_fail"
tick 280 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'failed 5 GHz handoff is not remembered'
''',
    "frequency memory follows the active STA rather than the requested radio": r'''
tick 100 search
active_radio=radio1
connect_sta 101
tick 102 wireless
expect "$(awk '{print $5}' "$RUNDIR/phase")" 5g 'actual active radio'
echo 0 >"$SYS_NET/sta0/carrier"
tick 104 wireless
tick 110 search
expect "$(get wireless.wifiroam_bh.device)" radio1 'reconnect on the actual previous radio'
''',
    "a short search window still tries the other configured band": r'''
uci set gwrt.mesh_apmode.search_seconds=15
tick 100 search
expect "$(get wireless.wifiroam_bh.device)" radio0 'configured band first'
tick 108 search
expect "$(get wireless.wifiroam_bh.device)" radio1 'alternate band before the search deadline'
connect_sta 109
tick 110 wireless
''',
    "default windows, short STA outage, router profile and pair stay intact": r'''
tick 100 search
connect_sta 101
tick 102 wireless
uci set wireless.localap.ssid='CAP SSID'
uci set wireless.localap.key='cap-fixture-key'
uci set wireless.localap.ieee80211r=1
uci set network.wan.hostname=retained
echo 0 >"$SYS_NET/sta0/carrier"
tick 104 wireless
connect_sta 105
tick 106 wireless
echo 0 >"$SYS_NET/sta0/carrier"
tick 108 wireless
tick 114 search
tick 233 search
tick 234 router
expect "$(get network.lan.proto)" static 'router LAN protocol'
expect "$(get network.lan.ipaddr)" 192.168.3.8/24 'custom router address'
expect "$(get network.lan.dns)" '192.168.3.1 2001:db8::53' 'list restored'
expect "$(get network.wan.hostname)" retained 'unrelated pending change survives'
expect "$(get wireless.localap.ssid)" 'My Router WiFi' 'original SSID'
expect "$(get wireless.localap.key)" 'router-fixture' 'original password'
expect "$(get wireless.localap.ieee80211r)" '' 'no CAP FT state leaks'
expect "$(get wireless.old_guest.disabled)" 0 'original guest state'
expect "$(get dhcp.lan.ra)" server 'local RA restored'
expect "$(get wifiroam.core.role)" sap 'still paired'
expect "$(get wifiroam.core.token)" fixture-token 'same pair token'
[ -f "$ROOT/dnsmasq.running" ] || fail 'local DHCP is not restored'
tick 293 router
tick 294 search
connect_sta 295
tick 296 wireless
''',
    "confirmed link without a bridged lease is rolled back; edited waits apply": r'''
uci set gwrt.mesh_apmode.search_seconds=40
uci set gwrt.mesh_apmode.router_seconds=15
cable_event 1 0
lease wan wan 198.51.100.23
tick 100 search
cap 4 101 0
tick 102 wired_pending
cap 2 125 0
lease lan br-lan 203.0.113.23
tick 127 search
tick 139 search
tick 140 router
tick 154 router
tick 155 search
''',
    "wired-only device and controller restart restore the original config": r'''
rm "$ROOT/etc/config/wireless"
cable_event 1 1
lease wan wan 198.51.100.23
tick 100 search
cap 4 101 1
tick 102 wired_pending
lease lan br-lan 198.51.100.32
cap 2 103 0
tick 104 wired
prepare || fail restart
expect "$phase" idle 'restart cleans old runtime state'
expect "$(get network.lan.proto)" static 'router profile after restart'
expect "$(get network.gwrt_mesh)" '' 'no STA on a wired-only device'
tick 106 search
cap 4 107 1
tick 108 wired_pending
cap 2 109 0
tick 110 wired
uci set wifiroam.core.role=unconfigured
tick 112 idle
expect "$(get network.lan.proto)" static 'router profile after unpair'
''',
    "failed handoff cannot leave a bridge and a live STA or enable DHCP too soon": r'''
tick 100 search
connect_sta 101
tick 102 wireless
cable_event 1 0
lease wan wan 198.51.100.23
cap 4 103 0
touch "$ROOT/stuck_sta"
tick 104 search
[ ! -e "$SYS_NET/br-lan/brif/wan" ] || fail 'bridge after stuck STA'
rm "$ROOT/stuck_sta"
echo 0 >"$SYS_NET/sta0/carrier"
cap 4 163 0
tick 164 wired_pending
cap 2 165 0
lease lan br-lan 198.51.100.31
tick 166 wired
touch "$ROOT/stuck_bridge"
cable_event 0 1
tick 168 recover
[ ! -f "$ROOT/dnsmasq.running" ] || fail 'local DHCP leaked while restoring'
[ ! -f "$ROOT/relayd.running" ] || fail 'relay started before WAN detached'
expect "$(cat "$SYS_NET/sta0/carrier")" 0 'STA stays down while WAN is still bridged'
uci set gwrt.mesh_apmode.enabled=0
rm "$ROOT/stuck_bridge"
tick 170 idle
[ -f "$ROOT/dnsmasq.running" ] || fail 'DHCP did not resume after cleanup'
''',
}


def fixture(directory):
    for f in FILES.rglob("*.sh"):
        copy_fixture(f, directory)
    copy_fixture(FILES / "usr/libexec/gwrt-mesh-apmode", directory)
    for pkg, body in CONFIG.items():
        write(directory / "etc/config" / pkg, body)
    for p in ("bin", "override", "delta", "sys/class/net/br-lan/brif"):
        (directory / p).mkdir(parents=True, exist_ok=True)
    for dev, idx in (("br-lan", 2), ("wan", 4), ("sta0", 7)):
        for field, value in (("ifindex", idx), ("carrier", 0), ("carrier_down_count", 0)):
            write(directory / "sys/class/net" / dev / field, f"{value}\n")
    for s in ("wifiroam", "dnsmasq", "odhcpd", "firewall"):
        write(directory / "etc/init.d" / s, "#!/bin/sh\nexit 0\n", executable=True)
    for s in ("dnsmasq", "odhcpd"):
        (directory / (s + ".running")).touch()
    for s in ("sbin/wifi", "usr/sbin/relayd"):
        write(directory / s, "#!/bin/sh\n", executable=True)
    for cmd, path in (("uci", "sbin/uci"), ("jsonfilter", "usr/bin/jsonfilter")):
        args = [QEMU, "-L", str(SYSROOT), str(SYSROOT / path)]
        if cmd == "uci":
            args += ["-c", str(directory / "etc/config"), "-C", str(directory / "override"),
                     "-t", str(directory / "delta")]
        write(directory / "bin" / cmd, "#!/bin/sh\nexec " + shlex.join(args) + ' "$@"\n', executable=True)


def write(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    if executable:
        path.chmod(0o755)


def copy_fixture(source, directory):
    # Prefix only target filesystem paths; all configuration writes stay in the fixture.
    data = re.sub(r'(?<![\w])/(etc|sys|var|sbin|usr|proc|tmp)(?=/)',
                  lambda m: str(directory / m.group(1)), source.read_text())
    write(directory / source.relative_to(FILES), data)


def check(label, scenario):
    with tempfile.TemporaryDirectory(prefix="gwrt-backhaul-") as tmp:
        d = Path(tmp)
        fixture(d)
        entry = (d / "usr/libexec/gwrt-mesh-apmode").read_text().split('\ncase "$1" in\n', 1)[0]
        env = dict(os.environ, PATH=str(d / "bin") + ":/usr/bin:/bin", ROOT=str(d))
        result = subprocess.run(["busybox", "ash"], input=entry + "\n" + SH + scenario,
                                env=env, text=True, capture_output=True, timeout=90)
        assert result.returncode == 0, f"{label}: {result.stderr}{result.stdout}\n{(d / 'events').read_text()}"
        for pkg, body in CONFIG.items():
            file = d / "etc/config" / pkg
            if file.exists():
                assert file.read_text() == body, f"unexpected persistent write to {pkg}"
        print("PASS", label, flush=True)


if __name__ == "__main__":
    if not QEMU or not (SYSROOT / "sbin/uci").is_file():
        raise SystemExit("Provide qemu-aarch64 and GWRT_TEST_SYSROOT with target UCI/jsonfilter")
    failures = []
    for label, scenario in CASES.items():
        try:
            check(label, scenario)
        except AssertionError as err:
            print(err, flush=True)
            failures.append(label)
    if failures:
        raise SystemExit(f"{len(failures)} of {len(CASES)} scenarios failed")
