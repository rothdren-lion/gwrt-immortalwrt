#!/usr/bin/env python3
"""Audit the actual JDC image DTB, 12M layout and repaired application payload."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ss01_audit', ROOT / 'scripts/gwrt-verify-ss01-image.py')
ss01 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss01)
require, fdt_nodes, enabled = ss01.require, ss01.fdt_nodes, ss01.enabled
DEVICES = {'ss01': 'jdcloud_re-ss-01', 'cs02': 'jdcloud_re-cs-02',
           'cs02-gwrt2': 'jdcloud_re-cs-02-gwrt2', 'cs07': 'jdcloud_re-cs-07'}


def verify_factory_rootfs(factory, rootfs, offset):
    """Compare the SquashFS payload and its permitted sysupgrade alignment."""
    with rootfs.open('rb') as image:
        header = image.read(96)
        require(len(header) == 96 and header[:4] == b'hsqs', 'invalid sysupgrade SquashFS')
        fs_size, = struct.unpack_from('<Q', header, 40)
        image_size = rootfs.stat().st_size
        require(96 <= fs_size <= image_size, 'invalid SquashFS size')
        # IMAGE_ROOTFS is built with mksquashfs -nopad. sysupgrade-tar.sh
        # pads it to 1 KiB, while factory appends metadata after the raw image.
        require(image_size % 1024 == 0, 'sysupgrade rootfs is not 1 KiB aligned')
        require(image_size - fs_size < 1024, 'unexpected sysupgrade rootfs padding')
        image.seek(0)
        factory.seek(offset)
        remaining = fs_size
        while remaining:
            size = min(1024 * 1024, remaining)
            require(factory.read(size) == image.read(size),
                    'factory rootfs differs from sysupgrade at 12M')
            remaining -= size
        require(not any(image.read()), 'sysupgrade rootfs padding is not zero')
    print(f'PASS factory rootfs at {offset} bytes; SquashFS={fs_size}, sysupgrade padding={image_size - fs_size}')


def verify_dtb(blob, preset):
    nodes = fdt_nodes(blob)
    compatible = DEVICES[preset].replace('jdcloud_', 'jdcloud,').encode()
    require(compatible in nodes['/'].get('compatible', b'').split(b'\0'), 'wrong DTB board')

    def active(compat):
        matches = []
        for path, node in nodes.items():
            if compat not in node.get('compatible', b'').split(b'\0'):
                continue
            parents = [path]
            while parents[-1] != '/':
                parents.append(parents[-1].rsplit('/', 1)[0] or '/')
            if all(enabled(nodes[parent]) for parent in parents):
                matches.append(node)
        return matches

    require(len(active(b'qualcomm,ipq6018-ppe')) == 1, 'missing DSA PPE switch')
    require(len(active(b'qualcomm,ipq6018-edma')) == 1, 'missing DSA EDMA dataplane')
    require(not active(b'qcom,nss-dp'), 'NSS dataplane must not coexist with DSA')
    ports = {int.from_bytes(n['reg'], 'big'): n['label'].rstrip(b'\0').decode()
             for path, n in nodes.items() if '/ports/port@' in path and 'label' in n and 'reg' in n}
    wanted = {1: 'wan', 2: 'lan1', 3: 'lan2', 4: 'lan3'} if preset == 'cs07' else {
        1: 'lan1', 2: 'lan2', 3: 'lan3', 4: 'lan4', 5: 'wan'}
    require(ports == wanted, 'DTB port map differs from the source DTS: ' + repr(ports))
    require(bool(active(b'qcom,ipq6018-wifi')) == (preset != 'cs07'), 'incorrect integrated radio state')
    require(bool(active(b'pci17cb,1104')) == (preset != 'cs07'), 'incorrect PCI radio state')
    print('PASS DTB identity, DSA PPE/EDMA, port map and radio state:', DEVICES[preset])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', type=Path)
    parser.add_argument('preset', choices=DEVICES)
    parser.add_argument('--dtb', action='store_true', help='verify a standalone compiled DSA DTB')
    args = parser.parse_args()
    if args.dtb:
        require(args.preset != 'ss01', 'SS-01 uses the NSS image verifier')
        verify_dtb(args.target.read_bytes(), args.preset)
        return
    if args.preset == 'ss01':
        subprocess.run(['python3', str(ROOT / 'scripts/gwrt-verify-ss01-image.py'), str(args.target)], check=True)
        return
    device = DEVICES[args.preset]
    profiles = json.loads((args.target / 'profiles.json').read_text())['profiles']
    require(set(profiles) == {device}, 'unexpected device profiles')
    images = {image['type']: image for image in profiles[device]['images']
              if image['type'] in ('sysupgrade', 'factory')}
    require(set(images) == {'sysupgrade', 'factory'}, 'missing factory/sysupgrade image')
    for image in images.values():
        path = args.target / image['name']
        require(hashlib.sha256(path.read_bytes()).hexdigest() == image['sha256'], 'image SHA256 mismatch: ' + path.name)
    with tempfile.TemporaryDirectory(prefix='gwrt-ipq60xx-audit-') as temporary:
        rootfs = Path(temporary) / 'root.squashfs'
        with tarfile.open(args.target / images['sysupgrade']['name']) as archive:
            kernels = [m for m in archive.getmembers() if m.isfile() and m.name.endswith('/kernel')]
            roots = [m for m in archive.getmembers() if m.isfile() and m.name.endswith('/root')]
            require(len(kernels) == len(roots) == 1, 'invalid sysupgrade members')
            kernel = archive.extractfile(kernels[0]).read()
            rootfs.write_bytes(archive.extractfile(roots[0]).read())
        limit = 12288 * 1024
        require(len(kernel) <= limit, 'kernel exceeds 12M HLOS layout')
        with (args.target / images['factory']['name']).open('rb') as factory:
            require(factory.read(len(kernel)) == kernel, 'factory/sysupgrade kernel mismatch')
            verify_factory_rootfs(factory, rootfs, limit)
        fit = fdt_nodes(kernel)
        blobs = [n['data'] for n in fit.values() if n.get('type') == b'flat_dt\0']
        require(len(blobs) == 1, 'expected one embedded DTB')
        verify_dtb(blobs[0], args.preset)
        candidates = [ROOT / 'staging_dir/host/bin/unsquashfs4', ROOT / 'staging_dir/host/bin/unsquashfs']
        reader = next((str(p) for p in candidates if p.is_file()), shutil.which('unsquashfs'))
        require(reader is not None, 'missing squashfs reader')
        def read(name):
            return subprocess.check_output([reader, '-cat', str(rootfs), name])
        listing = subprocess.check_output([reader, '-ll', str(rootfs)], text=True)
        if args.preset == 'cs07':
            require(not re.search(r'/(?:ath11k[^/]*\.ko[^/]*|wpad|iw|athena-led)\s*$', listing, re.M),
                    'wireless or Athena component installed on wired CS-07')
        for module in ('qca_ppe', 'qca_edma'):
            require(re.search(r'/' + module + r'\.ko(?:\s|$|\.)', listing), 'missing Ethernet module: ' + module)
        require(not re.search(r'/(?:qca-nss-dp|qca-ssdk)\.ko(?:\s|$|\.)', listing), 'NSS/SSDK modules present in DSA image')
        marker = b'daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1'
        require(read('usr/share/daed/gwrt-runtime-version').strip() == marker, 'wrong daed repair version')
        daemon = read('usr/bin/daed')
        require(daemon[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', daemon, 18)[0] == 183 and marker in daemon,
                'wrong daed ARM64 executable')
        require(not re.search(r'/etc/init\.d/homeproxy\s*$', listing, re.M), 'HomeProxy remains installed')
        theme = ROOT / 'gwrt-theme-V3/theme/luci-theme-gwrt'
        for installed, source in {
            'www/luci-static/gwrt/css/cascade.css': 'htdocs/luci-static/gwrt/css/cascade.css',
            'usr/libexec/gwrt-clients-dump': 'root/usr/libexec/gwrt-clients-dump',
            'usr/share/gwrt/clients.sh': 'root/usr/share/gwrt/clients.sh',
            'usr/share/ucode/luci/template/admin_status/index_gwrt.ut': 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut',
        }.items():
            require(read(installed) == (theme / source).read_bytes(), 'packaged theme source mismatch: ' + installed)
        for name in ('gwrt-mesh-apmode', 'gwrt-mesh-led', 'gwrt-wifiroam-autopair'):
            require(re.search(r'/etc/init\.d/' + name + r'\s*$', listing, re.M), 'missing Mesh service: ' + name)
        print('PASS 12M factory/sysupgrade, DSA modules, daed runtime1, current theme and Mesh:', device)


if __name__ == '__main__':
    main()
