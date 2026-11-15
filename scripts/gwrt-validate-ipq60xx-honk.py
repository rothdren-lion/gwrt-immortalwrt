#!/usr/bin/env python3
"""Check the shared Honk application selection and each IPQ60xx hardware matrix."""

import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEVICES = {
    "ss01": "jdcloud_re-ss-01",
    "cs02": "jdcloud_re-cs-02",
    "cs02-gwrt2": "jdcloud_re-cs-02-gwrt2",
    "cs07": "jdcloud_re-cs-07",
}
COMMON = {
    "honk", "luci-app-honk", "luci-lib-daeuniverse", "vmlinux-btf-builtin",
    "luci-app-easytier", "luci-i18n-easytier-zh-cn", "gwrt-tv-adblock",
    "luci-app-gwrt-tvadblock", "luci-app-iptv", "udpxy", "luci-app-udpxy",
    "vlmcsd", "luci-app-vlmcsd", "gwrt-agent", "gwrt-device-defaults",
    "gwrt-mesh-apmode", "gwrt-mesh-led", "luci-theme-gwrt", "sgdisk",
}
PROXY_EXACT = {
    "3proxy", "dae", "dae-geoip", "dae-geosite", "daed", "daed-geoip",
    "daed-geosite", "dns2socks", "dnscrypt-proxy", "dnscrypt-proxy2",
    "hysteria", "geoview", "ipt2socks", "gwrt-ssr-plus-luci",
    "luci-app-dae", "luci-app-daed", "luci-app-homeproxy", "luci-app-openclash",
    "luci-app-passwall", "luci-app-privoxy", "luci-app-ssr-plus", "luci-app-v2raya",
    "luci-i18n-daed-zh-cn", "luci-i18n-homeproxy-zh-cn", "luci-i18n-openclash-zh-cn",
    "luci-i18n-passwall-zh-cn", "luci-i18n-ssr-plus-zh-cn", "luci-i18n-v2raya-zh-cn",
    "microsocks", "naiveproxy", "ohybridproxy", "privoxy", "proxychains-ng",
    "shadowsocks-rust-sslocal", "shadowsocks-rust-ssmanager", "shadowsocks-rust-ssserver",
    "shadowsocks-rust-ssservice", "shadowsocks-rust-ssurl", "sing-box", "sing-box-tiny",
    "trojan", "tuic-client", "tuic-server", "v2ray-core", "v2raya", "v2ray-plugin",
    "v2dat", "xray-core", "xray-plugin",
}
WIRELESS = {
    "kmod-cfg80211", "kmod-mac80211", "kmod-ath", "kmod-ath11k",
    "kmod-ath11k-ahb", "kmod-ath11k-pci", "hostapd-common", "wpad-openssl",
    "wifi-scripts", "wireless-regdb", "iw", "iw-full", "iwinfo",
    "athena-led", "luci-app-athena-led", "luci-app-wifiroam",
    "luci-i18n-wifiroam-zh-cn", "ath11k-firmware-ipq6018-ddwrt",
    "ath11k-firmware-qcn9074-ddwrt",
}


def fail(message):
    raise SystemExit("FAIL: " + message)


def enabled_config(path):
    text = path.read_text()
    values = dict(re.findall(r"^CONFIG_([^=]+)=(.*)$", text, re.M))
    packages = {k[8:] for k, v in values.items()
                if k.startswith("PACKAGE_") and v in ("y", "m")}
    return text, values, packages


def proxy(name):
    if "_INCLUDE_" in name:
        return False
    return (name in PROXY_EXACT
            or name.startswith(("luci-app-passwall-", "luci-app-passwall_", "luci-i18n-passwall-",
                                "luci-app-openclash-", "luci-app-openclash_", "luci-i18n-openclash-",
                                "luci-app-ssr-plus-", "luci-app-ssr-plus_", "luci-i18n-ssr-plus-")))


def requirements(preset):
    required, forbidden = set(COMMON), set()
    if preset == "ss01":
        required |= {"ipq-wifi-jdcloud_re-ss-01", "ath11k-firmware-ipq6018-ddwrt",
                     "kmod-ath11k", "kmod-ath11k-ahb", "wpad-openssl",
                     "kmod-qca-nss-dp", "kmod-qca-ssdk"}
        forbidden |= {"ipq-wifi-jdcloud_re-cs-02", "kmod-ath11k-pci",
                      "ath11k-firmware-qcn9074-ddwrt", "athena-led", "luci-app-athena-led",
                      "kmod-qca-ppe", "kmod-qca-edma"}
    elif preset in ("cs02", "cs02-gwrt2"):
        required |= {"ipq-wifi-jdcloud_re-cs-02", "ath11k-firmware-ipq6018-ddwrt",
                     "ath11k-firmware-qcn9074-ddwrt", "kmod-ath11k", "kmod-ath11k-ahb",
                     "kmod-ath11k-pci", "wpad-openssl", "athena-led",
                     "luci-app-athena-led", "kmod-qca-ppe", "kmod-qca-edma"}
        forbidden |= {"ipq-wifi-jdcloud_re-ss-01", "ath11k-firmware-ipq6018",
                      "ath11k-firmware-qcn9074", "kmod-qca-nss-dp", "kmod-qca-ssdk"}
    else:
        required |= {"kmod-qca-ppe", "kmod-qca-edma"}
        forbidden |= WIRELESS | {"ipq-wifi-jdcloud_re-ss-01", "ipq-wifi-jdcloud_re-cs-02"}
    return required, forbidden


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("preset", choices=DEVICES)
parser.add_argument("config", type=Path)
parser.add_argument("--manifests", type=Path)
args = parser.parse_args()

subprocess.run(["sh", str(ROOT / "gwrt-check-target.sh"), str(args.config.resolve()), args.preset],
               cwd=ROOT, check=True)
text, values, packages = enabled_config(args.config)
device = DEVICES[args.preset]
image_definitions = (ROOT / "target/linux/qualcommax/image/ipq60xx.mk").read_text()
device_block = re.search(
    rf"^define Device/{re.escape(device)}\n(.*?)^endef",
    image_definitions,
    re.M | re.S,
)
if not device_block or not re.search(r"^\s*KERNEL_SIZE\s*:=\s*12288k\s*$", device_block.group(1), re.M):
    fail("selected device DTS image definition must use KERNEL_SIZE=12288k")
required, forbidden = requirements(args.preset)
missing, present_forbidden = required - packages, forbidden & packages
if missing:
    fail("config missing packages: " + ", ".join(sorted(missing)))
if present_forbidden:
    fail("hardware-incompatible packages in config: " + ", ".join(sorted(present_forbidden)))
bad_proxies = sorted(p for p in packages if proxy(p))
if bad_proxies:
    fail("proxy engines remain: " + ", ".join(bad_proxies))
if packages & {"easytier", "easytier-noweb"}:
    fail("EasyTier runtime must remain LuCI-only")
if values.get("EASYTIER_INCLUDE_WEBCONSOLE") == "y":
    fail("EasyTier Web Console must not be embedded")
if values.get("TARGET_qualcommax_ipq60xx_DEVICE_" + device) != "y":
    fail("wrong selected target: " + device)
if values.get("TARGET_PROFILE", "").strip('"') != "DEVICE_" + device:
    fail("wrong target profile")
if values.get("KERNEL_DEBUG_INFO_BTF") != "y" or values.get("KERNEL_CGROUP_BPF") != "y":
    fail("Honk requires kernel BTF and cgroup BPF")
if "CONFIG_PACKAGE_gwrt-tv-adblock=y" not in text.splitlines():
    fail("adblock must be embedded")
if "CONFIG_PACKAGE_honk=y" not in text.splitlines():
    fail("Honk must be embedded")
print(f"PASS {args.preset} config: Honk/Doona, EasyTier LuCI-only, adblock, IPTV/UDPXY/Vlmcsd")

if args.manifests:
    profiles_path = args.manifests / "profiles.json"
    profiles = json.loads(profiles_path.read_text()).get("profiles", {})
    if set(profiles) != {device}:
        fail("image profiles differ from requested device: " + repr(set(profiles)))
    manifest_paths = sorted(args.manifests.glob("*.manifest"))
    if not manifest_paths:
        fail("no generated package manifest")
    installed = {line.split()[0] for path in manifest_paths
                 for line in path.read_text().splitlines() if line.strip()}
    missing, present_forbidden = required - installed, forbidden & installed
    if missing:
        fail("manifest missing packages: " + ", ".join(sorted(missing)))
    if present_forbidden:
        fail("hardware-incompatible packages in manifest: " + ", ".join(sorted(present_forbidden)))
    bad_proxies = sorted(p for p in installed if proxy(p))
    if bad_proxies:
        fail("proxy engines in manifest: " + ", ".join(bad_proxies))
    if installed & {"easytier", "easytier-noweb"}:
        fail("EasyTier runtime package is in manifest")
    print(f"PASS {args.preset} manifest: {len(installed)} packages; device profile matches")
