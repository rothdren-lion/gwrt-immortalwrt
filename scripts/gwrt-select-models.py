#!/usr/bin/env python3
"""Limit an existing preset to explicitly selected device profiles."""
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
wanted = set(re.split(r'[\s,]+', sys.argv[2].strip())) - {''}
if not wanted or any(not re.fullmatch(r'[A-Za-z0-9_.-]+', name) for name in wanted):
    raise SystemExit('model list must contain device profile names separated by spaces or commas')
source = config.read_text()
pattern = re.compile(r'^(CONFIG_TARGET_DEVICE_\w+_DEVICE_([A-Za-z0-9_.-]+))=y$', re.M)
selected = {match.group(2) for match in pattern.finditer(source)}
if wanted - selected:
    raise SystemExit('models absent from the original preset: ' + ', '.join(sorted(wanted - selected)))
config.write_text(pattern.sub(lambda match: match[0] if match[2] in wanted else '# ' + match[1] + ' is not set', source))
print('selected models: ' + ', '.join(sorted(wanted)))
