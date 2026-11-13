#!/usr/bin/env python3
"""Run the real Wi-Fi hotplug script with synthetic UCI and sysfs state."""
from pathlib import Path
import copy
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HOTPLUG = ROOT / "package/network/config/wifi-scripts/files/etc/hotplug.d/ieee80211/10-wifi-detect"
HELPER = ROOT / "target/linux/qualcommbe/ipq53xx/base-files/usr/libexec/gwrt-cs06-radio-config"
AHB = "platform/soc@0/c000000.wifi"
PCI = "platform/soc@0/18000000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0"
FIXTURE = {
    "radio0": {".type": "wifi-device", "path": AHB, "radio": "0", "band": "2g", "channel": "6"},
    "radio1": {".type": "wifi-device", "path": AHB, "radio": "1", "band": "5g", "phy": "phy0", "htmode": "EHT160"},
    "ap0": {".type": "wifi-iface", "device": "radio0", "ssid": "Synthetic 2G", "key": "fixture-only-2g"},
    "ap1": {".type": "wifi-iface", "device": "radio1", "ssid": "Synthetic 5G", "key": "fixture-only-5g"},
}

MOCK = r'''#!/usr/bin/env python3
from pathlib import Path
import json, os, sys
p=Path(os.environ["GWRT_TEST_STATE"])
s=json.loads(p.read_text())
args=[x for x in sys.argv[1:] if x!="-q"]
name=Path(sys.argv[0]).name
if name!="uci": raise SystemExit(0)
op=args[0]
if op=="show":
    for k,v in s.items(): print("wireless."+k+"="+v[".type"])
    raise SystemExit(0)
if op=="commit": raise SystemExit(0)
key=args[1]
if op=="set": key,value=key.split("=",1)
parts=key.split(".")
assert parts[0]=="wireless" and len(parts)==3
section,option=parts[1:]
if op=="get":
    if section not in s or option not in s[section]: raise SystemExit(1)
    print(s[section][option]); raise SystemExit(0)
if op=="set": s[section][option]=value
elif op=="delete": s[section].pop(option,None)
else: raise AssertionError(op)
p.write_text(json.dumps(s))
'''


def run_case(case, board="jdcloud,re-cs-06", pci=True, action="add", modified=False):
    with tempfile.TemporaryDirectory(prefix="gwrt-cs06-config-test-") as tmp:
        t = Path(tmp)
        state = copy.deepcopy(FIXTURE)
        if modified:
            state["radio1"]["path"] = "platform/custom-radio"
        (t / "wireless.json").write_text(json.dumps(state))
        (t / "board_name").write_text(board + "\n")
        (t / "board.json").write_text("{}\n")
        (t / "system.sh").write_text("board_name() { cat '" + str(t / "board_name") + "'; }\n")
        (t / "phys/phy0").mkdir(parents=True)
        devices = t / "sys/devices"
        (devices / AHB).mkdir(parents=True)
        (t / "phys/phy0/device").symlink_to(devices / AHB)
        if pci:
            (t / "phys/phy1").mkdir()
            (devices / PCI).mkdir(parents=True)
            (t / "phys/phy1/device").symlink_to(devices / PCI)
        for name in ("uci", "ubus", "wifi", "logger"):
            p = t / name
            p.write_text(MOCK)
            p.chmod(0o755)
        helper = t / "helper"
        if HELPER.exists():
            helper.write_text(HELPER.read_text().replace("/lib/functions/system.sh", str(t / "system.sh"))
                              .replace("/sys/class/ieee80211", str(t / "phys"))
                              .replace("/sys/devices/", str(devices) + "/"))
        else:
            helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        hotplug = HOTPLUG.read_text()
        for original, replacement in {
            "/tmp/sysinfo/board_name": t / "board_name", "/etc/board.json": t / "board.json",
            "/sbin/wifi": t / "wifi", "/usr/libexec/gwrt-cs06-radio-config": helper,
            "/var/lock": t / "lock",
        }.items():
            hotplug = hotplug.replace(original, str(replacement))
        env = os.environ | {"PATH": str(t) + os.pathsep + os.environ["PATH"], "ACTION": action,
                            "GWRT_TEST_STATE": str(t / "wireless.json")}
        completed = subprocess.run(["sh", "-c", hotplug], env=env)
        assert completed.returncode == (0 if action == "add" else 1), case
        result = json.loads((t / "wireless.json").read_text())
        expected = copy.deepcopy(state)
        if board == "jdcloud,re-cs-06" and action == "add":
            expected["radio0"].pop("radio")
            if pci and not modified:
                expected["radio1"]["path"] = PCI
                expected["radio1"].pop("radio")
                expected["radio1"].pop("phy")
        assert result == expected, case + ": radio bindings were not migrated as expected"
        # Run it twice: normal recovery/add events must not change settings again.
        completed = subprocess.run(["sh", "-c", hotplug], env=env)
        assert completed.returncode == (0 if action == "add" else 1), case
        assert json.loads((t / "wireless.json").read_text()) == result, case + ": not idempotent"
        if not pci and board == "jdcloud,re-cs-06":
            (t / "phys/phy1").mkdir()
            (devices / PCI).mkdir(parents=True)
            (t / "phys/phy1/device").symlink_to(devices / PCI)
            subprocess.run(["sh", "-c", hotplug], env=env, check=True)
            expected["radio1"]["path"] = PCI
            expected["radio1"].pop("radio")
            expected["radio1"].pop("phy")
            assert json.loads((t / "wireless.json").read_text()) == expected, case + ": late PCI binding"
        print("PASS CS-06 radio configuration:", case)


if __name__ == "__main__":
    run_case("retained-config")
    run_case("AHB-before-PCI", pci=False)
    run_case("other-board", board="gl.inet,gl-be6500")
    run_case("remove-event", action="remove")
    run_case("custom-binding", modified=True)
