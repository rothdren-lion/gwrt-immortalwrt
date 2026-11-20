#!/usr/bin/env python3
"""Behavior checks for shared first-boot work, with no real UCI/services/devices."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'package/gwrt-device-defaults/files'
CALDATA = ROOT / 'target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata'
SHELL = ['/usr/bin/busybox', 'ash'] if Path('/usr/bin/busybox').exists() else ['/bin/sh']


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def sandbox(text, base):
    return re.sub(r'(?<![\w])/(etc|tmp|usr|sys|lib|www|sbin|var|dev)(?=/|[\s\'";]|$)',
                  lambda m: str(base / m.group(1)), text)


class Startup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gwrt-startup-opt-')
        self.addCleanup(self.temp.cleanup)
        self.base = b = Path(self.temp.name)
        for d in ['etc/config', 'etc/init.d', 'tmp/sysinfo', 'usr/share/gwrt/apk',
                  'usr/share/gwrt/wifiroam', 'usr/share/wifiroam', 'lib/apk/db', 'bin', 'dev']:
            (b / d).mkdir(parents=True, exist_ok=True)
        (b / 'dev/null').symlink_to('/dev/null')
        (b / 'tmp/sysinfo/board_name').write_text('test,router\n')
        (b / 'uci.json').write_text('{}')
        (b / 'events').touch()
        self.env = dict(os.environ, FAKE_ROOT=str(b), PATH=f'{b}/bin:/usr/bin:/bin')
        executable(b / 'bin/uci', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
b=Path(os.environ['FAKE_ROOT']); p=b/'uci.json'; d=json.loads(p.read_text()); a=sys.argv[1:]
if a and a[0]=='-q': a.pop(0)
op=a.pop(0)
if op=='get':
 if a[0] not in d: sys.exit(1)
 print(d[a[0]])
elif op=='show':
 for k,v in d.items():
  if k.startswith(a[0]+'.'): print(k+'='+str(v))
elif op=='set':
 k,v=a[0].split('=',1); d[k]=v; p.write_text(json.dumps(d))
elif op=='add_list':
 k,v=a[0].split('=',1)
 if (b/'list-fail').exists() and v=='Second AP': sys.exit(1)
 d.setdefault(k,[]).append(v); p.write_text(json.dumps(d))
elif op in ('delete','revert'):
 d.pop(a[0],None); p.write_text(json.dumps(d))
elif op=='commit': pass
else: sys.exit(1)
''')
        for cmd in ['logger', 'wifi', 'sleep', 'reboot', 'sync']:
            executable(b / 'bin' / cmd, '#!/bin/sh\nprintf "%s %s\\n" "${0##*/}" "$*" >> "$FAKE_ROOT/events"\n')
        executable(b / 'bin/apk', '''#!/bin/sh
case "$1" in
 info) exit 0 ;;
 add)
  for file in "$@"; do :; done
  file="${file##*/}"
  echo "apk $file" >> "$FAKE_ROOT/events"
  if [ -f "$FAKE_ROOT/apk-fail" ] && [ "$file" = bad.apk ]; then exit 1; fi
  exit 0 ;;
esac
exit 1
''')
        for service in ['wifiroam', 'gwrt-wifiroam-autopair', 'rpcd']:
            executable(b / 'etc/init.d' / service, '''#!/bin/sh
if [ "$1" = running ]; then [ -f "$FAKE_ROOT/service-active" ]; exit $?; fi
printf 'service %s %s\n' "${0##*/}" "$*" >> "$FAKE_ROOT/events"
''')

    def run_file(self, path, appended=''):
        script = self.base / 'run-script'
        executable(script, sandbox(path.read_text() + appended, self.base))
        return subprocess.run(SHELL + [str(script)], env=self.env, text=True,
                              capture_output=True, timeout=4)

    def db(self, values=None):
        p = self.base / 'uci.json'
        if values is not None:
            p.write_text(json.dumps(values))
        return json.loads(p.read_text())

    def events(self):
        return (self.base / 'events').read_text().splitlines()

    def test_non_ss01_defaults_do_not_write_or_reload(self):
        values = {'wireless.radio9.disabled': '1', 'wireless.radio9.channel': '100',
                  'wireless.user.ssid': 'Mesh Parent WiFi', 'wireless.user.key': 'keep'}
        self.db(values)
        self.assertEqual(self.run_file(FILES / '95_gwrt-wifi-defaults').returncode, 0)
        self.assertEqual(self.db(), values)
        self.assertEqual(self.events(), [])

    def test_retired_theme_hooks_never_touch_radios(self):
        hooks = [p for p in ROOT.glob('**/hotplug.d/ieee80211/*')
                 if p.name in ('30-gwrt-ssid-name', '40-gwrt-5g2-radio')]
        self.assertEqual(len(hooks), 6)
        self.env['ACTION'] = 'add'
        for hook in hooks:
            self.assertEqual(self.run_file(hook).returncode, 0)
        self.assertEqual(self.events(), [])

    def test_no_wireless_boards_never_extract_wait_or_reboot(self):
        appended = '''
cal_ensure() { echo EXTRACT >> "$FAKE_ROOT/events"; return 0; }
wifi_setup() { echo SETUP >> "$FAKE_ROOT/events"; }
reboot_after_caldata_extract() { echo REBOOT >> "$FAKE_ROOT/events"; }
start
wait
'''
        for board in ['jdcloud,re-cs-07', 'xiaomi,ax3000t', 'test,no-wifi']:
            (self.base / 'tmp/sysinfo/board_name').write_text(board)
            self.assertEqual(self.run_file(CALDATA, appended).returncode, 0)
            self.assertEqual(self.events(), [])

    def test_normal_calibrated_boot_never_rewrites_wifi(self):
        (self.base / 'tmp/sysinfo/board_name').write_text('jdcloud,re-cs-02')
        cal = self.base / 'lib/firmware/ath11k/IPQ6018/hw1.0/cal-ahb-c000000.wifi.bin'
        cal.parent.mkdir(parents=True)
        cal.write_bytes(b'caldata')
        result = self.run_file(CALDATA, '\nstart\nwait\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), [])

    def test_empty_apk_directory_has_no_database_wait(self):
        (self.base / 'lib/apk/db').rmdir()
        self.assertEqual(self.run_file(FILES / '96_gwrt-preset-apk').returncode, 0)
        self.assertEqual(self.events(), [])

    def test_apks_successful_files_installed_once_socket_first(self):
        for name in ['wifiroam.apk', 'luci-app.apk', 'ucode-mod-socket.apk']:
            (self.base / 'usr/share/gwrt/apk' / name).touch()
        result = self.run_file(FILES / '96_gwrt-preset-apk')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = [e for e in self.events() if e.startswith('apk ')]
        self.assertEqual(installed[0], 'apk ucode-mod-socket.apk')
        self.assertEqual(len(installed), 3)
        self.assertEqual(len(set(installed)), 3)

    def test_failed_apk_retains_retry_even_with_old_db_entries(self):
        for name in ['good.apk', 'bad.apk']:
            (self.base / 'usr/share/gwrt/apk' / name).touch()
        (self.base / 'apk-fail').touch()
        self.assertEqual(self.run_file(FILES / '96_gwrt-preset-apk').returncode, 1)
        self.assertEqual(self.events().count('apk good.apk'), 1)
        self.assertEqual(self.events().count('apk bad.apk'), 2)
        self.assertFalse((self.base / 'etc/gwrt/wifiroam-apk.done').exists())
        self.assertTrue((self.base / 'usr/share/gwrt/apk/bad.apk').exists())

    def prepare_mesh(self, enabled='1', role='cap'):
        (self.base / 'etc/config/wifiroam').touch()
        (self.base / 'usr/share/gwrt/wifiroam/wifiroamd.uc').write_text('old daemon')
        v5 = self.base / 'usr/share/gwrt/wifiroam-v5'
        v5.mkdir()
        (v5 / 'wifiroamd.uc').write_text('new daemon')
        (v5 / 'acl.json').write_text('{}')
        values = {'wifiroam.core.enabled': enabled, 'wifiroam.core.role': role,
                  'wifiroam.core.name': 'Saved Mesh', 'wifiroam.backhaul.enabled': '0',
                  'wifiroam.backhaul.ssid': 'Saved Backhaul', 'wifiroam.backhaul.key': 'secret',
                  'wifiroam.roam.ssids': ['Main AP', 'Guest AP'], 'wifiroam.roam.enabled': '0'}
        self.db(values)
        return values

    def test_overlay_waits_for_failed_preset_install_on_every_board(self):
        self.prepare_mesh()
        pending = self.base / 'etc/uci-defaults/96_gwrt-preset-apk'
        pending.parent.mkdir(parents=True)
        pending.touch()
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse((self.base / 'usr/share/wifiroam/wifiroamd.uc').exists())
        self.assertEqual(self.events(), [])
        pending.unlink()
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'usr/share/wifiroam/wifiroamd.uc').read_text(), 'new daemon')

    def test_pristine_apk_config_receives_gwrt_backhaul_defaults(self):
        self.prepare_mesh(role='unconfigured')
        stock = FILES / 'wifiroam.default-config'
        config = self.base / 'etc/config/wifiroam'
        config.write_text(stock.read_text() if stock.exists() else 'pristine upstream config\n')
        target = self.base / 'usr/share/gwrt/wifiroam/default-config'
        target.write_text(config.read_text())
        values = self.db()
        values.update({'wifiroam.backhaul.enabled': '0', 'wifiroam.backhaul.ssid': 'wifiroam-bh',
                       'wifiroam.backhaul.key': '', 'wifiroam.roam.enabled': '0'})
        del values['wifiroam.roam.ssids']
        self.db(values)
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.db()
        self.assertEqual(saved['wifiroam.backhaul.enabled'], '1')
        self.assertEqual(saved['wifiroam.backhaul.ssid'], 'mesh-gwrt')
        self.assertEqual(saved['wifiroam.backhaul.key'], 'Abc123abc8888')

    def test_known_backhaul_wds_compatibility_migration(self):
        self.prepare_mesh()
        values = self.db()
        values.update({'wireless.wifiroam_bh.wds': '1', 'wireless.wifiroam_bh2.wds': '1',
                       'wireless.user_sta.wds': '1', 'wireless.user_sta.key': 'saved-secret'})
        self.db(values)
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.db()
        self.assertEqual(saved['wireless.wifiroam_bh.wds'], '0')
        self.assertEqual(saved['wireless.wifiroam_bh2.wds'], '0')
        self.assertEqual(saved['wireless.user_sta.wds'], '1')
        self.assertEqual(saved['wireless.user_sta.key'], 'saved-secret')
        self.assertFalse(any(e.startswith('wifi ') for e in self.events()))

    def test_saved_mesh_config_preserved_single_final_restart(self):
        values = self.prepare_mesh()
        (self.base / 'service-active').touch()
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db(), values)
        self.assertEqual((self.base / 'usr/share/wifiroam/wifiroamd.uc').read_text(), 'new daemon')
        self.assertEqual(self.events().count('service wifiroam restart'), 1)
        self.assertEqual(self.events().count('service rpcd reload'), 1)

    def test_both_overlays_remove_stock_donation_page(self):
        self.prepare_mesh()
        shared = FILES / 'wifiroam'
        v5 = self.base / 'usr/share/gwrt/wifiroam-v5'
        stock_v5 = ROOT / 'package/gwrt-wifiroam-v5/files/usr/share/gwrt/wifiroam-v5'
        assets = self.base / 'www/luci-static/resources/wifiroam'
        views = assets.parent / 'view/wifiroam'
        for d in (assets, views):
            d.mkdir(parents=True)
        target = self.base / 'usr/share/luci/menu.d/luci-app-wifiroam.json'
        for name in ('menu.json', 'backhaul.js', 'backhaul-acl.json', 'topologyBackhaul.js'):
            (self.base / 'usr/share/gwrt/wifiroam' / name).write_bytes((shared / name).read_bytes())
        (v5 / 'menu.json').write_bytes((stock_v5 / 'menu.json').read_bytes())
        for variant in ('v5', 'base'):
            with self.subTest(variant=variant):
                stock = assets / 'donate-qr.png'
                old_view = views / 'donate.js'
                old_cache = self.base / 'tmp/luci-indexcache.12345678.json'
                for file in (stock, old_view, old_cache):
                    file.touch()
                if variant == 'base':
                    (v5 / 'wifiroamd.uc').unlink()
                result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(file.exists() for file in (stock, old_view, old_cache)))
                routes = json.loads(target.read_text())
                self.assertFalse(any('donate' in k for k in routes))
                self.assertIn('admin/services/wifiroam/backhaul', routes)
                self.assertEqual((views / 'backhaul.js').read_bytes(), (shared / 'backhaul.js').read_bytes())
                self.assertEqual((assets / 'topologyBackhaul.js').read_bytes(),
                                 (shared / 'topologyBackhaul.js').read_bytes())

    def test_mesh_assets_have_no_donation_ui(self):
        root = ROOT / 'package/gwrt-wifiroam-v5/files/usr/share/gwrt/wifiroam-v5'
        sources = [p for p in root.rglob('*') if p.is_file()]
        for path in sources:
            if not path.is_file():
                continue
            try:
                text = path.read_text().lower()
            except UnicodeDecodeError:
                continue
            for needle in ('wr-donate', 'donate-qr', 'donate.js', '打赏'):
                self.assertNotIn(needle, text, f'{needle} remains in {path.relative_to(ROOT)}')

    def test_user_disabled_mesh_not_started(self):
        values = self.prepare_mesh(enabled='0', role='sap')
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db(), values)
        self.assertFalse(any(e.startswith('service wifiroam ') or 'autopair ' in e for e in self.events()))

    def test_pre_service_boot_does_not_start_then_restart_daemon(self):
        self.prepare_mesh()
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(e.startswith('service wifiroam ') for e in self.events()))

    def test_partial_roam_list_is_reverted_and_retried(self):
        self.prepare_mesh(role='unconfigured')
        values = self.db()
        del values['wifiroam.roam.ssids']
        values.update({'wireless.ap0': 'wifi-iface', 'wireless.ap0.mode': 'ap',
                       'wireless.ap0.ssid': 'First AP', 'wireless.ap1': 'wifi-iface',
                       'wireless.ap1.mode': 'ap', 'wireless.ap1.ssid': 'Second AP'})
        self.db(values)
        (self.base / 'list-fail').touch()
        self.assertEqual(self.run_file(FILES / '97_gwrt-wifiroam-defaults').returncode, 1)
        self.assertNotIn('wifiroam.roam.ssids', self.db())
        self.assertFalse(any(e.startswith('service wifiroam ') for e in self.events()))
        (self.base / 'list-fail').unlink()
        result = self.run_file(FILES / '97_gwrt-wifiroam-defaults')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db()['wifiroam.roam.ssids'], ['First AP', 'Second AP'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
