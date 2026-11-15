#!/usr/bin/env python3
"""Generate the isolated SS-01 Honk + EasyTier firmware configuration."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "config.ss01-261101-01-nss"

# These are proxy engines or proxy management pages. Generic netfilter/BPF
# modules stay in the base profile because Honk uses its own eBPF/NFQUEUE path.
PROXY_NAMES = {
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
    "hysteria",
    "geoview",
    "ipt2socks",
    "gwrt-ssr-plus-luci",
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
}


def package_is_proxy(name: str) -> bool:
    return (
        name in PROXY_NAMES
        or name.startswith(("luci-app-passwall-", "luci-app-passwall_", "luci-i18n-passwall-"))
        or name.startswith(("luci-app-openclash-", "luci-app-openclash_", "luci-i18n-openclash-"))
        or name.startswith(("luci-app-ssr-plus-", "luci-app-ssr-plus_", "luci-i18n-ssr-plus-"))
    )


def set_value(source: str, name: str, value: str | None) -> str:
    line = f"# CONFIG_{name} is not set" if value is None else f"CONFIG_{name}={value}"
    pattern = re.compile(
        rf"^(?:CONFIG_{re.escape(name)}=.*|# CONFIG_{re.escape(name)} is not set)$",
        re.M,
    )
    source, count = pattern.subn(line, source)
    if not count:
        source += line + "\n"
    return source


def main() -> int:
    version = sys.argv[1] if len(sys.argv) == 2 else "261115-03"
    if not re.fullmatch(r"\d{6}-\d{2}", version):
        raise SystemExit("usage: gwrt-mk-ss01-honk-easytier-config.py [YYMMDD-NN]")

    source = SOURCE.read_text()
    for name in re.findall(r"^CONFIG_PACKAGE_([^=]+)=y$", source, re.M):
        if package_is_proxy(name):
            source = set_value(source, "PACKAGE_" + name, None)

    # Keep the EasyTier management page only. The user installs or uploads the
    # architecture-specific runtime when they choose to run an EasyTier node.
    for name in (
        "luci-app-easytier",
        "luci-i18n-easytier-zh-cn",
        "honk",
        "luci-app-honk",
        "luci-lib-daeuniverse",
        "vmlinux-btf-builtin",
        "gwrt-tv-adblock",
        "luci-app-gwrt-tvadblock",
        "luci-app-iptv",
        "udpxy",
        "luci-app-udpxy",
        "vlmcsd",
        "luci-app-vlmcsd",
    ):
        source = set_value(source, "PACKAGE_" + name, "y")
    for name in ("easytier", "easytier-noweb"):
        source = set_value(source, "PACKAGE_" + name, None)
    source = set_value(source, "EASYTIER_INCLUDE_WEBCONSOLE", None)

    # Honk's Makefile depends on the virtual vmlinux-btf provider. ImmortalWrt
    # already puts BTF in the kernel, so the empty builtin provider is correct;
    # a detached blob must not be generated for this in-tree BTF kernel.
    for name in (
        "KERNEL_DEBUG_INFO",
        "KERNEL_DEBUG_INFO_BTF",
        "KERNEL_CGROUP_BPF",
        "PACKAGE_kmod-sched-core",
        "PACKAGE_kmod-sched-bpf",
        "PACKAGE_kmod-veth",
        "PACKAGE_kmod-nft-core",
        "PACKAGE_kmod-nft-queue",
        "PACKAGE_kmod-nfnetlink-queue",
        "PACKAGE_kmod-nf-conntrack",
    ):
        source = set_value(source, name, "y")

    source = set_value(source, "VERSION_NUMBER", f'"{version}"')
    source = set_value(source, "PREINITOPT", "y")
    source = set_value(source, "TARGET_PREINIT_IP", '"192.168.3.3"')
    source = set_value(source, "TARGET_PREINIT_BROADCAST", '"192.168.3.255"')
    source = set_value(source, "OVERRIDE_PKGS", '""')

    # Preserve the physical SS-01 12 MiB HLOS layout used by the latest
    # four-profile build. The workflow passes this variable explicitly too.
    source = set_value(source, "CS02_KERNEL_SIZE", '"12288k"')
    (ROOT / ".config").write_text(source)
    print("Generated isolated SS-01 Honk + EasyTier configuration:", version)
    print("Removed proxy engines; selected Honk + Doona, EasyTier LuCI only, adblock, IPTV/UDPXY, and vlmcsd")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
