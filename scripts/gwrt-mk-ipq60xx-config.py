#!/usr/bin/env python3
"""Derive JDC IPQ60xx profiles from the current SS-01 application selection."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
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

    if args.preset != 'ss01':
        # The CS DTS uses the DSA PPE/EDMA path. NSS/SSDK owns the same
        # hardware and must not be installed alongside that path.
        for name in re.findall(r'^CONFIG_PACKAGE_([^=]+)=y$', source, re.M):
            if name.startswith(('kmod-qca-nss', 'kmod-qca-ssdk', 'kmod-nss-', 'nss-firmware', 'nss-eip-firmware')):
                set_value('PACKAGE_' + name, None)
        for name in ('kmod-qca-ppe', 'kmod-qca-edma'):
            set_value('PACKAGE_' + name, 'y')
        set_value('PACKAGE_ipq-wifi-jdcloud_re-ss-01', None)

    if args.preset in ('cs02', 'cs02-gwrt2'):
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
