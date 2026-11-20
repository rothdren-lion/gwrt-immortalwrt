#!/usr/bin/env python3
"""Validate the isolated SS-01 Honk + EasyTier config and manifests."""

import argparse
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]

NSS_KERNEL_API = {
    "qca_edma": ("qca_edma_cpu_queues_to_host", "qca_edma_cpu_queues_to_ring"),
    "qca_ppe": ("qca_ppe_fw_booted", "qca_ppe_fw_ports_set", "qca_ppe_fw_carrier_set"),
}
NSS_WIFI_PACKAGE = "kmod-nss-wifi-drv"
QSDK_WIRED_PACKAGES = {
    "kmod-qca-nss-dp",
    "kmod-qca-nss-drv",
    "kmod-qca-nss-drv-bridge-mgr",
    "kmod-qca-nss-drv-vlan-mgr",
    "kmod-qca-nss-ecm",
    "kmod-qca-ssdk",
}
NSS_KERNEL_BUILTINS = {
    "QCOM_EDMA", "QCOM_80211AX_PPE", "NET_DSA", "NET_DSA_TAG_QCA",
    "PCS_QCA_UNIPHY", "PAGE_POOL", "PHYLINK", "REGMAP_MMIO", "NET_REDIRECT",
    "NF_CONNTRACK", "NF_TABLES", "NF_FLOW_TABLE",
}

REQUIRED = {
    "honk",
    "luci-app-honk",
    "luci-lib-daeuniverse",
    "easytier",
    "luci-app-easytier",
    "luci-i18n-easytier-zh-cn",
    "vmlinux-btf-builtin",
    "gwrt-agent",
    "gwrt-device-defaults",
    "gwrt-mesh-apmode",
    "gwrt-mesh-led",
}

FORBIDDEN_EXACT = {
    "3proxy",
    "dae",
    "dae-geoip",
    "dae-geosite",
    "daed",
    "daed-geoip",
    "daed-geosite",
    "dnscrypt-proxy",
    "dnscrypt-proxy2",
    "hysteria",
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
    selected = set(text.splitlines())
    required = set(REQUIRED)
    missing = required - packages
    if missing:
        raise SystemExit("FAIL config missing: " + ", ".join(sorted(missing)))
    forbidden = sorted(name for name in packages if package_is_forbidden(name))
    if forbidden:
        raise SystemExit("FAIL config still enables proxy packages: " + ", ".join(forbidden))
    for line in (
        "CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y",
        "CONFIG_PACKAGE_wpad-openssl=y",
        "CONFIG_PACKAGE_ipq-wifi-jdcloud_re-ss-01=y",
        "CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=y",
        "CONFIG_PACKAGE_kmod-ath11k-ahb=y",
        "CONFIG_EASYTIER_INCLUDE_WEBCONSOLE=y",
        "CONFIG_KERNEL_DEBUG_INFO_BTF=y",
        "CONFIG_KERNEL_CGROUP_BPF=y",
    ):
        if line not in selected:
            raise SystemExit("FAIL config missing: " + line)
    if NSS_WIFI_PACKAGE not in packages:
        for package in ("kmod-qca-nss-dp", "kmod-qca-ssdk"):
            if f"CONFIG_PACKAGE_{package}=y" not in selected:
                raise SystemExit(f"FAIL config missing wired QSDK package: {package}")
    print("PASS Honk + EasyTier base config: SS-01 target, Mesh, embedded UI, no proxy engine")
    return packages


def check_nss_wifi_abi(
    packages: set[str], *, root: Path = ROOT, symvers: Path | None = None,
    kernel_config: Path | None = None, module_undefined: Path | None = None,
) -> None:
    if NSS_WIFI_PACKAGE not in packages:
        raise SystemExit(f"FAIL config does not select {NSS_WIFI_PACKAGE}")

    overlay = root / "target/linux/qualcommax/files"
    errors = []
    conflicts = sorted(QSDK_WIRED_PACKAGES & packages)
    if conflicts:
        errors.append("QSDK packages conflict with native EDMA/PPE and NSS Wi-Fi: " + ", ".join(conflicts))
    for driver, symbols in NSS_KERNEL_API.items():
        header = overlay / f"include/linux/soc/qcom/{driver}.h"
        implementation = overlay / "drivers/net/ethernet/qualcomm" / (
            "qca_ppe_main.c" if driver == "qca_ppe" else "qca_edma.c"
        )
        declarations = header.read_text() if header.is_file() else ""
        exports = implementation.read_text() if implementation.is_file() else ""
        if not header.is_file():
            errors.append(f"missing public header {header.relative_to(root)}")
        for symbol in symbols:
            if header.is_file() and not re.search(rf"\b{symbol}\s*\(", declarations):
                errors.append(f"{header.name} does not declare {symbol}")
            if not re.search(rf"\bEXPORT_SYMBOL(?:_GPL)?\s*\(\s*{symbol}\s*\)", exports):
                errors.append(f"{implementation.name} does not export {symbol}")

    required_symbols = set().union(*NSS_KERNEL_API.values())
    if kernel_config is not None:
        config_lines = set(kernel_config.read_text().splitlines())
        errors.extend(
            f"kernel .config lacks CONFIG_{name}=y" for name in sorted(NSS_KERNEL_BUILTINS)
            if f"CONFIG_{name}=y" not in config_lines
        )
    if symvers is not None:
        exported = {
            fields[1] for line in symvers.read_text().splitlines()
            if len(fields := line.split()) >= 4 and fields[2:4] == ["vmlinux", "EXPORT_SYMBOL_GPL"]
        }
        errors.extend(f"{symvers.name} lacks vmlinux GPL export {symbol}" for symbol in sorted(required_symbols - exported))
    if module_undefined is not None:
        imported = {
            fields[-1] for line in module_undefined.read_text().splitlines()
            if len(fields := line.split()) >= 2 and fields[-2] == "U"
        }
        errors.extend(f"nss-wifi-drv.ko does not import {symbol}" for symbol in sorted(required_symbols - imported))

    if errors:
        raise SystemExit("FAIL SS-01 NSS Wi-Fi ABI:\n  " + "\n  ".join(errors))
    print("PASS SS-01 NSS Wi-Fi ABI preflight (not a runtime offload test)")


def check_manifests(manifest_dir: Path, *, require_nss_wifi: bool = False) -> None:
    manifests = sorted(manifest_dir.glob("*.manifest"))
    if not manifests:
        raise SystemExit("FAIL no package manifest in " + str(manifest_dir))
    found: set[str] = set()
    for path in manifests:
        for line in path.read_text().splitlines():
            match = re.match(r"^([^\s]+)\s+-\s+", line)
            if match:
                found.add(match.group(1))
    required = REQUIRED | ({NSS_WIFI_PACKAGE} if require_nss_wifi else set())
    missing = required - found
    if missing:
        raise SystemExit("FAIL manifest missing: " + ", ".join(sorted(missing)))
    forbidden = sorted(name for name in found if package_is_forbidden(name))
    if forbidden:
        raise SystemExit("FAIL manifest contains proxy packages: " + ", ".join(forbidden))
    print("PASS Honk + EasyTier manifest packages:", ", ".join(sorted(required)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--manifests", type=Path)
    parser.add_argument("--require-nss-wifi", action="store_true")
    parser.add_argument("--kernel-symvers", type=Path)
    parser.add_argument("--kernel-config", type=Path)
    parser.add_argument("--module-undefined", type=Path)
    args = parser.parse_args()
    packages = check_config(args.config)
    require_nss_wifi = (
        args.require_nss_wifi or args.kernel_symvers is not None or args.kernel_config is not None
        or args.module_undefined is not None or NSS_WIFI_PACKAGE in packages
    )
    if require_nss_wifi:
        if not re.search(rf"^CONFIG_PACKAGE_{re.escape(NSS_WIFI_PACKAGE)}=y$", args.config.read_text(), re.M):
            raise SystemExit(f"FAIL config does not embed {NSS_WIFI_PACKAGE} (expected =y)")
        check_nss_wifi_abi(
            packages, symvers=args.kernel_symvers, kernel_config=args.kernel_config,
            module_undefined=args.module_undefined,
        )
    if args.manifests:
        check_manifests(args.manifests, require_nss_wifi=require_nss_wifi)


if __name__ == "__main__":
    main()
