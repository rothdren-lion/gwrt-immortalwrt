#!/usr/bin/env python3
"""Validate the isolated SS-01 Honk + EasyTier config and manifests."""

import argparse
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]

REQUIRED = {
    "honk",
    "luci-app-honk",
    "luci-lib-daeuniverse",
    "luci-app-easytier",
    "luci-i18n-easytier-zh-cn",
    "vmlinux-btf-builtin",
    "gwrt-agent",
    "gwrt-device-defaults",
    "gwrt-mesh-apmode",
    "gwrt-mesh-led",
    "gwrt-tv-adblock",
    "luci-app-gwrt-tvadblock",
    "luci-app-iptv",
    "udpxy",
    "luci-app-udpxy",
    "vlmcsd",
    "luci-app-vlmcsd",
}

FORBIDDEN_EXACT = {
    "3proxy",
    "dae",
    "dae-geoip",
    "dae-geosite",
    "daed",
    "daed-geoip",
    "daed-geosite",
    "dns2socks",
    "dnscrypt-proxy",
    "dnscrypt-proxy2",
    "easytier",
    "easytier-noweb",
    "hysteria",
    "geoview",
    "ipt2socks",
    "luci-app-dae",
    "luci-app-daed",
    "luci-app-homeproxy",
    "luci-app-openclash",
    "luci-app-passwall",
    "luci-app-privoxy",
    "luci-app-ssr-plus",
    "luci-app-v2raya",
    "luci-i18n-daed-zh-cn",
    "luci-i18n-homeproxy-zh-cn",
    "luci-i18n-openclash-zh-cn",
    "luci-i18n-passwall-zh-cn",
    "luci-i18n-ssr-plus-zh-cn",
    "luci-i18n-v2raya-zh-cn",
    "microsocks",
    "naiveproxy",
    "ohybridproxy",
    "privoxy",
    "proxychains-ng",
    "shadowsocks-rust-sslocal",
    "shadowsocks-rust-ssmanager",
    "shadowsocks-rust-ssserver",
    "shadowsocks-rust-ssservice",
    "shadowsocks-rust-ssurl",
    "sing-box",
    "sing-box-tiny",
    "trojan",
    "tuic-client",
    "tuic-server",
    "v2ray-core",
    "v2raya",
    "v2ray-plugin",
    "v2dat",
    "xray-core",
    "xray-plugin",
    "gwrt-ssr-plus-luci",
}


def package_is_forbidden(name: str) -> bool:
    # Kconfig keeps passwall's optional feature symbols in .config even when
    # the luci-app-passwall package itself is disabled. They are selections,
    # not packages that can be shipped in the image, so do not treat them as
    # an installed proxy engine.
    if name.startswith("luci-app-passwall_INCLUDE_"):
        return False
    return (
        name in FORBIDDEN_EXACT
        or name.startswith(("luci-app-passwall-", "luci-app-passwall_", "luci-i18n-passwall-"))
        or name.startswith(("luci-app-openclash-", "luci-app-openclash_", "luci-i18n-openclash-"))
        or name.startswith(("luci-app-ssr-plus-", "luci-app-ssr-plus_", "luci-i18n-ssr-plus-"))
    )


def read_enabled(path: Path) -> set[str]:
    text = path.read_text()
    return {key[8:] for key, value in re.findall(r"^CONFIG_(PACKAGE_[^=]+)=(y|m)$", text, re.M)}


def check_config(path: Path) -> set[str]:
    text = path.read_text()
    packages = read_enabled(path)
    required = set(REQUIRED)
    missing = required - packages
    if missing:
        raise SystemExit("FAIL config missing: " + ", ".join(sorted(missing)))
    built_in = set(re.findall(r"^CONFIG_PACKAGE_([^=]+)=y$", text, re.M))
    if REQUIRED - built_in:
        raise SystemExit("FAIL packages must be embedded (=y): " + ", ".join(sorted(REQUIRED - built_in)))
    forbidden = sorted(name for name in packages if package_is_forbidden(name))
    if forbidden:
        raise SystemExit("FAIL config still enables proxy packages: " + ", ".join(forbidden))
    for line in (
        "CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y",
        "CONFIG_PACKAGE_wpad-openssl=y",
        "CONFIG_PACKAGE_ipq-wifi-jdcloud_re-ss-01=y",
        "CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=y",
        "CONFIG_PACKAGE_kmod-ath11k-ahb=y",
        "CONFIG_PACKAGE_kmod-qca-nss-dp=y",
        "CONFIG_PACKAGE_kmod-qca-ssdk=y",
        "CONFIG_KERNEL_DEBUG_INFO_BTF=y",
        "CONFIG_KERNEL_CGROUP_BPF=y",
    ):
        if line not in text.splitlines():
            raise SystemExit("FAIL config missing: " + line)
    if "CONFIG_EASYTIER_INCLUDE_WEBCONSOLE=y" in text.splitlines():
        raise SystemExit("FAIL EasyTier web console must not be embedded")
    print("PASS Honk + EasyTier LuCI-only config: SS-01 target, Mesh/NSS, adblock, IPTV/UDPXY, vlmcsd, no proxy engine")
    return packages


def check_manifests(manifest_dir: Path) -> None:
    manifests = sorted(manifest_dir.glob("*.manifest"))
    if not manifests:
        raise SystemExit("FAIL no package manifest in " + str(manifest_dir))
    found: set[str] = set()
    for path in manifests:
        for line in path.read_text().splitlines():
            match = re.match(r"^([^\s]+)\s+-\s+", line)
            if match:
                found.add(match.group(1))
    missing = REQUIRED - found
    if missing:
        raise SystemExit("FAIL manifest missing: " + ", ".join(sorted(missing)))
    forbidden = sorted(name for name in found if package_is_forbidden(name))
    if forbidden:
        raise SystemExit("FAIL manifest contains proxy packages: " + ", ".join(forbidden))
    print("PASS Honk + EasyTier LuCI-only manifest packages:", ", ".join(sorted(REQUIRED)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--manifests", type=Path)
    args = parser.parse_args()
    check_config(args.config)
    if args.manifests:
        check_manifests(args.manifests)


if __name__ == "__main__":
    main()
