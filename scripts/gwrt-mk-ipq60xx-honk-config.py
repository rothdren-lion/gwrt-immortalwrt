#!/usr/bin/env python3
"""Derive four IPQ60xx board configs from the SS-01 Honk app selection."""

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DEVICES = {
    "ss01": "jdcloud_re-ss-01",
    "cs02": "jdcloud_re-cs-02",
    "cs02-gwrt2": "jdcloud_re-cs-02-gwrt2",
    "cs07": "jdcloud_re-cs-07",
}
PROXY_EXACT = {
    "3proxy", "dae", "dae-geoip", "dae-geosite", "daed", "daed-geoip",
    "daed-geosite", "dns2socks", "dnscrypt-proxy", "dnscrypt-proxy2",
    "hysteria", "geoview", "ipt2socks", "gwrt-ssr-plus-luci",
    "luci-app-dae", "luci-app-daed", "luci-app-homeproxy",
    "luci-app-openclash", "luci-app-passwall", "luci-app-privoxy",
    "luci-app-ssr-plus", "luci-app-v2raya", "luci-i18n-daed-zh-cn",
    "luci-i18n-homeproxy-zh-cn", "luci-i18n-openclash-zh-cn",
    "luci-i18n-passwall-zh-cn", "luci-i18n-ssr-plus-zh-cn",
    "luci-i18n-v2raya-zh-cn", "microsocks", "naiveproxy", "ohybridproxy",
    "privoxy", "proxychains-ng", "shadowsocks-rust-sslocal",
    "shadowsocks-rust-ssmanager", "shadowsocks-rust-ssserver",
    "shadowsocks-rust-ssservice", "shadowsocks-rust-ssurl", "sing-box",
    "sing-box-tiny", "trojan", "tuic-client", "tuic-server", "v2ray-core",
    "v2raya", "v2ray-plugin", "v2dat", "xray-core", "xray-plugin",
}
WIRELESS_EXACT = {
    "kmod-cfg80211", "kmod-mac80211", "kmod-ath", "kmod-ath11k",
    "kmod-ath11k-ahb", "kmod-ath11k-pci", "hostapd-common", "wpad-openssl",
    "wifi-scripts", "wireless-regdb", "iw", "iw-full", "iwinfo",
    "athena-led", "luci-app-athena-led", "luci-app-wifiroam",
    "luci-i18n-wifiroam-zh-cn",
}


def set_value(source, name, value):
    line = f"# CONFIG_{name} is not set" if value is None else f"CONFIG_{name}={value}"
    pattern = re.compile(
        rf"^(?:CONFIG_{re.escape(name)}=.*|# CONFIG_{re.escape(name)} is not set)$",
        re.M,
    )
    source, count = pattern.subn(lambda _match: line, source)
    if not count:
        source += line + "\n"
    return source


def is_proxy(name):
    return (
        name in PROXY_EXACT
        or name.startswith(("luci-app-passwall-", "luci-app-passwall_", "luci-i18n-passwall-"))
        or name.startswith(("luci-app-openclash-", "luci-app-openclash_", "luci-i18n-openclash-"))
        or name.startswith(("luci-app-ssr-plus-", "luci-app-ssr-plus_", "luci-i18n-ssr-plus-"))
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preset", choices=DEVICES)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / ".config")
    args = parser.parse_args()
    if not re.fullmatch(r"\d{6}-\d{2}", args.version):
        parser.error("version must be YYMMDD-NN")

    source = (ROOT / "config.ss01-261101-01-nss").read_text()
    for name in re.findall(r"^CONFIG_PACKAGE_([^=]+)=y$", source, re.M):
        if is_proxy(name):
            source = set_value(source, "PACKAGE_" + name, None)
    for name in ("easytier", "easytier-noweb"):
        source = set_value(source, "PACKAGE_" + name, None)

    for name in (
        "luci-app-easytier", "luci-i18n-easytier-zh-cn", "honk",
        "luci-app-honk", "luci-lib-daeuniverse", "vmlinux-btf-builtin",
        "gwrt-tv-adblock", "luci-app-gwrt-tvadblock", "luci-app-iptv",
        "udpxy", "luci-app-udpxy", "vlmcsd", "luci-app-vlmcsd",
        "gwrt-agent", "gwrt-device-defaults", "gwrt-mesh-apmode",
        "gwrt-mesh-led", "luci-theme-gwrt", "sgdisk",
        "kmod-sched-core", "kmod-sched-bpf", "kmod-veth",
        "kmod-nft-core", "kmod-nft-queue", "kmod-nfnetlink-queue",
        "kmod-nf-conntrack", "kmod-qca-ppe", "kmod-qca-edma",
    ):
        source = set_value(source, "PACKAGE_" + name, "y")

    # BTF and cgroup BPF are required by Honk on all four IPQ6018 devices.
    for name in ("KERNEL_DEBUG_INFO", "KERNEL_DEBUG_INFO_BTF", "KERNEL_CGROUP_BPF"):
        source = set_value(source, name, "y")
    source = set_value(source, "EASYTIER_INCLUDE_WEBCONSOLE", None)

    device = DEVICES[args.preset]
    target_pattern = re.compile(
        r"^CONFIG_(TARGET_qualcommax_ipq60xx_DEVICE_[^=]+)=y$", re.M
    )
    source = target_pattern.sub(
        lambda m: "# CONFIG_" + m.group(1) + " is not set", source
    )
    source = set_value(
        source, "TARGET_qualcommax_ipq60xx_DEVICE_" + device, "y"
    )
    source = set_value(source, "TARGET_PROFILE", '"DEVICE_' + device + '"')
    source = set_value(source, "VERSION_NUMBER", '"' + args.version + '"')
    source = set_value(source, "PREINITOPT", "y")
    source = set_value(source, "TARGET_PREINIT_IP", '"192.168.3.3"')
    source = set_value(source, "TARGET_PREINIT_BROADCAST", '"192.168.3.255"')
    if args.preset == "ss01":
        for name in (
            "ipq-wifi-jdcloud_re-ss-01", "ath11k-firmware-ipq6018-ddwrt",
            "kmod-ath11k", "kmod-ath11k-ahb", "wpad-openssl",
            "kmod-qca-nss-dp", "kmod-qca-ssdk",
        ):
            source = set_value(source, "PACKAGE_" + name, "y")
        for name in ("ipq-wifi-jdcloud_re-cs-02", "athena-led", "luci-app-athena-led",
                     "kmod-ath11k-pci", "ath11k-firmware-qcn9074-ddwrt"):
            source = set_value(source, "PACKAGE_" + name, None)
        for name in ("kmod-qca-ppe", "kmod-qca-edma"):
            source = set_value(source, "PACKAGE_" + name, None)
    else:
        # CS targets use the DTS-described DSA PPE/EDMA path, not NSS/SSDK.
        for name in re.findall(r"^CONFIG_PACKAGE_([^=]+)=y$", source, re.M):
            if name.startswith(("kmod-qca-nss", "kmod-qca-ssdk", "kmod-nss-",
                                "nss-firmware", "nss-eip-firmware")):
                source = set_value(source, "PACKAGE_" + name, None)
        for name in ("ipq-wifi-jdcloud_re-ss-01", "kmod-qca-nss-dp", "kmod-qca-ssdk"):
            source = set_value(source, "PACKAGE_" + name, None)
        for name in ("kmod-qca-ppe", "kmod-qca-edma"):
            source = set_value(source, "PACKAGE_" + name, "y")

    if args.preset in ("cs02", "cs02-gwrt2"):
        for name in (
            "ipq-wifi-jdcloud_re-cs-02", "ath11k-firmware-ipq6018-ddwrt",
            "ath11k-firmware-qcn9074-ddwrt", "kmod-ath11k", "kmod-ath11k-ahb",
            "kmod-ath11k-pci", "wpad-openssl", "athena-led",
            "luci-app-athena-led",
        ):
            source = set_value(source, "PACKAGE_" + name, "y")
        for name in ("ath11k-firmware-ipq6018", "ath11k-firmware-qcn9074",
                     "ipq-wifi-jdcloud_re-ss-01"):
            source = set_value(source, "PACKAGE_" + name, None)
    elif args.preset == "cs07":
        for name in WIRELESS_EXACT:
            source = set_value(source, "PACKAGE_" + name, None)
        for name in re.findall(r"^CONFIG_PACKAGE_([^=]+)=y$", source, re.M):
            if name.startswith(("kmod-ath", "ath11k-firmware-", "ipq-wifi-",
                                "luci-app-wifiroam", "luci-i18n-wifiroam-")):
                source = set_value(source, "PACKAGE_" + name, None)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)
    print(f"Generated {args.preset}: {device}, SS-01 Honk application set, {args.version}, 12M")


if __name__ == "__main__":
    main()
