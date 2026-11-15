#!/usr/bin/env python3
"""Reject production plugins in resolved CS-06 diagnostic configs/manifests."""
import argparse
from pathlib import Path
import re

REQUIRED = {'kmod-ath12k', 'ath12k-firmware-ipq5332-ddwrt',
            'ath12k-firmware-qcn9274-ddwrt', 'ipq-wifi-jdcloud_re-cs-06',
            'wpad-openssl', 'luci', 'luci-theme-bootstrap', 'dropbear',
            'dnsmasq', 'firewall4', 'iw', 'hostapd-utils', 'tcpdump-mini',
            'gwrt-cs06-diag-defaults'}
ALLOWED_LUCI_APPS = {'luci-app-firewall', 'luci-app-package-manager'}
FORBIDDEN = re.compile(r'^(?:gwrt-(?!cs06-diag-defaults$)|athena-led$|wifiroam$|'
                       r'luci-theme-gwrt$|(?:luci-(?:app|i18n)-)?'
                       r'(?:daed|dae|homeproxy|openclash|passwall|ssr-plus|shadowsocks|'
                       r'sing-box|xray|v2ray|easytier|bandix|appfilter|oaf|fwx|'
                       r'aria2|samba|adguard|adblock|turboacc|eqos|nlbwmon|vlmcsd|'
                       r'udpxy|wifiroam|athena-led)(?:$|[-+]))')


def check(packages, label):
    missing = REQUIRED - packages
    forbidden = sorted(p for p in packages if FORBIDDEN.search(p) or
                       (p.startswith('luci-app-') and p not in ALLOWED_LUCI_APPS))
    if missing or forbidden:
        raise ValueError(f'{label}: missing={sorted(missing)} forbidden={forbidden}')
    print(f'PASS CS-06 minimal packages: {label} ({len(packages)} packages)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('--manifests', type=Path)
    args = parser.parse_args()
    config = args.config.read_text()
    assert 'CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y' in config.splitlines()
    check(set(re.findall(r'^CONFIG_PACKAGE_([a-z0-9+_.-]+)=[ym]$', config, re.M)), 'resolved config')
    if args.manifests:
        manifests = list(args.manifests.rglob('*jdcloud_re-cs-06*.manifest'))
        assert len(manifests) == 1, 'missing/ambiguous CS-06 manifest'
        for path in manifests:
            check({line.split(' - ', 1)[0] for line in path.read_text().splitlines()}, path.name)


if __name__ == '__main__':
    main()
