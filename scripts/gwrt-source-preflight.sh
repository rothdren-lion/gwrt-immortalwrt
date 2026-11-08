#!/bin/sh
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$top"
sh gwrt-theme-V3/scripts/integrate.sh --check --no-config

python3 - <<'PY'
from pathlib import Path
import json
import re
import subprocess
theme = Path('gwrt-theme-V3/theme/luci-theme-gwrt')
roots = [theme, Path('gwrt-overlays'), Path('package/gwrt-agent'),
         Path('package/gwrt-device-defaults'), Path('package/gwrt-mesh-apmode'), Path('package/gwrt-mesh-led')]
counts = dict(js=0, shell=0, json=0)
for root in roots:
    for path in root.rglob('*'):
        if not path.is_file():
            continue
        if path.suffix in ('.bak', '.orig', '.rej', '.swp') or '.bak-' in path.name:
            raise SystemExit('shipping backup residue: ' + str(path))
        if path.suffix == '.js' and not path.name.endswith('.min.js'):
            subprocess.run(['node', '--check', str(path)], check=True)
            counts['js'] += 1
        elif path.suffix == '.json':
            json.loads(path.read_text())
            counts['json'] += 1
        elif path.read_bytes()[:20].startswith(b'#!/bin/sh'):
            subprocess.run(['sh', '-n', str(path)], check=True)
            counts['shell'] += 1
index = theme / 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'
inline = re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>', index.read_text(), re.S)
for code in inline:
    subprocess.run(['node', '--check', '-'], input=code, text=True, check=True)
config = (theme / 'root/etc/config/gwrt').read_text()
assert not re.search(r'^config device\b', config, re.M), 'factory defaults contain live device history'
base = Path('package/base-files/Makefile').read_text()
assert '"192.168.3.3"' in base and '"192.168.3.255"' in base, 'GWRT LAN fallback is missing'
print('PASS source syntax and JSON:', counts, 'dashboard scripts:', len(inline))
PY

sh scripts/tests/test-gwrt-aria2-mount.sh gwrt-overlays/feeds/packages/net/aria2/files/aria2.init
sh scripts/tests/test-gwrt-aria2-uci-defaults.sh
python3 scripts/tests/test-gwrt-select-models.py
sh scripts/tests/test-gwrt-socinfo.sh
python3 scripts/tests/test-gwrt-collect-firmware.py

helper=gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-apk-autoinstall
if [ -f scripts/tests/test-gwrt-apk-autoinstall.sh ]; then
	bash scripts/tests/test-gwrt-apk-autoinstall.sh "$helper"
fi
echo 'GWRT source preflight passed'
