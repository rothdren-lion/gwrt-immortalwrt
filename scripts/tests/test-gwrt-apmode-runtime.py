#!/usr/bin/env python3
"""Check production FT repair order and retry suppression without real radios."""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "package/gwrt-mesh-apmode/files/usr/libexec/gwrt-mesh-apmode").read_text()


def function(name):
    match = re.search(r"^" + name + r"\(\)\s*\{.*?^\}", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError("missing production function " + name)
    return match.group(0)


for fail in (False, True):
    with tempfile.TemporaryDirectory(prefix="gwrt-ft-repair-") as tmp:
        path = Path(tmp)
        (path / "ifindex").write_text("12\n")
        (path / "packet").write_text("sk RefCnt Type Proto Iface R Rmem User Inode\n0 2 3 88b7 -1 0 0 101 6263\n0 2 3 890d 12 0 0 101 17759\n")
        for phy in ("phy0", "phy1"):
            (path / ("hostapd-" + phy + ".conf")).write_text("bridge=br-lan\nft_iface=br-lan\nmobility_domain=0001\n")
        code = "\n".join(function(n) for n in ("ft_bridge_socket_stale", "repair_ft_bridge_sockets"))
        for old, new in (("/proc/net/packet", "packet"), ("/sys/class/net/br-lan/ifindex", "ifindex"), ("/tmp/gwrt-ft-bridge-repair.sig", "sig"), ("/var/run/hostapd-", "hostapd-")):
            code = code.replace(old, str(path / new))
        code += r'''
log() { :; }
sleep() { :; }
uci() { printf '%s\n' wireless.radio0=wifi-device wireless.radio1=wifi-device; }
jsonfilter() { case "$*" in *radio0*) echo phy0-ap0 ;; *radio1*) echo phy1-ap0 ;; esac; }
ubus() {
 case "$*" in
  *status*) printf status ;;
  *) printf '%s\n' "$*" >> "$fixture/actions"
     if [ "$fail" = 0 ] && [ "$(wc -l < "$fixture/actions")" -eq 2 ]; then : > "$fixture/packet"; fi ;;
 esac
}
repair_ft_bridge_sockets
repair_ft_bridge_sockets
'''
        result = subprocess.run(["sh", "-c", code], env={"fixture": tmp, "fail": "1" if fail else "0", "PATH": "/usr/bin:/bin"}, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        actions = (path / "actions").read_text().splitlines()
        expected = [f'call network.wireless {op} {{"device":"radio{radio}"}}' for op in ("down", "up") for radio in (0, 1)]
        assert actions == expected, actions
print("PASS: FT all-down-before-up order and failed-socket retry suppression")
