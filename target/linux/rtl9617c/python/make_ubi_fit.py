#!/usr/bin/env python3
"""Wrap an OpenWrt kernel Image and DTB into the TYFZA1 stock-U-Boot FIT.

The stock bootloader loads a FIT (max 0x600000 bytes) whose script picks the
UBI root slot from the CRC-verified OEM selector.  Signing is optional: when a
key directory is supplied the image is signed with the host mkimage, otherwise
an unsigned FIT is emitted and the caller is warned.
"""
import argparse
import json
import lzma
import shutil
import subprocess
import sys
from pathlib import Path

BASE_ARGS = ('earlycon console=ttyS0,115200n8 loglevel=8 ignore_loglevel '
             'clk_ignore_unused maxcpus=4')

BOOT_SCRIPT = '''if test "${root_mtd}" = "31:12"; then
    setenv tyfza1_slot 1
    setenv tyfza1_root ubi_r1
    setenv tyfza1_block /dev/ubiblock0_7
else
    setenv tyfza1_slot 0
    setenv tyfza1_root ubi_r0
    setenv tyfza1_block /dev/ubiblock0_4
fi
setenv bootargs "@BASE_ARGS@ ubi.mtd=ubi_device ubi.block=0,${tyfza1_root} root=${tyfza1_block} rootfstype=squashfs ro tyfza1.slot=${tyfza1_slot}"


if test -z "${b_conf}" && test -n "${conf_match}"; then
    run conf_match
fi
if test -n "${b_conf}"; then
    bootm ${unzip_src}#${b_conf}
else
    bootm ${unzip_src}
fi
'''


def compress(data, parameters):
    return lzma.compress(data, format=lzma.FORMAT_ALONE, filters=[{
        'id': lzma.FILTER_LZMA1,
        'dict_size': parameters['dictionary_bytes'],
        'lc': parameters['lc'], 'lp': parameters['lp'], 'pb': parameters['pb'],
    }])


def make_its(load, entry, fdt_load, kver, signed, board_variants):
    signature = ('signature { algo = "sha256,rsa2048"; key-name-hint = "dev"; };'
                 if signed else '')
    config_signature = ('signature { algo = "sha256,rsa2048"; key-name-hint = "dev"; '
                        'sign-images = "fdt", "kernel", "script"; };' if signed else '')
    label = 'SIGNED' if signed else 'UNSIGNED'
    its = f'''/dts-v1/;
/ {{
    description = "TYFZA1 native {label} boot-contract candidate";
    #address-cells = <1>;
    images {{
        kernel {{
            description = "Native OpenWrt Linux {kver}";
            data = /incbin/("kernel.lzma");
            type = "kernel"; arch = "arm64"; os = "linux";
            compression = "lzma"; load = <{load:#x}>; entry = <{entry:#x}>;
            hash {{ algo = "sha256"; }};
            {signature}
        }};
        fdt-dts {{
            data = /incbin/("fdt.lzma");
            type = "flat_dt"; arch = "arm64";
            compression = "lzma"; load = <{fdt_load:#x}>;
            hash {{ algo = "sha256"; }};
            {signature}
        }};
        script {{
            data = /incbin/("boot.cmd");
            type = "script"; compression = "none";
            hash {{ algo = "sha256"; }};
            {signature}
        }};
    }};
    configurations {{
        default = "conf-dts";
        conf-dts {{ compatible = "realtek,taurus"; kernel = "kernel"; fdt = "fdt-dts"; script = "script"; {config_signature} }};
    }};
}};
'''
    if board_variants:
        fdt = f'''        fdt-2p5g {{
            data = /incbin/("fdt-2p5g.lzma");
            type = "flat_dt"; arch = "arm64";
            compression = "lzma"; load = <{fdt_load:#x}>;
            hash {{ algo = "sha256"; }};
            {signature}
        }};
'''
        its = its.replace('        script {', fdt + '        script {')
        its = its.replace('default = "conf-dts";', 'default = "conf-0";')
        its = its.replace('        conf-dts {',
                          '        conf-0 { compatible = "realtek,taurus"; kernel = "kernel"; '
                          'fdt = "fdt-2p5g"; script = "script"; ' + config_signature + ' };\n'
                          '        conf-1 {')
    return its


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('dtb', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--dtb-2p5g', type=Path, required=True)
    parser.add_argument('--keys', type=Path, default=None)
    parser.add_argument('--kver', default='6.18')
    parser.add_argument('--mkimage', default=None)
    args = parser.parse_args()

    kernel = args.image.read_bytes()
    if len(kernel) < 64 or kernel.startswith(b'\x7fELF') or kernel[56:60] != b'ARM\x64':
        sys.exit(f'make_ubi_fit: {args.image} is not a raw ARM64 Linux Image')

    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    contract = json.loads((Path(__file__).resolve().parent /
                           'tyfza1-fit-compression.json').read_text())
    parameters = {item['name']: item['lzma_alone'] for item in contract['images']}

    compressed_kernel = compress(kernel, parameters['kernel'])
    (out / 'kernel.lzma').write_bytes(compressed_kernel)
    (out / 'fdt.lzma').write_bytes(compress(args.dtb.read_bytes(), parameters['fdt-dts']))
    (out / 'fdt-2p5g.lzma').write_bytes(
        compress(args.dtb_2p5g.read_bytes(), parameters['fdt-dts']))
    # Leave every ${...} variable for U-Boot to expand at boot time.
    (out / 'boot.cmd').write_text(BOOT_SCRIPT.replace('@BASE_ARGS@', BASE_ARGS))

    signed = args.keys is not None and (args.keys / 'dev.key').exists()
    mkimage = args.mkimage or shutil.which('mkimage')
    if signed and not mkimage:
        sys.exit('make_ubi_fit: key directory present but mkimage is not installed')

    (out / 'image.its').write_text(make_its(0x200000, 0x200000, 0x2000000,
                                            args.kver, signed=signed,
                                            board_variants=True))
    if signed:
        subprocess.run([mkimage, '-f', 'image.its', '-k', str(args.keys.resolve()),
                        'image.itb'], cwd=out, check=True, stdout=subprocess.DEVNULL)
        print('make_ubi_fit: signed FIT')
    else:
        if not mkimage:
            mkimage = str(Path(args.mkimage or 'mkimage'))
        subprocess.run([mkimage, '-f', 'image.its', 'image.itb'],
                       cwd=out, check=True, stdout=subprocess.DEVNULL)
        print('make_ubi_fit: UNSIGNED FIT (no key directory supplied)', file=sys.stderr)

    size = (out / 'image.itb').stat().st_size
    print(f'make_ubi_fit: Image={len(kernel)} bytes, LZMA={len(compressed_kernel)} bytes, '
          f'FIT={size} bytes, limit={0x600000} bytes', flush=True)
    if size > 0x600000:
        sys.exit(f'make_ubi_fit: FIT is {size} bytes; stock U-Boot reads at most 0x600000')


if __name__ == '__main__':
    main()
