#!/usr/bin/env python3
"""Exercise roaming SSID selection and the set_roam payload without a router."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUSYBOX = os.environ.get('GWRT_SS01_TEST_BUSYBOX')
SHELL = [BUSYBOX, 'ash'] if BUSYBOX else ['/bin/sh']


def sandboxed(content, base):
    return re.sub(r'(?<![\w])/(etc|tmp|usr|sys|lib|www|sbin|var)(?=/|[\s\'";]|$)',
                  lambda match: str(base / match.group(1)), content)


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix='gwrt-roam-ssid-') as tmp:
    base = Path(tmp)
    binary = base / 'bin'
    binary.mkdir()
    functions = (ROOT / 'package/base-files/files/lib/functions.sh').read_text()
    write(base / 'lib/functions.sh', sandboxed(functions, base))
    write(base / 'lib/config/uci.sh', '''
uci_load() {
    local data
    data="$(uci -S -n export "$1")" || return 1
    eval "$data"
}
''')
    write(binary / 'uci', '''#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
data = json.loads((Path(os.environ['FAKE_ROOT']) / 'state.json').read_text())
args = [v for v in sys.argv[1:] if v not in ('-q', '-S', '-n')]
if args == ['export', 'wifiroam']:
    print('config roam roam')
    values = data['ssids']
    if isinstance(values, list):
        for value in values: print('list ssids ' + shlex.quote(value))
    elif values: print('option ssids ' + shlex.quote(values))
elif args == ['get', 'wifiroam.roam.enabled']:
    print('1')
elif args == ['show', 'wireless']:
    for name in data['wireless']: print('wireless.' + name + '=wifi-iface')
elif len(args) == 2 and args[0] == 'get':
    key = args[1].split('.')
    try: print(data['wireless'][key[1]][key[2]])
    except KeyError: sys.exit(1)
else: sys.exit(1)
''', True)
    write(binary / 'ubus', '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1:4] != ['call', 'wifiroam', 'set_roam']: sys.exit(1)
(Path(os.environ['FAKE_ROOT']) / 'payload.json').write_text(sys.argv[4])
''', True)
    write(binary / 'logger', '#!/bin/sh\nexit 0\n', True)
    write(binary / 'record-ssid', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with (Path(os.environ['FAKE_ROOT']) / 'ssids.jsonl').open('a') as output:
    output.write(json.dumps(sys.argv[1], ensure_ascii=False) + '\\n')
''', True)
    # CI has not built jshn yet. This small API stub records the shell arguments;
    # setting GWRT_TEST_JSHN_SH and PATH also exercises the actual host jshn.
    jshn = os.environ.get('GWRT_TEST_JSHN_SH')
    if jshn:
        write(base / 'usr/share/libubox/jshn.sh', Path(jshn).read_text())
    else:
        write(base / 'usr/share/libubox/jshn.sh', '''
json_init() { : > "$FAKE_ROOT/ssids.jsonl"; }
json_add_array() { json_in_array=1; }
json_close_array() { json_in_array=0; }
json_add_string() { [ "${json_in_array:-0}" != 1 ] || record-ssid "$2"; }
json_add_boolean() { :; }
json_add_int() { :; }
json_dump() {
    python3 -c 'import json,os,pathlib; p=pathlib.Path(os.environ["FAKE_ROOT"])/"ssids.jsonl"; print(json.dumps({"ssids":[json.loads(s) for s in p.read_text().splitlines()]}))'
}
''')
    source = (ROOT / 'package/gwrt-device-defaults/files/gwrt-wifiroam-autopair').read_text()
    source = source.split('\nwait_ubus || exit 0\n', 1)[0] + '\napply_roam\n'
    script = base / 'autopair'
    write(script, sandboxed(source, base))

    env = os.environ.copy()
    env.update(FAKE_ROOT=str(base), PATH=str(binary) + ':' + env['PATH'])

    def run_case(ssids, active, expected):
        payload = base / 'payload.json'
        payload.unlink(missing_ok=True)
        state = {'ssids': ssids, 'wireless': active}
        (base / 'state.json').write_text(json.dumps(state))
        result = subprocess.run(SHELL + [str(script)], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        if expected is None:
            assert not payload.exists(), 'unselected or already active SSID triggered set_roam'
        else:
            assert payload.exists(), 'selected SSID did not trigger set_roam'
            assert json.loads(payload.read_text())['ssids'] == expected

    ssids = ['My WiFi', 'Work Guest', 'O\'Reilly "mesh" \\ backslash', '网络',
             'line\nbreak', 'literal $(touch /tmp/never-run)']
    run_case(ssids, {'ap': {'mode': 'ap', 'ssid': 'My WiFi'}}, ssids)
    run_case(['Work Guest'], {'ap': {'mode': 'ap', 'ssid': 'Guest'}}, None)
    run_case('Office Room', {'ap': {'mode': 'ap', 'ssid': 'Office Room'}}, ['Office Room'])
    run_case(['My WiFi'], {'ap': {'mode': 'ap', 'ssid': 'My WiFi', 'ieee80211r': '1'}}, None)
    run_case([], {'ap': {'mode': 'ap', 'ssid': 'My WiFi'}}, None)

print('PASS: roaming applies exact UCI SSIDs, including spaces and quotes')
