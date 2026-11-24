#!/usr/bin/env python3
"""Derive JDC IPQ60xx profiles from the current SS-01 application selection."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

# 代理引擎与代理管理页（Honk 除外）。Honk 使用自己的 eBPF/NFQUEUE 数据面，
# 因此通用 netfilter/BPF 模块不在剔除范围内。
PROXY_NAMES = {
    '3proxy', 'dae', 'dae-geoip', 'dae-geosite', 'daed', 'daed-geoip', 'daed-geosite',
    'dnscrypt-proxy', 'dnscrypt-proxy2', 'hysteria', 'gwrt-ssr-plus-luci',
    'luci-app-dae', 'luci-app-daed', 'luci-app-homeproxy', 'luci-app-openclash',
    'luci-app-passwall', 'luci-app-privoxy', 'luci-app-ssr-plus', 'luci-app-v2raya',
    'luci-i18n-daed-zh-cn', 'luci-i18n-homeproxy-zh-cn', 'luci-i18n-openclash-zh-cn',
    'luci-i18n-passwall-zh-cn', 'luci-i18n-ssr-plus-zh-cn', 'luci-i18n-v2raya-zh-cn',
    'microsocks', 'naiveproxy', 'ohybridproxy', 'privoxy', 'proxychains-ng',
    'shadowsocks-rust-sslocal', 'shadowsocks-rust-ssmanager', 'shadowsocks-rust-ssserver',
    'shadowsocks-rust-ssservice', 'shadowsocks-rust-ssurl',
    'sing-box', 'sing-box-tiny', 'trojan', 'tuic-client', 'tuic-server',
    'v2ray-core', 'v2raya', 'v2ray-plugin', 'xray-core', 'xray-plugin',
}


def package_is_proxy(name: str) -> bool:
    return (
        name in PROXY_NAMES
        or name.startswith(('luci-app-passwall-', 'luci-app-passwall_', 'luci-i18n-passwall-'))
        or name.startswith(('luci-app-openclash-', 'luci-app-openclash_', 'luci-i18n-openclash-'))
        or name.startswith(('luci-app-ssr-plus-', 'luci-app-ssr-plus_', 'luci-i18n-ssr-plus-'))
    )


DEVICES = {
    'ss01': 'jdcloud_re-ss-01',
    'cs02': 'jdcloud_re-cs-02',
    'cs02-gwrt2': 'jdcloud_re-cs-02-gwrt2',
    'cs07': 'jdcloud_re-cs-07',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('preset', choices=DEVICES)
    parser.add_argument('--output', type=Path, default=ROOT / '.config')
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d{6}-\d{2}', args.version):
        parser.error('version must be YYMMDD-NN')
    source = (ROOT / 'config.ss01-261101-01-nss').read_text()

    def set_value(name, value):
        nonlocal source
        line = f'# CONFIG_{name} is not set' if value is None else f'CONFIG_{name}={value}'
        pattern = re.compile(r'^(?:CONFIG_' + re.escape(name) + r'=.*|# CONFIG_' + re.escape(name) + r' is not set)$', re.M)
        source, count = pattern.subn(lambda match: line, source)
        if not count:
            source += line + '\n'

    for symbol in re.findall(r'^CONFIG_(TARGET_(?:DEVICE_)?\w+_DEVICE_[^=]+)=y$', source, re.M):
        set_value(symbol, None)
    device = DEVICES[args.preset]
    set_value('TARGET_qualcommax_ipq60xx_DEVICE_' + device, 'y')
    set_value('TARGET_PROFILE', '"DEVICE_' + device + '"')
    set_value('VERSION_NUMBER', '"' + args.version + '"')
    set_value('PREINITOPT', 'y')
    set_value('TARGET_PREINIT_IP', '"192.168.3.3"')
    set_value('TARGET_PREINIT_BROADCAST', '"192.168.3.255"')

    if args.preset == 'ss01':
        # 新版 wifiroam v5 覆盖层：装到私有目录，由 97 首启脚本换上
        set_value('PACKAGE_gwrt-wifiroam-v5', 'y')
        # 应用管控的 DPI 旁路（NFQUEUE）需要内核队列模块
        set_value('PACKAGE_kmod-nfnetlink-queue', 'y')

    if args.preset != 'ss01':
        if args.preset in ('cs02', 'cs02-gwrt2'):
            # 用户要求 NSS+PPE 同时编进镜像：NSS 栈（dp/drv/ecm/ssdk/固件）与
            # PPE/EDMA 模块都选中。实际由 DTS 决定哪一路绑定网口（当前 CS-02 DTS
            # 用 ipq6018-ess.dtsi，即 PPE/EDMA 数据面；NSS 栈随镜像可用）。
            for name in ('nss-firmware', 'nss-firmware-ipq60xx', 'kmod-qca-nss-dp',
                         'kmod-qca-nss-drv', 'kmod-qca-nss-drv-bridge-mgr',
                         'kmod-qca-nss-drv-vlan-mgr', 'kmod-qca-nss-ecm',
                         'kmod-qca-ssdk', 'kmod-qca-ppe', 'kmod-qca-edma'):
                set_value('PACKAGE_' + name, 'y')
            # 与 SS-01 一致：NSS 固件/驱动负责无线卸载（kmod-nss-wifi-drv 随
            # 参考机型选中），有线仍走 DTS 里的 DSA/PPE（ipq6018-ess.dtsi）。
            set_value('PACKAGE_kmod-nss-wifi-drv', 'y')
            set_value('PACKAGE_nss-eip-firmware', 'y')
        else:
            # CS-07: DSA PPE/EDMA path conflicts with NSS/SSDK
            for name in re.findall(r'^CONFIG_PACKAGE_([^=]+)=y$', source, re.M):
                if name.startswith(('kmod-qca-nss', 'kmod-qca-ssdk', 'kmod-nss-', 'nss-firmware', 'nss-eip-firmware')):
                    set_value('PACKAGE_' + name, None)
            for name in ('kmod-qca-ppe', 'kmod-qca-edma'):
                set_value('PACKAGE_' + name, 'y')
        set_value('PACKAGE_ipq-wifi-jdcloud_re-ss-01', None)

    if args.preset in ('cs02', 'cs02-gwrt2'):
        # 删除 geocosos（gecoosac）——用户要求不纳入本机型
        for name in ('gecoosac', 'luci-app-gecoosac', 'luci-i18n-gecoosac-zh-cn'):
            set_value('PACKAGE_' + name, None)
        # 去掉所有代理引擎/管理页，换 Honk（eBPF 透明代理）
        # 注意：v2ray-geoip/geosite 保留，Honk 的 Makefile 依赖它们提供 dat 文件。
        for name in re.findall(r'^CONFIG_PACKAGE_([^=]+)=y$', source, re.M):
            if package_is_proxy(name):
                set_value('PACKAGE_' + name, None)
        set_value('OVERRIDE_PKGS', None)
        # Honk 完整包（含内嵌 Doona 面板）+ LuCI 页
        for name in ('honk', 'luci-app-honk', 'luci-lib-daeuniverse', 'vmlinux-btf-builtin',
                     'v2ray-geoip', 'v2ray-geosite'):
            set_value('PACKAGE_' + name, 'y')
        # Honk 的 eBPF/NFQUEUE 数据面依赖：内核 BTF + TC-bpf/ nft queue /veth
        for name in ('KERNEL_DEBUG_INFO', 'KERNEL_DEBUG_INFO_BTF', 'KERNEL_CGROUP_BPF'):
            set_value(name, 'y')
        for name in ('kmod-sched-core', 'kmod-sched-bpf', 'kmod-veth', 'kmod-nft-core',
                     'kmod-nft-queue', 'kmod-nfnetlink-queue', 'kmod-nf-conntrack'):
            set_value('PACKAGE_' + name, 'y')
        for name in ('ipq-wifi-jdcloud_re-cs-02', 'ath11k-firmware-ipq6018-ddwrt',
                     'ath11k-firmware-qcn9074-ddwrt', 'kmod-ath11k-ahb',
                     'kmod-ath11k-pci', 'wpad-openssl', 'athena-led', 'luci-app-athena-led'):
            set_value('PACKAGE_' + name, 'y')
    elif args.preset == 'cs07':
        for name in re.findall(r'^CONFIG_PACKAGE_([^=]+)=y$', source, re.M):
            if name.startswith(('kmod-ath', 'ath11k-firmware-', 'ipq-wifi-')) or name in {
                'kmod-cfg80211', 'kmod-mac80211', 'hostapd-common', 'wpad-openssl',
                'wifi-scripts', 'wireless-regdb', 'iw', 'iw-full', 'iwinfo',
                'libiwinfo', 'libiwinfo-data', 'libiwinfo-lua', 'rpcd-mod-iwinfo',
                'athena-led', 'luci-app-athena-led',
            }:
                set_value('PACKAGE_' + name, None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)
    print(f'Generated {args.preset}: {device}, SS-01 applications, {args.version}')


if __name__ == '__main__':
    main()
