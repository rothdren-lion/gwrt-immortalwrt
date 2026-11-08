#!/usr/bin/env python3
"""Validate resolved GWRT configs and the final per-device package manifests."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('config', type=Path)
parser.add_argument('preset')
parser.add_argument('--manifests', type=Path)
parser.add_argument('--models', default='')
args = parser.parse_args()
subprocess.run(['sh', str(ROOT / 'gwrt-check-target.sh'), str(args.config.resolve()), args.preset], cwd=ROOT, check=True)
values = dict(re.findall(r'^CONFIG_([^=]+)=(.*)$', args.config.read_text(), re.M))
board, sub = (values['TARGET_' + key].strip('"') for key in ('BOARD', 'SUBTARGET'))
devices = sorted({m.group(1) for key, val in values.items() if val == 'y'
                  and (m := re.fullmatch(r'TARGET_(?:DEVICE_)?' + board + '_' + sub + r'_DEVICE_(.+)', key))})
errors = []
if args.models:
    wanted = set(re.split(r'[\s,]+', args.models.strip()))
    if wanted != set(devices):
        errors.append('resolved profiles differ from the requested models: ' + ', '.join(sorted(set(devices) ^ wanted)))

def fail(message):
    errors.append(message)

def check_packages(packages, required, forbidden, label):
    missing = set(required) - packages
    extra = set(forbidden) & packages
    if missing:
        fail(label + ': missing ' + ', '.join(sorted(missing)))
    if extra:
        fail(label + ': forbidden ' + ', '.join(sorted(extra)))

packages = {key[8:] for key, val in values.items() if key.startswith('PACKAGE_') and val in ('y', 'm')}
ahb = {'kmod-ath11k', 'kmod-ath11k-ahb', 'wpad-openssl'}
pci = {'kmod-ath11k-pci', 'ath11k-firmware-qcn9074', 'ath11k-firmware-qcn9074-ddwrt'}
ath12k = {'kmod-ath12k', 'wpad-openssl', 'ath12k-firmware-ipq5332-ddwrt', 'ath12k-firmware-qcn9274-ddwrt'}
radio_packages = {p for p in packages if p.startswith(('kmod-ath11k', 'ath11k-firmware-', 'kmod-ath12k', 'ath12k-firmware-', 'kmod-mt79'))}

def requirements(device):
    required, forbidden = set(), set()
    if device in ('jdcloud_re-cs-02', 'jdcloud_re-cs-02-gwrt2'):
        required |= ahb | {'kmod-ath11k-pci', 'ath11k-firmware-ipq6018-ddwrt',
                           'ath11k-firmware-qcn9074-ddwrt', 'ipq-wifi-jdcloud_re-cs-02'}
        forbidden |= {'ath11k-firmware-ipq6018', 'ath11k-firmware-qcn9074'}
    elif device == 'jdcloud_re-ss-01':
        required |= ahb | {'ath11k-firmware-ipq6018-ddwrt', 'ipq-wifi-jdcloud_re-ss-01'}
        forbidden |= pci | {'ipq-wifi-jdcloud_re-cs-02', 'luci-app-athena-led'}
    elif device in ('jdcloud_re-cs-06', 'xiaomi_be6500'):
        required |= ath12k | {'ipq-wifi-' + device}
        forbidden |= ahb - {'wpad-openssl'}
        other = 'xiaomi_be6500' if device == 'jdcloud_re-cs-06' else 'jdcloud_re-cs-06'
        forbidden.add('ipq-wifi-' + other)
    elif device in ('jdcloud_re-cs-07', 'jdcloud_re-cs-08', 'clx_s20m'):
        forbidden |= radio_packages
        forbidden.add('wpad-openssl')
    elif args.preset in ('mt7981', 'mt7986'):
        soc = args.preset
        required |= {'kmod-mt7915e', 'kmod-' + soc + '-firmware', soc + '-wo-firmware', 'wpad-openssl'}
    return required, forbidden

# Per-device rootfs selects default drivers as modules for the image builder.
# They still must exist in the config; each final manifest must contain them.
for device in devices:
    required, forbidden = requirements(device)
    check_packages(packages, required, forbidden if len(devices) == 1 else (), 'config/' + device)

if args.preset in ('mt7981', 'mt7986'):
    image = (ROOT / 'target/linux/mediatek/image/filogic.mk').read_text()
    blocks = dict(re.findall(r'^define Device/([^\n]+)\n(.*?)^endef', image, re.M | re.S))
    def expand(name, seen=()):
        if name in seen:
            raise ValueError('recursive Device/' + name)
        block = blocks.get(name, '')
        inherited = ''.join(expand(parent, seen + (name,)) for parent in re.findall(r'\$\(call Device/([^),]+)', block))
        return inherited + '\n' + block
    for device in devices:
        block = expand(device)
        identifiers = re.findall(r'^\s*(?:SOC|DEVICE_DTS)\s*:?=\s*(.+)', block, re.M)
        if not any(args.preset in ident for ident in identifiers):
            fail('Device/' + device + ' does not identify ' + args.preset + ' in its DTS/SOC')
    if args.preset == 'mt7981' and 'mt7981_eeprom_mt7976_dbdc.bin' not in (ROOT / 'package/kernel/mt76/Makefile').read_text():
        fail('MT7981 fallback EEPROM missing from mt76 firmware install recipe')
    if 'clx_s20m' in devices:
        dts = (ROOT / 'target/linux/mediatek/dts/mt7986a-clx-s20m.dts').read_text()
        for node in (r'&wifi\s*', r'gmac1:\s*mac@1\s*'):
            if not re.search(node + r'\{[^}]*status\s*=\s*"disabled"', dts, re.S):
                fail('S20M must disable WiFi and the external 2.5G MAC')

if args.preset in ('cs06', 'be6500') and values.get('PACKAGE_MAC80211_DEBUGFS') != 'y':
    fail('ath12k PPE-DS requires MAC80211_DEBUGFS')
if args.preset in ('cs02', 'cs02-gwrt2'):
    image = (ROOT / 'target/linux/qualcommax/image/ipq60xx.mk').read_text()
    blocks = dict(re.findall(r'^define Device/([^\n]+)\n(.*?)^endef', image, re.M | re.S))
    for device in devices:
        block = blocks.get(device, '')
        size = re.search(r'^\s*KERNEL_SIZE\s*:?=\s*([^\s]+)', block, re.M)
        if not size or size.group(1) != '12288k':
            fail('Device/' + device + ' must retain its recorded 12288k CS-02 layout')
if 'daed' in packages:
    check_packages(packages, {'kmod-sched-bpf', 'kmod-xdp-sockets-diag'}, (), 'daed')
    if values.get('aarch64') != 'y':
        fail('the selected prebuilt daed binary requires aarch64')
    if values.get('KERNEL_DEBUG_INFO_BTF') != 'y' and 'vmlinux-btf' not in packages:
        fail('daed needs kernel BTF or vmlinux-btf')

if args.manifests:
    manifests = list(args.manifests.rglob('*.manifest'))
    profiles_file = next(args.manifests.rglob('profiles.json'), None)
    profiles = {}
    if profiles_file:
        profiles = json.loads(profiles_file.read_text()).get('profiles', {})
    for device in devices:
        matching = [m for m in manifests if m.name.endswith('-' + device + '.manifest')]
        required, forbidden = requirements(device)
        # Reject radio packages even if a config forgot to select them.
        if device in ('jdcloud_re-cs-07', 'jdcloud_re-cs-08', 'clx_s20m'):
            forbidden |= {p for p in packages if p.startswith(('kmod-ath11k', 'ath11k-firmware-', 'kmod-ath12k', 'ath12k-firmware-', 'kmod-mt79'))}

        if matching:
            for manifest in matching:
                installed = {line.split()[0] for line in manifest.read_text().splitlines() if line.strip()}
                check_packages(installed, required, forbidden, manifest.name)
                if 'daed' in packages:
                    check_packages(installed, {'daed', 'kmod-sched-bpf'}, (), manifest.name)
            continue

        # Multi-profile targets share a rootfs manifest; profiles.json records
        # each device's built images and package additions/removals.
        profile = profiles.get(device)
        if not profile:
            fail('no image manifest or profiles.json entry produced for ' + device)
            continue
        images = profile.get('images', [])
        if not images:
            fail('no firmware images recorded for ' + device)
            continue
        for image in images:
            if not (profiles_file.parent / image['name']).is_file():
                fail('image listed for ' + device + ' is missing: ' + image['name'])

        base_manifests = [m for m in manifests if m not in matching]
        if not base_manifests:
            fail('no shared package manifest produced for ' + device)
            continue
        installed = {line.split()[0] for manifest in base_manifests
                     for line in manifest.read_text().splitlines() if line.strip()}
        device_packages = set(profile.get('device_packages', []))
        installed -= {p[1:] for p in device_packages if p.startswith('-')}
        installed |= {p for p in device_packages if not p.startswith('-')}
        check_packages(installed, required, forbidden, device)
        if 'daed' in packages:
            check_packages(installed, {'daed', 'kmod-sched-bpf'}, (), device)

if errors:
    raise SystemExit('\n'.join('FAIL: ' + error for error in errors))
print('PASS: ' + args.preset + ': ' + ', '.join(devices) + ('; final manifests verified' if args.manifests else '; drivers and firmware selected'))
