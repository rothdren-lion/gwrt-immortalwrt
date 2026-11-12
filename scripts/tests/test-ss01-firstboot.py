#!/usr/bin/env python3
"""Exercise deferred SS-01 defaults with a fake UCI/APK filesystem."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'package/gwrt-device-defaults/files'
BUSYBOX = os.environ.get('GWRT_SS01_TEST_BUSYBOX')
SHELL = [BUSYBOX, 'ash'] if BUSYBOX else ['/bin/sh']


def write_executable(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if BUSYBOX and data.startswith('#!/bin/sh\n'):
        data = data.replace('#!/bin/sh\n', '#!' + BUSYBOX + ' ash\n', 1)
    path.write_text(data)
    path.chmod(0o755)


def wait_until(predicate, label, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('timed out waiting for ' + label)


def sandboxed(content, base):
    return re.sub(r'(?<![\w])/(etc|tmp|usr|sys|lib|www|sbin|var)(?=/|[\s\'";]|$)',
                  lambda m: str(base / m.group(1)), content)


with tempfile.TemporaryDirectory(prefix='ss01-firstboot-') as tmp:
    base = Path(tmp)
    defaults = base / 'etc/uci-defaults'
    bindir = base / 'bin'
    for directory in ('etc/config', 'etc/init.d', 'tmp/sysinfo', 'usr/libexec',
                      'usr/share/gwrt/apk', 'usr/share/gwrt/wifiroam',
                      'sys/class/ieee80211', 'sys/class/net/eth0', 'lib/apk/db',
                      'sbin', 'var/lock'):
        (base / directory).mkdir(parents=True, exist_ok=True)
    (base / 'tmp/sysinfo/board_name').write_text('jdcloud,re-ss-01\n')
    (base / 'sys/class/net/eth0/address').write_text('00:11:22:33:44:55\n')
    (base / 'etc/config/wireless').write_text('')
    (base / 'usr/share/gwrt/apk/wifiroam-test.apk').touch()
    (base / 'usr/share/gwrt/apk/luci-app-wifiroam-test.apk').touch()
    (base / 'usr/share/gwrt/apk/luci-i18n-wifiroam-zh-cn-test.apk').touch()
    for name in ('wifiroamd.uc', 'topology.js', 'clients.js', 'pairing.js',
                 'settings.js', 'menu.json'):
        (base / 'usr/share/gwrt/wifiroam' / name).write_text('patched ' + name)

    for name in ('95_gwrt-wifi-defaults', '96_gwrt-preset-apk', '97_gwrt-wifiroam-defaults'):
        write_executable(defaults / name, sandboxed((FILES / name).read_text(), base))
    write_executable(base / 'usr/libexec/gwrt-ssid-name',
                     sandboxed((FILES / 'gwrt-ssid-name').read_text(), base))

    write_executable(bindir / 'uci', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
b=Path(os.environ['FAKE_ROOT']); db=b/'uci.json'
d=json.loads(db.read_text()) if db.exists() else {}
args=sys.argv[1:]
if args and args[0]=='-q': args.pop(0)
op=args.pop(0)
if op=='show':
    prefix=args[0]+'.'
    for k,v in d.items():
        if k.startswith(prefix):
            value=v if k.count('.')==1 else "'"+str(v)+"'"
            print(k+'='+str(value))
elif op=='get':
    if args[0] not in d or d[args[0]]=='': sys.exit(1)
    print(d[args[0]])
elif op=='set':
    if args[0].startswith('wifiroam.core.enabled=') and (b/'uci-fail').exists():
        with (b/'uci-failed').open('a') as f: f.write('fail\\n')
        sys.exit(1)
    k,v=args[0].split('=',1); d[k]=v; db.write_text(json.dumps(d))
    with (b/'calls').open('a') as f: f.write('set '+k+'='+v+'\\n')
elif op=='delete':
    d.pop(args[0],None); db.write_text(json.dumps(d))
elif op=='add_list':
    k,v=args[0].split('=',1); d.setdefault(k,[]).append(v); db.write_text(json.dumps(d))
elif op=='commit': pass
else: sys.exit(1)
''')
    write_executable(bindir / 'apk', '''#!/bin/sh
case "$1" in
  info)
    [ -f "$FAKE_ROOT/apk-installed" ] || exit 1
    [ "$2" != luci-i18n-wifiroam-zh-cn ] || [ -f "$FAKE_ROOT/apk-i18n-installed" ]
    exit $? ;;
  add)
    echo 'apk add' >> "$FAKE_ROOT/calls"
    [ -f "$FAKE_ROOT/apk-allow" ] || exit 1
    case "$*" in
      *luci-i18n-wifiroam-zh-cn-*)
        touch "$FAKE_ROOT/apk-i18n-attempt"
        [ -f "$FAKE_ROOT/apk-i18n-allow" ] || exit 1
        touch "$FAKE_ROOT/apk-i18n-installed" ;;
    esac
    touch "$FAKE_ROOT/apk-installed" "$FAKE_ROOT/etc/config/wifiroam"
    mkdir -p "$FAKE_ROOT/usr/share/wifiroam"
    mkdir -p "$FAKE_ROOT/www/luci-static/resources/view/wifiroam" "$FAKE_ROOT/usr/share/luci/menu.d"
    touch "$FAKE_ROOT/usr/share/luci/menu.d/luci-app-wifiroam.json"
    exit 0 ;;
esac
exit 1
''')
    for name in ('logger', 'ubus'):
        write_executable(bindir / name, '#!/bin/sh\nexit 0\n')
    write_executable(bindir / 'wifi', '''#!/bin/sh
printf 'wifi %s\\n' "$*" >> "$FAKE_ROOT/calls"
if [ -f "$FAKE_ROOT/wifi-fail" ]; then
  touch "$FAKE_ROOT/wifi-failed"
  exit 1
fi
''')
    write_executable(bindir / 'cp', '''#!/bin/sh
if [ -f "$FAKE_ROOT/cp-fail" ]; then
  echo failed >> "$FAKE_ROOT/cp-failed"
  exit 1
fi
exec /bin/cp "$@"
''')
    write_executable(base / 'sbin/wifi', '''#!/bin/sh
touch "$FAKE_ROOT/hotplug-locked"
while [ ! -e "$FAKE_ROOT/hotplug-release" ]; do sleep 0.05; done
''')
    (base / 'etc/board.json').write_text('{}')
    hook = base / '10-wifi-detect'
    write_executable(hook, sandboxed((ROOT / 'package/network/config/wifi-scripts/files/etc/hotplug.d/ieee80211/10-wifi-detect').read_text(), base))
    theme_hook = base / '30-gwrt-ssid-name'
    write_executable(theme_hook, sandboxed((ROOT / 'gwrt-theme-V3/theme/luci-theme-gwrt/root/etc/hotplug.d/ieee80211/30-gwrt-ssid-name').read_text(), base))
    for name in ('wifiroam', 'gwrt-wifiroam-autopair'):
        write_executable(base / 'etc/init.d' / name,
                         '''#!/bin/sh
printf 'init %s %s\\n' "${0##*/}" "$*" >> "$FAKE_ROOT/calls"
if [ "${0##*/}" = gwrt-wifiroam-autopair ] && [ "$1" = start ] && [ -f "$FAKE_ROOT/service-fail" ]; then
  echo failed >> "$FAKE_ROOT/service-failed"
  exit 1
fi
''')

    env = os.environ.copy()
    env.update(PATH=f'{bindir}:/usr/bin:/bin', FAKE_ROOT=str(base),
               GWRT_SS01_DEFAULTS_DIR=str(defaults),
               GWRT_SS01_PID_FILE=str(base / 'tmp/gwrt-ss01-uci-defaults.pid'),
               GWRT_SS01_WIFI_LOCK=str(base / 'var/lock/gwrt-ss01-wifi'),
               GWRT_SS01_WAIT_INTERVAL='0.05', GWRT_SS01_WAIT_ATTEMPTS='300')
    if BUSYBOX:
        (bindir / 'flock').symlink_to(BUSYBOX)
    (base / 'uci.json').write_text('{}')
    (base / 'calls').write_text('')

    # Source in subshells as S10boot does, then hold its parent process alive.
    boot = subprocess.Popen(SHELL + ['-c', '''
for f in "$GWRT_SS01_DEFAULTS_DIR"/*; do ( . "$f" ) || :; done
touch "$FAKE_ROOT/s10-ran-defaults"
while [ ! -e "$FAKE_ROOT/s10-release" ]; do sleep 0.05; done
'''], env=env)
    worker = None
    hotplug = None
    try:
        wait_until(lambda: (base / 's10-ran-defaults').exists(), 'S10 defaults')
        assert all((defaults / n).exists() for n in
                   ('95_gwrt-wifi-defaults', '96_gwrt-preset-apk', '97_gwrt-wifiroam-defaults'))
        assert int((base / 'tmp/gwrt-ss01-uci-defaults.pid').read_text()) == boot.pid

        # Exercise the actual caldata dispatch while defaults are pending.
        write_executable(base / 'usr/libexec/gwrt-ss01-firstboot',
                         '#!/bin/sh\ntouch "$FAKE_ROOT/caldata-dispatched"\nexit 23\n')
        caldata = (ROOT / 'target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata').read_text()
        dispatch = base / 'caldata-dispatch'
        write_executable(dispatch, sandboxed(caldata + '\nwifi_setup\n', base))
        result = subprocess.run(SHELL + [str(dispatch)], env=env, timeout=3)
        assert result.returncode == 23 and (base / 'caldata-dispatched').exists(), 'caldata did not dispatch pending SS-01 defaults'

        # A phy hotplug can arrive before S10boot creates /var/lock.
        hotplug_env = dict(env, ACTION='add')
        (base / 'var/lock').rmdir()
        hotplug = subprocess.Popen([str(hook)], env=hotplug_env, stdout=subprocess.DEVNULL)
        wait_until(lambda: (base / 'hotplug-locked').exists(), 'early hotplug lock', seconds=3)
        (base / 'hotplug-release').touch()
        assert hotplug.wait(timeout=3) == 0
        (base / 'hotplug-locked').unlink()
        (base / 'hotplug-release').unlink()

        worker = subprocess.Popen(SHELL + [str(FILES / 'gwrt-ss01-firstboot')], env=env)
        time.sleep(0.25)
        assert not (base / 'calls').read_text(), 'worker ran while S10boot was still active'
        (base / 's10-release').touch()
        assert boot.wait(timeout=3) == 0

        # With no phy, then only 2.4 GHz, nothing may be marked complete.
        time.sleep(0.2)
        (base / 'sys/class/ieee80211/phy0').mkdir()
        db = {
            'wireless.radio0': 'wifi-device', 'wireless.radio0.band': '2g',
            'wireless.default_radio0': 'wifi-iface', 'wireless.default_radio0.device': 'radio0',
            'wireless.default_radio0.mode': 'ap', 'wireless.default_radio0.ssid': 'OpenWrt',
            'wireless.default_radio0.encryption': 'none',
        }
        (base / 'uci.json').write_text(json.dumps(db))
        time.sleep(0.25)
        assert (defaults / '95_gwrt-wifi-defaults').exists()
        assert not (base / 'calls').read_text(), 'partial radios must not be configured'

        # Hold wifi config midway through hotplug. The worker must wait even if
        # both radio bands are already visible in the shared UCI staging area.
        assert subprocess.run([str(theme_hook)], env=hotplug_env).returncode == 0
        hotplug = subprocess.Popen([str(hook)], env=hotplug_env, stdout=subprocess.DEVNULL)
        wait_until(lambda: (base / 'hotplug-locked').exists(), 'hotplug lock')
        (base / 'sys/class/ieee80211/phy1').mkdir()
        db.update({'wireless.radio1': 'wifi-device', 'wireless.radio1.band': '5g'})
        (base / 'uci.json').write_text(json.dumps(db))
        time.sleep(0.8)
        assert not (base / 'calls').read_text(), 'worker wrote UCI during wifi detection'

        # Finish detection with a custom SSID containing whitespace.
        db.update({'wireless.radio1': 'wifi-device', 'wireless.radio1.band': '5g',
                   'wireless.default_radio1': 'wifi-iface', 'wireless.default_radio1.device': 'radio1',
                   'wireless.default_radio1.mode': 'ap', 'wireless.default_radio1.ssid': 'My WiFi',
                   'wireless.default_radio1.encryption': 'none'})
        (base / 'uci.json').write_text(json.dumps(db))
        (base / 'wifi-fail').touch()
        (base / 'hotplug-release').touch()
        assert hotplug.wait(timeout=3) == 0
        wait_until(lambda: (base / 'wifi-failed').exists(), 'failed wireless reload')
        time.sleep(0.25)
        assert (defaults / '95_gwrt-wifi-defaults').exists(), 'failed wireless reload was accepted'
        (base / 'wifi-fail').unlink()
        wait_until(lambda: not (defaults / '95_gwrt-wifi-defaults').exists(), 'wireless defaults')
        assert (base / 'calls').read_text().count('wifi reload\n') >= 2, 'wireless reload was not retried after SSIDs were already named'
        wait_until(lambda: 'apk add' in (base / 'calls').read_text(), 'failed offline install')
        assert (defaults / '96_gwrt-preset-apk').exists()
        assert (defaults / '97_gwrt-wifiroam-defaults').exists()
        assert 'wifiroam.core.role' not in json.loads((base / 'uci.json').read_text())

        # Simulate a reboot with only 96/97 still pending. Partial APK install,
        # patch copying, UCI writes, and service failures must all be retried.
        worker.terminate()
        worker.wait(timeout=3)
        (base / 'cp-fail').touch()
        (base / 'uci-fail').touch()
        (base / 'service-fail').touch()
        (base / 'apk-allow').touch()
        worker = subprocess.Popen(SHELL + [str(FILES / 'gwrt-ss01-firstboot')], env=env)
        wait_until(lambda: (base / 'apk-i18n-attempt').exists(), 'failed language APK install')
        time.sleep(0.25)
        assert (defaults / '96_gwrt-preset-apk').exists(), 'incomplete APK install was accepted'
        assert (base / 'usr/share/gwrt/apk').is_dir()
        (base / 'apk-i18n-allow').touch()
        wait_until(lambda: (base / 'cp-failed').exists(), 'failed mesh patch copy')
        assert (defaults / '97_gwrt-wifiroam-defaults').exists(), 'failed patch copy was accepted'
        (base / 'cp-fail').unlink()
        wait_until(lambda: (base / 'uci-failed').exists(), 'mesh UCI failure')
        wait_until(lambda: (base / 'service-failed').exists() or
                   not (defaults / '97_gwrt-wifiroam-defaults').exists() or
                   len((base / 'uci-failed').read_text().splitlines()) >= 2, 'mesh UCI retry')
        assert not (base / 'service-failed').exists(), 'mesh services started after failed UCI write'
        assert 'init wifiroam restart' not in (base / 'calls').read_text(), 'mesh services started after failed UCI write'
        assert (defaults / '97_gwrt-wifiroam-defaults').exists(), 'failed mesh defaults were removed'
        (base / 'uci-fail').unlink()
        wait_until(lambda: (base / 'service-failed').exists(), 'failed mesh service start')
        assert (defaults / '97_gwrt-wifiroam-defaults').exists(), 'failed service start was accepted'
        (base / 'service-fail').unlink()
        assert worker.wait(timeout=10) == 0
        assert not list(defaults.iterdir())
        state = json.loads((base / 'uci.json').read_text())
        assert state['wireless.radio0.disabled'] == state['wireless.radio1.disabled'] == '0'
        assert state['wireless.radio0.country'] == state['wireless.radio1.country'] == 'CN'
        assert state['wireless.radio1.channel'] == '149'
        assert state['wireless.radio1.htmode'] == 'HE80'
        assert state['wireless.default_radio0.ssid'] == 'GWRT_2.4G_4455'
        assert state['wireless.default_radio1.ssid'] == 'My WiFi'
        assert state['wireless.default_radio0.encryption'] == 'psk2+ccmp'
        assert state['wifiroam.core.role'] == 'unconfigured'
        assert 'GWRT_2.4G_4455' in state['wifiroam.roam.ssids']
        assert 'My WiFi' in state['wifiroam.roam.ssids']
        assert 'init wifiroam enable' in (base / 'calls').read_text()
        assert 'init wifiroam restart' in (base / 'calls').read_text()
        assert 'init gwrt-wifiroam-autopair start' in (base / 'calls').read_text()
        assert (base / 'etc/gwrt/wifiroam-apk.done').exists()
    finally:
        for process in (boot, worker, hotplug):
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=3)

print('PASS: SS-01 serializes wifi detection, retries first-boot failures, and activates mesh defaults')
