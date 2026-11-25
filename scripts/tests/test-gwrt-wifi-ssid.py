#!/usr/bin/env python3
"""Exercise the fixed band-prefix SSID naming (GWRT_<band>_<radio MAC4>)."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'package/gwrt-device-defaults/files'


def write_executable(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    path.chmod(0o755)


def sandboxed(content, base):
    return re.sub(r'(?<![\w])/(etc|tmp|usr|sys|lib|var|bin|sbin)(?=/|[\s\'";]|$)',
                  lambda m: str(base / m.group(1)), content)


UCI = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
b = Path(os.environ['FAKE_ROOT'])
db = b / 'uci.json'
d = json.loads(db.read_text()) if db.exists() else {}
args = sys.argv[1:]
if args and args[0] == '-q':
    args.pop(0)
op = args.pop(0)
if op == 'show':
    prefix = args[0] + '.'
    for k, v in d.items():
        if k.startswith(prefix):
            print(k + '=' + (str(v) if k.count('.') == 1 else "'" + str(v) + "'"))
elif op == 'get':
    if args[0] not in d or d[args[0]] == '':
        sys.exit(1)
    print(d[args[0]])
elif op == 'set':
    k, v = args[0].split('=', 1)
    d[k] = v
    db.write_text(json.dumps(d))
    with (b / 'calls').open('a') as f:
        f.write('set ' + k + '=' + v + '\\n')
elif op == 'commit':
    with (b / 'calls').open('a') as f:
        f.write('commit ' + ' '.join(args) + '\\n')
else:
    sys.exit(1)
'''


def build_sandbox(base):
    for directory in ('etc/config', 'usr/libexec', 'bin', 'sys/class/ieee80211',
                      'sys/class/net/eth0', 'sys/devices/platform/soc@0',
                      'sys/devices/pci0000:00/0000:01:00.0'):
        (base / directory).mkdir(parents=True, exist_ok=True)
    (base / 'sys/class/net/eth0/address').write_text('dc:d8:7c:4a:84:13\n')
    (base / 'etc/config/wireless').write_text('')


    # AHB dual band: same device, two phys; PCIe 9074 is its own device.
    ahb = base / 'sys/devices/platform/soc@0/c000000.wifi'
    ahb.mkdir(parents=True, exist_ok=True)
    pcie = base / 'sys/devices/pci0000:00/0000:01:00.0'
    pcie.mkdir(parents=True, exist_ok=True)
    for name, target, mac in (
            ('phy0', ahb, 'dc:d8:7c:59:b5:e0'),
            ('phy1', ahb, 'dc:d8:7c:59:b5:df'),
            ('phy2', pcie, 'dc:d8:7c:59:b5:c4')):
        phy = base / 'sys/class/ieee80211' / name
        phy.mkdir(parents=True, exist_ok=True)
        (phy / 'macaddress').write_text(mac + '\n')
        (phy / 'device').symlink_to(target)

    write_executable(base / 'bin/uci', UCI)
    write_executable(base / 'bin/logger', '#!/bin/sh\nexit 0\n')
    write_executable(base / 'bin/wifi', '#!/bin/sh\nprintf "wifi %s\\n" "$*" >> "$FAKE_ROOT/calls"\n')
    write_executable(base / 'usr/libexec/gwrt-ssid-name',
                     sandboxed((FILES / 'gwrt-ssid-name').read_text(), base))

    wireless = {
        'wireless.radio0': 'wifi-device',
        'wireless.radio0.band': '5g',
        'wireless.radio0.channel': '157',
        'wireless.radio0.path': 'platform/soc@0/c000000.wifi',
        'wireless.radio1': 'wifi-device',
        'wireless.radio1.band': '2g',
        'wireless.radio1.channel': '1',
        'wireless.radio1.path': 'platform/soc@0/c000000.wifi+1',
        'wireless.radio2': 'wifi-device',
        'wireless.radio2.band': '5g',
        'wireless.radio2.channel': '36',
        'wireless.radio2.path': 'pci0000:00/0000:01:00.0',
        # 默认名（OpenWrt 原生 / 空）
        'wireless.default_radio0': 'wifi-iface',
        'wireless.default_radio0.device': 'radio0',
        'wireless.default_radio0.mode': 'ap',
        'wireless.default_radio0.ssid': 'OpenWrt',
        # 默认名（网关原生带频段）
        'wireless.default_radio1': 'wifi-iface',
        'wireless.default_radio1.device': 'radio1',
        'wireless.default_radio1.mode': 'ap',
        'wireless.default_radio1.ssid': 'OpenWrt_2.4G',
        # 空 SSID
        'wireless.default_radio2': 'wifi-iface',
        'wireless.default_radio2.device': 'radio2',
        'wireless.default_radio2.mode': 'ap',
        'wireless.default_radio2.ssid': '',
        # 用户自定义：不许动
        'wireless.user0': 'wifi-iface',
        'wireless.user0.device': 'radio1',
        'wireless.user0.mode': 'ap',
        'wireless.user0.ssid': 'Rodren',
        # mesh 回传：不许动
        'wireless.wifiroam_bh': 'wifi-iface',
        'wireless.wifiroam_bh.device': 'radio0',
        'wireless.wifiroam_bh.mode': 'ap',
        'wireless.wifiroam_bh.ssid': 'mesh-gwrt',
        # 非 AP 模式：不处理
        'wireless.sta0': 'wifi-iface',
        'wireless.sta0.device': 'radio2',
        'wireless.sta0.mode': 'sta',
        'wireless.sta0.ssid': 'OpenWrt',
    }
    (base / 'uci.json').write_text(json.dumps(wireless))
    (base / 'calls').write_text('')


def run_helper(base, env):
    return subprocess.run(['/bin/sh', str(base / 'usr/libexec/gwrt-ssid-name'), '--reload'],
                          env=env, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='wifi-ssid-') as tmp:
    base = Path(tmp)
    build_sandbox(base)
    env = os.environ.copy()
    env.update(FAKE_ROOT=str(base), PATH=f'{base}/bin:/usr/bin:/bin')

    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr

    cfg = json.loads((base / 'uci.json').read_text())
    assert cfg['wireless.default_radio0.ssid'] == 'GWRT_5.8G_B5E0', cfg['wireless.default_radio0.ssid']
    assert cfg['wireless.default_radio1.ssid'] == 'GWRT_2.4G_B5DF', cfg['wireless.default_radio1.ssid']
    assert cfg['wireless.default_radio2.ssid'] == 'GWRT_5.2G_B5C4', cfg['wireless.default_radio2.ssid']
    assert cfg['wireless.user0.ssid'] == 'Rodren'
    assert cfg['wireless.wifiroam_bh.ssid'] == 'mesh-gwrt'
    assert cfg['wireless.sta0.ssid'] == 'OpenWrt'
    calls = (base / 'calls').read_text()
    assert 'commit wireless' in calls and 'wifi reload' in calls, calls

    # 幂等：第二次不写盘、不 reload
    before = (base / 'uci.json').read_text()
    (base / 'calls').write_text('')
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    assert (base / 'uci.json').read_text() == before
    assert (base / 'calls').read_text().strip() == '', (base / 'calls').read_text()

    # 用户自己改成 GWRT_5.8G_1234（不同后缀，例如主 AP 下发）不许被覆盖
    cfg['wireless.default_radio0.ssid'] = 'GWRT_5.8G_1234'
    (base / 'uci.json').write_text(json.dumps(cfg))
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    assert json.loads((base / 'uci.json').read_text())['wireless.default_radio0.ssid'] == 'GWRT_5.8G_1234'

# phy MAC 不可用时退回基础 MAC
with tempfile.TemporaryDirectory(prefix='wifi-ssid-fallback-') as tmp:
    base = Path(tmp)
    build_sandbox(base)
    for phy in ('phy0', 'phy1', 'phy2'):
        (base / 'sys/class/ieee80211' / phy / 'macaddress').write_text('00:00:00:00:00:00\n')
    env = os.environ.copy()
    env.update(FAKE_ROOT=str(base), PATH=f'{base}/bin:/usr/bin:/bin')
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    cfg = json.loads((base / 'uci.json').read_text())
    assert cfg['wireless.default_radio0.ssid'] == 'GWRT_5.8G_8413', cfg['wireless.default_radio0.ssid']
    assert cfg['wireless.default_radio1.ssid'] == 'GWRT_2.4G_8413'

# 完全没有 MAC 时只写 GWRT_<频段>，拿到 MAC 后再补后缀
with tempfile.TemporaryDirectory(prefix='wifi-ssid-nomac-') as tmp:
    base = Path(tmp)
    build_sandbox(base)
    for phy in ('phy0', 'phy1', 'phy2'):
        (base / 'sys/class/ieee80211' / phy / 'macaddress').write_text('00:00:00:00:00:00\n')
    (base / 'sys/class/net/eth0/address').write_text('00:00:00:00:00:00\n')
    env = os.environ.copy()
    env.update(FAKE_ROOT=str(base), PATH=f'{base}/bin:/usr/bin:/bin')
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    cfg = json.loads((base / 'uci.json').read_text())
    assert cfg['wireless.default_radio0.ssid'] == 'GWRT_5.8G', cfg['wireless.default_radio0.ssid']
    assert cfg['wireless.default_radio1.ssid'] == 'GWRT_2.4G'
    assert cfg['wireless.default_radio2.ssid'] == 'GWRT_5.2G'

    # 下次开机 phy MAC 可读，无后缀的默认名应该被补全
    for name, mac in (('phy0', 'dc:d8:7c:59:b5:e0'), ('phy1', 'dc:d8:7c:59:b5:df'),
                      ('phy2', 'dc:d8:7c:59:b5:c4')):
        (base / 'sys/class/ieee80211' / name / 'macaddress').write_text(mac + '\n')
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    cfg = json.loads((base / 'uci.json').read_text())
    assert cfg['wireless.default_radio0.ssid'] == 'GWRT_5.8G_B5E0', cfg['wireless.default_radio0.ssid']
    assert cfg['wireless.default_radio1.ssid'] == 'GWRT_2.4G_B5DF'
    assert cfg['wireless.default_radio2.ssid'] == 'GWRT_5.2G_B5C4'

# 无 band、只有旧 hwmode 的配置也要能命名
with tempfile.TemporaryDirectory(prefix='wifi-ssid-hwmode-') as tmp:
    base = Path(tmp)
    build_sandbox(base)
    cfg = json.loads((base / 'uci.json').read_text())
    for radio in ('radio0', 'radio1', 'radio2'):
        cfg.pop(f'wireless.{radio}.band', None)
    cfg['wireless.radio0.hwmode'] = '11a'
    cfg['wireless.radio1.hwmode'] = '11g'
    cfg['wireless.radio2.hwmode'] = '11a'
    (base / 'uci.json').write_text(json.dumps(cfg))
    env = os.environ.copy()
    env.update(FAKE_ROOT=str(base), PATH=f'{base}/bin:/usr/bin:/bin')
    result = run_helper(base, env)
    assert result.returncode == 0, result.stderr
    cfg = json.loads((base / 'uci.json').read_text())
    assert cfg['wireless.default_radio0.ssid'] == 'GWRT_5.8G_B5E0'
    assert cfg['wireless.default_radio1.ssid'] == 'GWRT_2.4G_B5DF'
    assert cfg['wireless.default_radio2.ssid'] == 'GWRT_5.2G_B5C4'

print('PASS gwrt-ssid-name: fixed band prefixes, per-radio MAC4, idempotent, fallback and hwmode paths')
