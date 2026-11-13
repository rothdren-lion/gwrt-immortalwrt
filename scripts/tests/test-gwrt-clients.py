#!/usr/bin/env python3
"""Exercise client presence, lease reuse and offline expiry with BusyBox awk."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MERGER = ROOT / "gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/gwrt/clients-merge.awk"
if not MERGER.exists():
    MERGER = ROOT / "package/gwrt-theme/luci-theme-gwrt/root/usr/share/gwrt/clients-merge.awk"
NOW = 1_800_000_000
MAC = "aa:bb:cc:dd:ee:01"
OTHER = "aa:bb:cc:dd:ee:02"


def client(mac=MAC, **updates):
    row = dict(mac=mac, ip="192.168.9.100", host="phone", online=False,
               first_seen=NOW - 1000, last_seen=NOW - 60, offline_at=NOW - 50,
               via="wifi5gh", port="phy0-ap0", os="android")
    row.update(updates)
    return row


class ClientsTest(unittest.TestCase):
    def merge(self, rows=(), active="", dhcp="", ports="", now=NOW, updated=NOW - 30):
        results = []
        engines = [["awk"]]
        if shutil.which("busybox"):
            engines.append(["busybox", "awk"])
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "clients.json"
            state.write_text(json.dumps(dict(updated=updated, clients=list(rows)), separators=(",", ":")))
            for engine in engines:
                args = engine + ["-v", f"state_file={state}", "-v", f"now={now}",
                                 "-v", "retention=86400", "-v", f"active={active}",
                                 "-v", f"dhcp={dhcp}", "-v", f"port_data={ports}",
                                 "-v", 'wan_json={"type":"pppoe"}',
                                 "-f", str(MERGER)]
                result = json.loads(subprocess.check_output(args, text=True))
                self.assertEqual(result["offline_retention"], 86400)
                self.assertEqual(result["wan"], {"type": "pppoe"})
                results.append({row["mac"]: row for row in result["clients"]})
                self.assertEqual(len(results[-1]), len(result["clients"]), "duplicate MAC output")
        for result in results[1:]:
            self.assertEqual(result, results[0])
        return results[0]

    def test_unexpired_lease_does_not_create_device(self):
        self.assertEqual(self.merge(dhcp=f"{MAC}|192.168.9.100|phone"), {})

    def test_expired_device_stays_removed_with_lease_present(self):
        lease = f"{MAC}|192.168.9.100|phone"
        expired = client(last_seen=NOW - 86400, offline_at=NOW - 86390)
        self.assertEqual(self.merge([expired], dhcp=lease), {})
        self.assertEqual(self.merge(dhcp=lease, now=NOW + 10), {})

    def test_retains_recent_offline_until_exact_deadline(self):
        row = client(last_seen=NOW - 86399)
        self.assertIn(MAC, self.merge([row]))
        self.assertEqual(self.merge([row], now=NOW + 1), {})

    def test_expiry_does_not_reset_duration_or_offline_time(self):
        row = client()
        result = self.merge([row])[MAC]
        self.assertEqual(result["first_seen"], row["first_seen"])
        self.assertEqual(result["last_seen"], row["last_seen"])
        self.assertEqual(result["offline_at"], row["offline_at"])
        self.assertEqual(result["ip"], row["ip"])

    def test_normalizes_and_merges_duplicate_mac(self):
        old = client(mac=MAC.upper(), last_seen=NOW - 300, host="older")
        new = client(host="newer")
        for rows in ([old, new], [new, old]):
            result = self.merge(rows)
            self.assertEqual(list(result), [MAC])
            self.assertEqual(result[MAC]["host"], "newer")

    def test_live_observation_overrides_history_and_restores_connection(self):
        result = self.merge([client(last_seen=NOW - 90000)],
                            active=f"{MAC.upper()}|-|wifi5gh|-55")[MAC]
        self.assertTrue(result["online"])
        self.assertEqual(result["first_seen"], NOW)
        self.assertEqual(result["last_seen"], NOW)
        self.assertEqual(result["offline_at"], 0)
        self.assertEqual(result["signal"], "-55")

    def test_ip_reuse_removes_old_offline_owner(self):
        result = self.merge([client()], active=f"{OTHER}|192.168.9.100|wired")
        self.assertEqual(list(result), [OTHER])

    def test_two_online_macs_with_same_ip_are_preserved(self):
        result = self.merge(active=f"{MAC}|192.168.9.100|wired\n{OTHER}|192.168.9.100|wired")
        self.assertEqual(set(result), {MAC, OTHER})
        self.assertTrue(all(row["online"] for row in result.values()))

    def test_stale_wifi_lease_does_not_claim_current_neighbors_ip(self):
        result = self.merge(active=f"{MAC}|-|wifi5gh|-60\n{OTHER}|192.168.9.100|wired",
                            dhcp=f"{MAC}|192.168.9.100|phone")
        self.assertEqual(set(result), {MAC, OTHER})
        self.assertTrue(result[MAC]["online"])
        self.assertEqual(result[MAC]["ip"], "")
        self.assertEqual(result[OTHER]["ip"], "192.168.9.100")

    def test_ipv6_does_not_replace_active_ipv4(self):
        result = self.merge(active=f"{MAC}|192.168.9.100|wired\n{MAC}|2001:db8::1|wired")[MAC]
        self.assertEqual(result["ip"], "192.168.9.100")

    def test_prefers_current_dhcp_address_when_mac_has_two_addresses(self):
        result = self.merge(active=f"{MAC}|192.168.9.100|wired\n{MAC}|192.168.9.101|wired",
                            dhcp=f"{MAC}|192.168.9.100|phone")[MAC]
        self.assertEqual(result["ip"], "192.168.9.100")

    def test_old_cache_without_per_device_timestamps_expires(self):
        row = dict(mac=MAC, ip="192.168.9.100", online=False)
        result = self.merge([row], updated=NOW - 86399)
        self.assertEqual(result[MAC]["last_seen"], NOW - 86399)
        self.assertEqual(self.merge(result.values(), now=NOW + 1), {})

    def test_current_lan_port_replaces_previous_port(self):
        result = self.merge([client(via="wired", port="lan1")],
                            active=f"{MAC}|192.168.9.100|wired", ports=f"{MAC}|lan2")[MAC]
        self.assertEqual(result["port"], "lan2")

    def test_wifi_association_overrides_stale_fdb(self):
        result = self.merge([client(via="wired", port="lan2")],
                            active=f"{MAC}|192.168.9.100|wired\n{MAC}|-|wifi24g|-53|phy1-ap0",
                            ports=f"{MAC}|lan2")[MAC]
        self.assertEqual((result["via"], result["port"], result["signal"]),
                         ("wifi24g", "phy1-ap0", "-53"))

    def test_current_association_replaces_previous_radio(self):
        result = self.merge([client()], active=f"{MAC}|-|wifi6g|-58|phy2-ap0")[MAC]
        self.assertEqual((result["via"], result["port"]), ("wifi6g", "phy2-ap0"))

    def test_live_device_without_fdb_does_not_reuse_old_port(self):
        result = self.merge([client()], active=f"{MAC}|192.168.9.100|wired")[MAC]
        self.assertEqual(result["port"], "")

    def test_offline_device_keeps_last_observed_port(self):
        result = self.merge([client()], ports=f"{MAC}|lan3")[MAC]
        self.assertEqual(result["port"], "phy0-ap0")

    def test_assoc_collector_pairs_each_mac_signal_and_interface(self):
        source = MERGER.with_name("clients.sh").read_text()
        code = re.search(r'awk -v t="\$tag" -v iface="\$phy" \'(.*?)\'\n\tdone', source, re.S)
        self.assertIsNotNone(code)
        station_json = json.dumps({"results": [
            {"mac": MAC.upper(), "signal": -48, "rx": {"rate": 2401000}},
            {"mac": OTHER, "signal": -72},
            {"mac": "invalid", "signal": -10},
        ]}, indent="\t")
        engines = [["awk"]]
        if shutil.which("busybox"):
            engines.append(["busybox", "awk"])
        for engine in engines:
            result = subprocess.check_output(engine + ["-v", "t=wifi5gh", "-v", "iface=phy0-ap0",
                                                        code[1]], input=station_json, text=True)
            self.assertEqual(result.splitlines(), [f"{MAC}|-|wifi5gh|-48|phy0-ap0",
                                                   f"{OTHER}|-|wifi5gh|-72|phy0-ap0"])


if __name__ == "__main__":
    unittest.main()
