#!/usr/bin/env python3
"""Collect only the requested firmware image types from OpenWrt metadata."""
import argparse
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profiles', type=Path, required=True,
                    help='profiles.json file or bin/targets directory')
parser.add_argument('--mode', choices=('flashable',), required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()

if args.profiles.is_file():
    profiles_file = args.profiles
else:
    matches = list(args.profiles.rglob('profiles.json'))
    if len(matches) != 1:
        raise SystemExit(f'expected one profiles.json under {args.profiles}, found {len(matches)}')
    profiles_file = matches[0]

profiles = json.loads(profiles_file.read_text()).get('profiles', {})
if not profiles:
    raise SystemExit(f'no device profiles in {profiles_file}')

allowed = {'factory', 'sysupgrade'}
selected = {}
for device, profile in profiles.items():
    images = [image for image in profile.get('images', []) if image.get('type') in allowed]
    if not any(image.get('type') == 'sysupgrade' for image in images):
        raise SystemExit(f'no sysupgrade image recorded for {device}')
    for image in images:
        name = image['name']
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise SystemExit(f'unsafe image path in profiles.json: {name}')
        source = profiles_file.parent / relative
        if not source.is_file():
            raise SystemExit(f'image listed for {device} is missing: {source}')
        artifact_name = relative.name
        if artifact_name in selected and selected[artifact_name] != source:
            raise SystemExit(f'image basename collision in profiles.json: {artifact_name}')
        selected[artifact_name] = source

args.output.mkdir(parents=True, exist_ok=True)
for name, source in sorted(selected.items()):
    shutil.copy2(source, args.output / name)
print(f'Collected {len(selected)} factory/sysupgrade firmware image(s) for {len(profiles)} profile(s)')
