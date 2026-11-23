#!/usr/bin/env python3
"""Run the production wireless generator in ucode with isolated fs/UCI inputs.

UCODE=/path/to/ucode UCODE_LIB=/path/to/modules python3 <this-file>
Only the UCI read interface and device files are fixtures; generation is real.
"""
import copy
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'package/network/config/wifi-scripts/files'
UCODE = os.environ.get('UCODE') or shutil.which('ucode')
if not UCODE:
    raise SystemExit('Set UCODE to a host ucode executable (with fs module)')
POLICY = {'ssid_prefix': 'GWRT', 'country': 'CN', 'key': '12345678'}
LOW = [36, 40, 44, 48]
HIGH = [149, 153, 157, 161]


def band(channels=None, he=True, vht=True, ht=True, eht=False, width=160):
    modes = ['NOHT']
    for mode, enabled, widths in [('HT', ht, [20, 40]), ('VHT', vht, [20, 40, 80, 160]),
                                   ('HE', he, [20, 40, 80, 160]), ('EHT', eht, [20, 40, 80, 160])]:
        if enabled:
            modes += [mode + str(w) for w in widths if w <= width]
    return dict(default_channel=(channels or [36])[0], channels=channels or LOW + HIGH,
                max_width=width, ht=ht, vht=vht, he=he, eht=eht, modes=modes)


def phy(path, bands):
    return {'path': path, 'info': {'bands': bands, 'radios': []}}


def detect(phys):
    """Run the production detector using only nl80211 device fixtures."""
    with tempfile.TemporaryDirectory(prefix='gwrt-wifi-detect-') as tmp:
        base = Path(tmp)
        (base / 'etc').mkdir()
        (base / 'etc/board.json').write_text('{"wlan":{}}')
        (base / 'phys.json').write_text(json.dumps(phys))
        for item in phys:
            name = item['wiphy_name']
            device = base / 'sys/devices/platform/soc/c000000.wifi'
            phy_dir = device / 'ieee80211' / name
            phy_dir.mkdir(parents=True, exist_ok=True)
            (phy_dir / 'index').write_text(re.sub(r'\D', '', name) + '\n')
            (phy_dir / 'device').symlink_to(device, target_is_directory=True)
            link = base / 'sys/class/ieee80211' / name
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(phy_dir, target_is_directory=True)
        source = (FILES / 'usr/share/hostap/wifi-detect.uc').read_text()
        source = source.replace('import { is_equal } from "/usr/share/hostap/common.uc";',
                                'function is_equal(a, b) { return sprintf("%J", a) == sprintf("%J", b); }')
        source = source.replace('let nl = require("nl80211");',
                                'let nl = { const: {}, request: function() { return json(readfile(' +
                                json.dumps(str(base / 'phys.json')) + ')); } };')
        source = re.sub(r'(?<![\w])/(etc|sys|lib|usr)(?=/)',
                        lambda m: str(base / m.group(1)), source)
        source = source.replace('replace(devpath, /^\\/sys\\/devices\\//, "")',
                                'replace(devpath, ' + json.dumps(str(base / 'sys/devices') + '/') + ', "")')
        (base / 'detector.uc').write_text(source)
        cmd = [UCODE]
        if os.environ.get('UCODE_LIB'):
            cmd += ['-L', os.environ['UCODE_LIB']]
        result = subprocess.run(cmd + [str(base / 'detector.uc')], text=True,
                                capture_output=True, timeout=5)
        if result.returncode:
            raise AssertionError('detector failed: ' + result.stderr)
        return json.loads((base / 'etc/board.json').read_text())['wlan']


def generate(wlan, config=None, policy=POLICY, board_id='test,router', eth_mac='00:11:22:33:AB:CD'):
    with tempfile.TemporaryDirectory(prefix='gwrt-wifi-generation-') as tmp:
        base = Path(tmp)
        for d in ['etc', 'usr/share/gwrt', 'lib/wifi', 'sys/class/net/eth0']:
            (base / d).mkdir(parents=True, exist_ok=True)
        (base / 'etc/board.json').write_text(json.dumps({'model': {'id': board_id}, 'wlan': wlan}))
        (base / 'sys/class/net/eth0/address').write_text(eth_mac + '\n')
        for name, data in wlan.items():
            if 'info' not in data:
                continue
            d = base / 'sys/class/ieee80211' / name
            d.mkdir(parents=True, exist_ok=True)
            (d / 'macaddress').write_text('00:22:33:44:55:66\n')
        if policy is not None:
            (base / 'usr/share/gwrt/wifi-defaults.json').write_text(json.dumps(policy))
        (base / 'uci.json').write_text(json.dumps(config or {}))
        (base / 'uci.uc').write_text('''import { readfile } from 'fs';
export function cursor() {
    return { get_all: function(name) { return json(readfile(''' + json.dumps(str(base / 'uci.json')) + ''')); } };
}
''')
        def sandbox(text):
            return re.sub(r'(?<![\w])/(etc|sys|lib|usr)(?=/)',
                          lambda m: str(base / m.group(1)), text)
        source = (FILES / 'lib/wifi/mac80211.uc').read_text()
        source = source.replace("import * as uci from 'uci';", 'import * as uci from ' + json.dumps(str(base / 'uci.uc')) + ';')
        (base / 'generator.uc').write_text(sandbox(source))
        helper = FILES / 'lib/wifi/gwrt-defaults.uc'
        if helper.exists():
            (base / 'lib/wifi/gwrt-defaults.uc').write_text(sandbox(helper.read_text()))
        cmd = [UCODE]
        if os.environ.get('UCODE_LIB'):
            cmd += ['-L', os.environ['UCODE_LIB']]
        result = subprocess.run(cmd + [str(base / 'generator.uc')], text=True, capture_output=True, timeout=5)
        if result.returncode:
            raise AssertionError('generator failed: ' + result.stderr)
        output = {}
        for line in result.stdout.splitlines():
            words = shlex.split(line)
            if words and words[0] == 'set':
                key, value = words[1].split('=', 1)
                output[key] = value
        return output, result.stdout


class Generation(unittest.TestCase):
    def test_ss01_high_band_generated_once(self):
        wlan = {'phy8': phy('platform/soc/c000000.wifi', {'5G': band()}),
                'phy9': phy('platform/soc/c000000.wifi+1', {'2G': band([1, 6, 11], width=40)})}
        out, _ = generate(wlan, board_id='jdcloud,re-ss-01')
        self.assertEqual(out['wireless.radio0.channel'], '149')
        self.assertEqual(out['wireless.radio0.htmode'], 'HE80')
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.8G_ABCD')
        self.assertEqual(out['wireless.default_radio1.ssid'], 'GWRT_2.4G_ABCD')
        self.assertEqual(out['wireless.default_radio0.encryption'], 'psk2+ccmp')
        self.assertEqual(out['wireless.default_radio0.key'], '12345678')
        self.assertEqual(out['wireless.radio0.country'], 'CN')

    def test_cs02_three_radios_in_any_probe_order(self):
        for order in [False, True]:
            entries = [('phy9', phy('soc/10000000.pci/pci0000:00/0000:01:00.0', {'5G': band(LOW)})),
                       ('phy1', phy('platform/soc/c000000.wifi', {'5G': band()}))]
            if order:
                entries.reverse()
            out, _ = generate(dict(entries), board_id='jdcloud,re-cs-02')
            for i, (_, p) in enumerate(entries):
                high = p['path'].endswith('c000000.wifi')
                self.assertEqual(out[f'wireless.radio{i}.channel'], '149' if high else '36')
                self.assertEqual(out[f'wireless.default_radio{i}.ssid'], f'GWRT_{"5.8G" if high else "5.2G"}_ABCD')
                self.assertEqual(out[f'wireless.radio{i}.htmode'], 'HE80')

    def test_other_platforms_generate_secure_defaults(self):
        for name, path in [('MT7981', 'platform/soc/18000000.wifi'),
                           ('AN7581', 'platform/1e140000.pcie/pci0000:00/0000:01:00.0'),
                           ('IPQ53xx', 'platform/soc/c000000.wifi'),
                           ('IPQ5018', 'platform/soc/a000000.wifi')]:
            with self.subTest(name=name):
                out, _ = generate({'phy0': phy(path, {'5G': band()})})
                self.assertEqual(out['wireless.radio0.channel'], '36')
                self.assertEqual(out['wireless.radio0.htmode'], 'HE80')
                self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.2G_ABCD')
                self.assertEqual(out['wireless.default_radio0.encryption'], 'psk2+ccmp')

    def test_old_vht_and_ht_hardware_keep_supported_modes(self):
        for capabilities, expected in [(band(he=False, width=80), 'VHT80'),
                                        (band(he=False, vht=False, width=40), 'HT40')]:
            out, _ = generate({'phy0': phy('platform/1e140000.pcie', {'5G': capabilities})})
            self.assertEqual(out['wireless.radio0.htmode'], expected)
            self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.2G_ABCD')

    def test_six_ghz_keeps_valid_security_and_regulatory_defaults(self):
        out, _ = generate({'phy0': phy('platform/wifi7', {'6G': band([5, 21, 37], eht=True)})})
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_6G_ABCD')
        self.assertEqual(out['wireless.default_radio0.encryption'], 'owe')
        self.assertEqual(out['wireless.default_radio0.key'], '')
        self.assertEqual(out['wireless.radio0.country'], '00')

    def test_channel_must_be_supported(self):
        out, _ = generate({'phy0': phy('platform/soc/c000000.wifi', {'5G': band(LOW)})},
                          board_id='jdcloud,re-ss-01')
        self.assertEqual(out['wireless.radio0.channel'], '36')
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.2G_ABCD')

    def test_board_country_does_not_get_cn_high_channel_preference(self):
        wlan = {'phy0': phy('platform/soc/c000000.wifi', {'5G': band()}),
                'defaults': {'country': 'DE'}}
        out, _ = generate(wlan, board_id='jdcloud,re-ss-01')
        self.assertEqual(out['wireless.radio0.country'], 'DE')
        self.assertEqual(out['wireless.radio0.channel'], '36')

    def test_sparse_channels_do_not_request_unavailable_bandwidth(self):
        for available, expected in [([40], 'HE20'), ([36, 40], 'HE40'),
                                    (LOW, 'HE80')]:
            out, _ = generate({'phy0': phy('platform/wifi', {'5G': band(available)})})
            self.assertEqual(out['wireless.radio0.htmode'], expected)

    def test_invalid_optional_policy_keeps_upstream_defaults(self):
        for invalid in ['not an object', {'ssid_prefix': 'GWRT', 'country': 'CN'},
                        dict(POLICY, country="C'N"), dict(POLICY, key='short')]:
            out, _ = generate({'phy0': phy('platform/wifi', {'5G': band()})}, policy=invalid)
            self.assertEqual(out['wireless.default_radio0.ssid'], 'ImmortalWrt')
            self.assertEqual(out['wireless.default_radio0.encryption'], 'none')

    def test_high_band_only_radio(self):
        out, _ = generate({'phy0': phy('platform/mt7996', {'5G': band(HIGH)})})
        self.assertEqual(out['wireless.radio0.channel'], '149')
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.8G_ABCD')

    def test_saved_user_mesh_and_disabled_config_unchanged(self):
        path = 'platform/soc/c000000.wifi'
        config = {'radio7': {'.type': 'wifi-device', 'path': path, 'band': '5g', 'channel': '100',
                             'htmode': 'HE160', 'disabled': '1'},
                  'custom': {'.type': 'wifi-iface', 'device': 'radio7', 'ssid': 'Main AP WiFi',
                             'key': 'keep-me', 'mode': 'ap', 'disabled': '1'},
                  'wifiroam_bh': {'.type': 'wifi-iface', 'mode': 'sta', 'ssid': 'mesh-gwrt'}}
        before = copy.deepcopy(config)
        out, raw = generate({'phy0': phy(path, {'5G': band()})}, config=config)
        self.assertEqual(out, {})
        self.assertEqual(raw, '')
        self.assertEqual(config, before)

    def test_late_phy_only_adds_missing_radio(self):
        path = 'platform/soc/c000000.wifi'
        saved = {'radio0': {'.type': 'wifi-device', 'path': path, 'band': '5g'}}
        wlan = {'phy0': phy(path, {'5G': band()}),
                'phy4': phy('pci0000:00/0000:01:00.0', {'5G': band(LOW)})}
        out, _ = generate(wlan, config=saved, board_id='jdcloud,re-cs-02')
        self.assertNotIn('wireless.radio0', out)
        self.assertEqual(out['wireless.default_radio1.ssid'], 'GWRT_5.2G_ABCD')

    def test_board_defaults_override_product_fallback(self):
        wlan = {'phy0': phy('platform/wifi', {'5G': band()}),
                'defaults': {'country': 'DE', 'ssids': {'5g': {'ssid': 'Operator WiFi',
                                                             'encryption': 'sae', 'key': 'saved-secret'}}}}
        out, _ = generate(wlan)
        self.assertEqual(out['wireless.default_radio0.ssid'], 'Operator WiFi')
        self.assertEqual(out['wireless.default_radio0.encryption'], 'sae')
        self.assertEqual(out['wireless.default_radio0.key'], 'saved-secret')
        self.assertEqual(out['wireless.radio0.country'], 'DE')

    def test_non_gwrt_image_unchanged(self):
        out, _ = generate({'phy0': phy('platform/wifi', {'5G': band()})}, policy=None)
        self.assertEqual(out['wireless.default_radio0.ssid'], 'ImmortalWrt')
        self.assertEqual(out['wireless.default_radio0.encryption'], 'none')
        self.assertEqual(out['wireless.radio0.channel'], '36')

    def test_invalid_ethernet_mac_uses_valid_phy_mac(self):
        out, _ = generate({'phy0': phy('platform/wifi', {'5G': band()})}, eth_mac='00:00:00:00:00:00')
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.2G_5566')

    def test_detector_to_generator_respects_radio_frequency_ranges(self):
        entry = {'wiphy_name': 'phy7', 'radios': [
            {'index': 0, 'freq_ranges': [{'start': 5170000, 'end': 5250000}]},
            {'index': 1, 'freq_ranges': [{'start': 5730000, 'end': 5850000}]}],
            'wiphy_bands': [{'ht_capa': 2, 'vht_capa': 1,
                'iftype_data': [{'he_cap_phy': [4]}],
                'freqs': [{'freq': 5180, 'disabled': True}, {'freq': 5200},
                          {'freq': 5745}, {'freq': 5765}, {'freq': 5785}, {'freq': 5805}]}]}
        wlan = detect([entry])
        info = wlan['phy7']['info']
        self.assertEqual(info['bands']['5G']['channels'], [40, 149, 153, 157, 161])
        self.assertEqual(info['radios'][0]['bands']['5G']['channels'], [40])
        self.assertEqual(info['radios'][1]['bands']['5G']['channels'], HIGH)
        out, _ = generate(wlan, board_id='jdcloud,re-cs-02')
        self.assertEqual(out['wireless.radio0.channel'], '40')
        self.assertEqual(out['wireless.radio1.channel'], '149')
        self.assertEqual(out['wireless.radio0.radio'], '0')
        self.assertEqual(out['wireless.radio1.radio'], '1')
        self.assertEqual(out['wireless.default_radio0.ssid'], 'GWRT_5.2G_ABCD')
        self.assertEqual(out['wireless.default_radio1.ssid'], 'GWRT_5.8G_ABCD')

    def test_board_ssid_without_key_keeps_upstream_open_defaults(self):
        wlan = {'phy0': phy('platform/wifi', {'5G': band()}),
                'defaults': {'country': 'DE', 'ssids': {'5g': {'ssid': 'Operator WiFi'}}}}
        out, _ = generate(wlan)
        self.assertEqual(out['wireless.default_radio0.encryption'], 'none')
        self.assertEqual(out['wireless.default_radio0.key'], '')

    def test_no_radio_needs_no_work(self):
        out, raw = generate({})
        self.assertEqual((out, raw), ({}, ''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
