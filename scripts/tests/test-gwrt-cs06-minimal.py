#!/usr/bin/env python3
"""Diagnostic package guard, board scope, defaults and seed regressions."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('minimal', ROOT / 'scripts/gwrt-verify-cs06-minimal.py')
minimal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(minimal)


class MinimalTests(unittest.TestCase):
    def test_essentials(self):
        minimal.check(minimal.REQUIRED | {'luci-app-firewall'}, 'test')

    def test_dnsmasq_full_provides_dhcp_dns(self):
        minimal.check((minimal.REQUIRED - {'dnsmasq'}) | {'dnsmasq-full'}, 'test')

    def test_dnsmasq_similar_name_is_not_a_provider(self):
        with self.assertRaises(ValueError):
            minimal.check((minimal.REQUIRED - {'dnsmasq'}) | {'dnsmasq-extra'}, 'test')

    def test_missing_essentials(self):
        for name in minimal.REQUIRED:
            with self.subTest(name=name), self.assertRaises(ValueError):
                minimal.check(minimal.REQUIRED - {name}, 'test')

    def test_plugins_rejected(self):
        for name in ('daed', 'luci-app-homeproxy', 'easytier', 'appfilter', 'gwrt-agent',
                     'gwrt-device-defaults', 'gwrt-mesh-apmode', 'luci-theme-gwrt',
                     'luci-app-aria2', 'athena-led', 'wifiroam', 'luci-app-any-new-plugin'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                minimal.check(minimal.REQUIRED | {name}, 'test')

    def test_seed(self):
        with tempfile.TemporaryDirectory() as temp:
            seed = Path(temp) / 'seed'
            subprocess.run(['sh', str(ROOT / 'gwrt-mk-cs06-minimal-config.sh'), str(seed)], check=True)
            text = seed.read_text()
            self.assertIn('CONFIG_PACKAGE_gwrt-cs06-diag-defaults=y', text)
            self.assertNotIn('CONFIG_PACKAGE_gwrt-device-defaults=y', text)
            self.assertNotIn('CONFIG_PACKAGE_daed=y', text)
            self.assertIn('CONFIG_PACKAGE_MAC80211_DEBUGFS=y', text)

    def test_no_apk_restore(self):
        makefile = (ROOT / 'package/gwrt-cs06-diag-defaults/Makefile').read_text()
        installed = re.findall(r'^\s*\$\(INSTALL_BIN\).*?/files/(\S+)', makefile, re.M)
        self.assertEqual(installed, ['94_gwrt-lan-ip', '95_gwrt-wifi-defaults', 'gwrt-ssid-name'])

    def test_cs06_only_board_flags(self):
        property_name = 'qcom,ath12k-disable-tx-encap-offload;'
        paths = [p for p in (ROOT / 'target/linux/qualcommbe/dts').glob('*')
                 if p.is_file() and property_name in p.read_text()]
        self.assertEqual([p.name for p in paths], ['ipq5322-re-cs-06.dts'])
        text = paths[0].read_text()
        for node in ('wifi0', 'wifi1'):
            body = re.search(r'&' + node + r'\s*\{(.*?)\n};', text, re.S).group(1)
            self.assertIn(property_name, body)
            self.assertIn('qcom,ath12k-disable-mlo;', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
