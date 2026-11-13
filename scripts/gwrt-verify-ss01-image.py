#!/usr/bin/env python3
"""Verify SS-01's shipped CSS, Ethernet DTB/modules, and factory layout."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)


def fdt_nodes(data):
    magic, total, position, strings = struct.unpack_from('>4I', data)
    require(magic == 0xd00dfeed and total <= len(data), 'invalid FIT/DTB')
    nodes, stack = {}, []
    while position < total:
        token, = struct.unpack_from('>I', data, position)
        position += 4
        if token == 1:
            end = data.index(b'\0', position)
            stack.append(data[position:end].decode())
            position = (end + 4) & ~3
            nodes['/' + '/'.join(stack[1:])] = {}
        elif token == 2:
            stack.pop()
        elif token == 3:
            size, name_offset = struct.unpack_from('>2I', data, position)
            position += 8
            name_start = strings + name_offset
            name = data[name_start:data.index(b'\0', name_start)].decode()
            nodes['/' + '/'.join(stack[1:])][name] = data[position:position + size]
            position = (position + size + 3) & ~3
        elif token == 9:
            return nodes
        else:
            require(token == 4, 'unexpected FDT token')
    raise SystemExit('FAIL: incomplete FDT')


def enabled(node):
    return node.get('status', b'okay\0') in (b'okay\0', b'ok\0')


def verify_dtb(kernel):
    images = fdt_nodes(kernel)
    blobs = [node['data'] for name, node in images.items()
             if name.startswith('/images/') and node.get('type') == b'flat_dt\0']
    require(len(blobs) == 1, 'expected one embedded SS-01 DTB')
    nodes = fdt_nodes(blobs[0])
    require(nodes['/'].get('model') == b'JDCloud RE-SS-01\0', 'wrong DTB model')
    require(b'jdcloud,re-ss-01' in nodes['/'].get('compatible', b'').split(b'\0'), 'wrong DTB compatible')
    for compatible in (b'qcom,ess-switch-ipq60xx', b'qcom,edma'):
        matches = [node for node in nodes.values()
                   if compatible in node.get('compatible', b'').split(b'\0') and enabled(node)]
        require(len(matches) == 1, 'missing enabled ' + compatible.decode())
    for port, label in ((2, 'lan1'), (3, 'lan2'), (4, 'lan3'), (5, 'wan')):
        matches = [node for name, node in nodes.items()
                   if name.rsplit('/', 1)[-1] == 'dp' + str(port)]
        require(len(matches) == 1, 'missing unique dp port: ' + label)
        node = matches[0]
        require(node.get('compatible') == b'qcom,nss-dp\0' and enabled(node)
                and node.get('label') == label.encode() + b'\0', 'incorrect dp port: ' + label)
    print('PASS embedded DTB: JDCloud RE-SS-01; ESS, EDMA, dp2=lan1 dp3=lan2 dp4=lan3 dp5=wan')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    profiles = json.loads((args.target / 'profiles.json').read_text())['profiles']
    require(set(profiles) == {'jdcloud_re-ss-01'}, 'unexpected device profiles')
    images = profiles['jdcloud_re-ss-01']['images']
    selected = {image['type']: args.target / image['name'] for image in images
                if image['type'] in ('sysupgrade', 'factory')}
    require(set(selected) == {'sysupgrade', 'factory'}, 'missing factory/sysupgrade image')
    for image in images:
        if image['type'] not in selected:
            continue
        path = args.target / image['name']
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        require(digest == image['sha256'], 'image SHA256 mismatch: ' + path.name)
        print('PASS image SHA256:', digest, path.name)
    with tempfile.TemporaryDirectory(prefix='gwrt-ss01-image-') as temp:
        rootfs = Path(temp) / 'root.squashfs'
        with tarfile.open(selected['sysupgrade']) as archive:
            kernels = [m for m in archive.getmembers() if m.isfile() and m.name.endswith('/kernel')]
            roots = [m for m in archive.getmembers() if m.isfile() and m.name.endswith('/root')]
            require(len(kernels) == len(roots) == 1, 'invalid sysupgrade members')
            kernel = archive.extractfile(kernels[0]).read()
            rootfs.write_bytes(archive.extractfile(roots[0]).read())
        block = re.search(r'^define Device/jdcloud_re-ss-01\n(.*?)^endef',
                          (ROOT / 'target/linux/qualcommax/image/ipq60xx.mk').read_text(), re.M | re.S).group(1)
        size = re.search(r'KERNEL_SIZE\s*:=\s*(\d+)k', block)
        require(size is not None, 'missing explicit SS-01 kernel layout')
        limit = int(size.group(1)) * 1024
        require(len(kernel) <= limit, 'kernel exceeds HLOS layout')
        with selected['factory'].open('rb') as factory:
            require(factory.read(len(kernel)) == kernel, 'factory kernel differs from sysupgrade')
            factory.seek(limit)
            require(factory.read(4) == b'hsqs', 'wrong factory rootfs offset')
        print(f'PASS layout: KERNEL_SIZE={size.group(1)}k; kernel={len(kernel)} rootfs={rootfs.stat().st_size}')
        verify_dtb(kernel)
        candidates = [ROOT / 'staging_dir/host/bin/unsquashfs4',
                      ROOT / 'staging_dir/host/bin/unsquashfs']
        unsquashfs = next((str(path) for path in candidates if path.is_file()),
                         shutil.which('unsquashfs'))
        require(unsquashfs is not None, 'missing host unsquashfs4/unsquashfs')
        print('Using squashfs reader:', unsquashfs)
        def read_file(name):
            return subprocess.check_output([str(unsquashfs), '-cat', str(rootfs), name])
        theme = ROOT / 'gwrt-theme-V3/theme/luci-theme-gwrt'
        checks = {'www/luci-static/gwrt/css/cascade.css': 'htdocs/luci-static/gwrt/css/cascade.css',
                  'usr/libexec/gwrt-socinfo': 'root/usr/libexec/gwrt-socinfo'}
        template = 'usr/share/ucode/luci/template/'
        for name in ('header', 'header_login', 'footer', 'footer_login'):
            checks[template + 'themes/gwrt/' + name + '.ut'] = 'root/' + template + 'themes/gwrt/' + name + '.ut'
        checks[template + 'admin_status/index_gwrt.ut'] = 'root/' + template + 'admin_status/index_gwrt.ut'
        for name in ('gwrt-runtime-dir', 'gwrt-clients-dump', 'gwrt-coremark', 'gwrt-ota'):
            checks['usr/libexec/' + name] = 'root/usr/libexec/' + name
        for name in ('clients.sh', 'clients-merge.awk'):
            checks['usr/share/gwrt/' + name] = 'root/usr/share/gwrt/' + name
        checks['usr/share/rpcd/acl.d/luci-theme-gwrt.json'] = 'root/usr/share/rpcd/acl.d/luci-theme-gwrt.json'
        for installed, source in checks.items():
            content = read_file(installed)
            require(content == (theme / source).read_bytes(), 'packaged theme differs: ' + installed)
            print('PASS packaged file:', hashlib.sha256(content).hexdigest(), installed)
        require(b'qca-nss-dp' in read_file('etc/modules.d/31-qca-nss-dp'), 'missing dataplane autoload')
        listing = subprocess.check_output([str(unsquashfs), '-ll', str(rootfs)], text=True)
        manifests = list(args.target.glob('*.manifest'))
        require(re.search(r'/qca-nss-dp\.ko(?:\s|$|\.)', listing), 'missing dataplane module')
        require(re.search(r'/qca-ssdk\.ko(?:\s|$|\.)', listing), 'missing SSDK module')
        # SS-01 must keep the GWRT mesh stack; the NSS-only seed regression shipped
        # only gwrt-agent and silently dropped pairing / AP mode / first-boot defaults.
        mesh_files = {
            'etc/uci-defaults/95_gwrt-wifi-defaults': 'first-boot wireless defaults',
            'etc/uci-defaults/96_gwrt-preset-apk': 'offline mesh installer',
            'etc/uci-defaults/97_gwrt-wifiroam-defaults': 'wifiroam defaults',
            'usr/libexec/gwrt-ss01-firstboot': 'SS-01 deferred first-boot worker',
            'etc/init.d/gwrt-wifiroam-autopair': 'wifiroam autopair service',
            'usr/libexec/gwrt-wifiroam-autopair': 'wifiroam autopair daemon',
            'usr/share/gwrt/wifiroam/wifiroamd.uc': 'wifiroam daemon',
            'usr/libexec/gwrt-mesh-apmode': 'mesh AP-mode helper',
            'usr/libexec/gwrt-mesh-led': 'mesh LED helper',
            'usr/libexec/gwrt-mesh-pair': 'mesh pairing helper',
        }
        for installed, label in mesh_files.items():
            require(re.search(r'/' + re.escape(installed) + r'\s*$', listing, re.M),
                    'missing ' + label + ': ' + installed)
        for prefix in ('wifiroam-', 'luci-app-wifiroam-', 'luci-i18n-wifiroam-'):
            require(re.search(r'/usr/share/gwrt/apk/' + prefix + r'[^/\s]*\.apk\s*$', listing, re.M),
                    'missing offline mesh APK: ' + prefix)
        # Assert the packaged scripts match the sources tested before the build.
        firstboot_sources = {
            'etc/uci-defaults/95_gwrt-wifi-defaults': 'package/gwrt-device-defaults/files/95_gwrt-wifi-defaults',
            'etc/uci-defaults/96_gwrt-preset-apk': 'package/gwrt-device-defaults/files/96_gwrt-preset-apk',
            'etc/uci-defaults/97_gwrt-wifiroam-defaults': 'package/gwrt-device-defaults/files/97_gwrt-wifiroam-defaults',
            'usr/libexec/gwrt-ssid-name': 'package/gwrt-device-defaults/files/gwrt-ssid-name',
            'usr/libexec/gwrt-ss01-firstboot': 'package/gwrt-device-defaults/files/gwrt-ss01-firstboot',
            'usr/libexec/gwrt-wifiroam-autopair': 'package/gwrt-device-defaults/files/gwrt-wifiroam-autopair',
            'etc/hotplug.d/ieee80211/10-wifi-detect': 'package/network/config/wifi-scripts/files/etc/hotplug.d/ieee80211/10-wifi-detect',
            'etc/hotplug.d/ieee80211/30-gwrt-ssid-name': 'gwrt-theme-V3/theme/luci-theme-gwrt/root/etc/hotplug.d/ieee80211/30-gwrt-ssid-name',
            'etc/init.d/gwrt-caldata': 'target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata',
            'usr/share/gwrt/wifiroam/wifiroamd.uc': 'package/gwrt-device-defaults/files/wifiroam/wifiroamd.uc',
        }
        for installed, source in firstboot_sources.items():
            require(read_file(installed) == (ROOT / source).read_bytes(),
                    'packaged first-boot script differs: ' + installed)
        for section in ('gwrt-mesh-apmode', 'gwrt-mesh-led'):
            require(re.search(r'/etc/init\.d/' + section + r'\s*$', listing, re.M),
                    'missing mesh init: ' + section)
        manifest_text = '\n'.join(p.read_text() for p in manifests)
        for package in ('gwrt-agent', 'gwrt-device-defaults', 'gwrt-mesh-apmode', 'gwrt-mesh-led'):
            require(re.search(r'^' + package + r'\s+-\s+', manifest_text, re.M),
                    'missing mesh package in manifest: ' + package)
        print('PASS SS-01 packaged mesh stack and first-boot defaults')
        require(any(re.search(r'^luci-theme-gwrt\s+-\s+1\.0-r117\s*$', p.read_text(), re.M)
                    for p in manifests), 'wrong theme package release')
        print('PASS SS-01 packaged theme r117 and Ethernet modules')


if __name__ == '__main__':
    main()
