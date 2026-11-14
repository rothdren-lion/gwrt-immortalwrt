#!/usr/bin/env python3
"""Verify the compiled CS-06 kernel, excluding toolchain header trees."""
import argparse
from pathlib import Path
import shutil


VERSION = '6.18.62'
SETTINGS = ('CONFIG_ARM64=y', 'CONFIG_CMA=y', 'CONFIG_DMA_CMA=y',
            'CONFIG_CMA_SIZE_SEL_MBYTES=y', 'CONFIG_CMA_SIZE_MBYTES=64')


def verify_kernel(build_dir):
    candidates = sorted(path for path in build_dir.glob(
        'target-aarch64*/linux-qualcommbe_ipq53xx/linux-*') if path.is_dir())
    if len(candidates) != 1:
        raise ValueError('expected exactly one CS-06 target kernel; found: ' +
                         (', '.join(map(str, candidates)) or 'none'))
    kernel = candidates[0]
    print('CS-06 target kernel:', kernel, flush=True)
    if kernel.name != 'linux-' + VERSION:
        raise ValueError(f'expected Linux {VERSION}, found {kernel.name}')
    config = kernel / '.config'
    settings = set(config.read_text().splitlines())
    for setting in SETTINGS:
        if setting not in settings:
            key = setting.split('=', 1)[0]
            actual = next((line for line in sorted(settings)
                           if line.startswith(key + '=') or
                           line == '# ' + key + ' is not set'), 'missing')
            raise ValueError(f'{config}: expected {setting}; actual: {actual}')
        print('PASS', setting)
    release = kernel / 'include/config/kernel.release'
    if release.read_text().strip() != VERSION:
        raise ValueError(f'{release}: expected compiled release {VERSION}')
    print('PASS compiled kernel release:', VERSION)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_dir', type=Path)
    parser.add_argument('--output', required=True, type=Path,
                        help='save the verified target kernel configuration')
    args = parser.parse_args()
    try:
        config = verify_kernel(args.build_dir)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(config, args.output)
    except (OSError, ValueError) as exc:
        parser.exit(1, f'FAIL CS-06 target kernel: {exc}\n')


if __name__ == '__main__':
    main()
