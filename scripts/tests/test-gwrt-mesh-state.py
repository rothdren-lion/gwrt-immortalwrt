#!/usr/bin/env python3
"""Exercise production mesh snapshot helpers with an isolated, real target UCI."""
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYSROOT = Path(os.environ.get("GWRT_TEST_SYSROOT", "/home/godsun/build/immortalwrt-mt7981/staging_dir/target-aarch64_cortex-a53_musl/root-mediatek"))
UCI = SYSROOT / "sbin/uci"
QEMU = shutil.which("qemu-aarch64")
if not QEMU or not UCI.exists():
    raise SystemExit("Set GWRT_TEST_SYSROOT to an aarch64 target root with sbin/uci; qemu-aarch64 is required")

APMODE = (ROOT / "package/gwrt-mesh-apmode/files/usr/libexec/gwrt-mesh-apmode").read_text()
BOARD = (ROOT / "target/linux/mediatek/filogic/base-files/etc/board.d/02_network").read_text()
SYSTEM = (ROOT / "package/base-files/files/lib/functions/system.sh").read_text()


def function(source, name):
    match = re.search(r"^" + re.escape(name) + r"\(\)\s*\{.*?^\}", source, re.M | re.S)
    if not match:
        raise AssertionError("missing production function " + name)
    return match.group(0)


HELPERS = "\n".join(function(APMODE, name) for name in (
    "state_quote", "save_option", "restore_option", "restore_wan_bridge_membership", "load_state", "save_state"))


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gwrt-mesh-state-")
        self.path = Path(self.tmp.name)
        for name in ("config", "override", "save", "bin"):
            (self.path / name).mkdir()
        self.env = dict(os.environ, PATH=str(self.path / "bin") + ":" + os.environ["PATH"])
        wrapper = "#!/bin/sh\nexec " + " ".join(shlex.quote(str(x)) for x in (
            QEMU, "-L", SYSROOT, UCI, "-c", self.path / "config", "-C", self.path / "override", "-t", self.path / "save")) + ' "$@"\n'
        (self.path / "bin/uci").write_text(wrapper)
        (self.path / "bin/uci").chmod(0o755)
        for cmd, text in {"ip": "echo 'inet 192.0.2.1/24'", "ps": "echo dropbear", "logger": ":"}.items():
            p = self.path / "bin" / cmd
            p.write_text("#!/bin/sh\n" + text + "\n")
            p.chmod(0o755)
        for name, text in {"network": """
config device 'br'
 option name 'br-lan'
 list ports 'lan1'
 list ports 'lan2'
config interface 'lan'
 option proto 'static'
 option ipaddr '192.168.3.4'
 option netmask '255.255.255.0'
 option gateway '192.168.3.1'
 list dns '192.168.3.1'
 list dns '2001:db8::53'
config interface 'wan'
 option device 'wan'
 option proto 'static'
 option ipaddr '198.51.100.2'
 option netmask '255.255.255.0'
 option gateway '198.51.100.1'
 list dns '1.1.1.1'
 list dns '8.8.8.8'
config interface 'wan6'
 option proto 'dhcpv6'
""", "dhcp": "config dhcp 'lan'\n option ignore '0'\n", "dropbear": "config dropbear\n option Interface 'lan'\n"}.items():
            (self.path / "config" / name).write_text(text)

    def shell(self, script):
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr + result.stdout)
        return result.stdout.strip()

    def get(self, key):
        return self.shell("uci -q get " + shlex.quote(key) + " || true")

    def restore(self, name, before="", state=""):
        # Network/service effects are stubbed; the production UCI operations run unchanged.
        script = HELPERS + "\n" + function(APMODE, name)
        script = script.replace("/etc/init.d/", str(self.path / "no-services") + "/")
        script += "\nSTATE=" + shlex.quote(str(self.path / "state")) + "\nAP_OFF=''\n"
        script += "brlan_dev_section(){ echo br; }; wan_dev_name(){ echo wan; }; hnat_off(){ :; }; hnat_on(){ :; }; fw_move_wwan(){ :; }; log(){ :; }\n"
        if state:
            (self.path / "state").write_text(state)
        else:
            script += "save_state\n"
        script += before + "\n" + name + "\n"
        return self.shell(script)


MUTATE = """
uci set network.lan.proto=dhcp
uci set network.wan.proto=none
uci set network.wan6.proto=none
for side in lan wan; do for opt in ipaddr netmask gateway dns; do uci -q delete network.$side.$opt; done; done
uci add_list network.br.ports=wan
uci commit network
"""


def test_roundtrip(name):
    f = Fixture()
    f.restore(name, MUTATE)
    expected = {
        "lan.proto": "static", "lan.ipaddr": "192.168.3.4", "lan.netmask": "255.255.255.0",
        "lan.gateway": "192.168.3.1", "lan.dns": "192.168.3.1 2001:db8::53",
        "wan.proto": "static", "wan.ipaddr": "198.51.100.2", "wan.netmask": "255.255.255.0",
        "wan.gateway": "198.51.100.1", "wan.dns": "1.1.1.1 8.8.8.8", "wan6.proto": "dhcpv6", "br.ports": "lan1 lan2",
    }
    for key, value in expected.items():
        assert f.get("network." + key) == value, (name, key, f.get("network." + key), value)
    exported = f.shell("uci export network")
    assert exported.count("list dns") == 4, exported
    print("PASS", name, "static LAN/WAN + IPv4/IPv6 DNS lists + original WAN not bridged")


for restore in ("restore_network_only", "restore_routermode"):
    test_roundtrip(restore)
    f = Fixture()
    f.shell("uci add_list network.br.ports=wan; uci commit network")
    f.restore(restore, "uci del_list network.br.ports=wan; uci commit network")
    assert f.get("network.br.ports") == "lan1 lan2 wan"
    print("PASS", restore, "preserves original WAN bridge member")
    f = Fixture()
    legacy = "lan_proto=static\nlan_ipaddr=192.168.3.8/24\nlan_netmask=255.255.255.0\nwan_proto=static\nwan6_proto=dhcpv6\nbrdev=br\nwandev=wan\nbridged_wandev=1\ndhcp_ignore=0\ndb_iface=lan\nsvc_enabled=''\n"
    f.restore(restore, "uci set network.lan.ipaddr=192.168.3.3/24; uci commit network", legacy)
    assert f.get("network.lan.ipaddr") == "192.168.3.8/24"
    assert f.get("network.wan.ipaddr") == "198.51.100.2"
    assert f.get("network.lan.gateway") == "192.168.3.1"
    assert f.get("network.br.ports") == "lan1 lan2 wan"
    print("PASS", restore, "legacy state restores known LAN fields and preserves unsaved valid WAN/LAN options")
    f = Fixture()
    f.shell("uci delete network.wan.dns; uci delete network.lan.gateway; uci commit network")
    f.restore(restore, "uci set network.wan.dns=9.9.9.9; uci set network.lan.gateway=192.168.9.9; uci commit network")
    assert f.get("network.wan.dns") == ""
    assert f.get("network.lan.gateway") == ""
    print("PASS", restore, "explicit original option absence is restored")

f = Fixture()
quoted = f.shell(HELPERS + "\nx=" + shlex.quote("literal ' quote $dollar `cmd` \\") + "\nq=$(state_quote \"$x\"); eval \"y=$q\"; [ \"$x\" = \"$y\" ] && echo ok")
assert quoted == "ok"
print("PASS state file safely quotes apostrophe, dollar, backtick and backslash")

mac_funcs = function(BOARD, "mediatek_setup_macs") + "\n" + function(SYSTEM, "macaddr_add")
for mac in ("28:AB:CD:12:34:56", "28:ab:cd:12:34:56", "", ":", "ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00"):
    script = mac_funcs + "\nMAC_INPUT=" + shlex.quote(mac) + "\n"
    script += 'mtd_get_mac_ascii(){ [ "$1" = Factory ] || return 2; printf "%s\\n" "$MAC_INPUT"; }; ucidef_set_interface_macaddr(){ printf "%s=%s\\n" "$1" "$2"; }; ucidef_set_label_macaddr(){ :; }; mediatek_setup_macs qihoo,360t7; :\n'
    out = f.shell(script)
    if mac.startswith("28:"):
        assert "wan=" in out and "lan=" in out, (mac, out)
    else:
        assert out == "", (mac, out)
print("PASS 360T7 Factory lookup and upper/lowercase valid MACs; empty/colon/multicast/zero MACs are not configured")

f = Fixture()
f.shell("uci set network.bad=device; uci set network.bad.macaddr=:; uci set network.good=device; uci set network.good.macaddr=28:ab:cd:12:34:56; uci commit network")
migration = (ROOT / "package/gwrt-device-defaults/files/94_gwrt-invalid-mac").read_text().replace(". /lib/functions.sh", 'board_name(){ echo "${TEST_BOARD:-qihoo,360t7}"; }')
f.shell("TEST_BOARD=other; " + migration)
assert f.get("network.bad.macaddr") == ":"
f.shell(migration)
assert f.get("network.bad.macaddr") == ""
assert f.get("network.good.macaddr") == "28:ab:cd:12:34:56"
f.shell(migration)
print("PASS invalid-MAC migration only removes ':' on 360T7, preserves valid override, and is idempotent")
print("All 11 production-state/MAC fixture groups passed")
