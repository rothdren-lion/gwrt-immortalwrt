#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
collector = root / 'scripts/gwrt-collect-firmware.py'

with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    profiles_dir = base / 'targets/mediatek/filogic'
    profiles_dir.mkdir(parents=True)
    image_types = {
        'board-a-factory.bin': 'factory',
        'board-a-sysupgrade.bin': 'sysupgrade',
        'board-a-initramfs.itb': 'initramfs',
        'board-b-sysupgrade.itb': 'sysupgrade',
    }
    images = []
    for name, image_type in image_types.items():
        (profiles_dir / name).write_bytes(b'test image')
        images.append((name, image_type))

    (profiles_dir / 'profiles.json').write_text(json.dumps({
        'profiles': {
            'board-a': {'images': [
                {'name': name, 'type': image_type}
                for name, image_type in images if name.startswith('board-a-')
            ]},
            'board-b': {'images': [
                {'name': 'board-b-sysupgrade.itb', 'type': 'sysupgrade'},
            ]},
        },
    }))
    output = base / 'out'
    subprocess.run([
        'python3', str(collector), '--profiles', str(profiles_dir),
        '--mode', 'flashable', '--output', str(output),
    ], check=True)
    actual = {path.name for path in output.iterdir()}
    expected = {
        'board-a-factory.bin',
        'board-a-sysupgrade.bin',
        'board-b-sysupgrade.itb',
    }
    assert actual == expected, (actual, expected)

print('PASS: factory and sysupgrade images only')
