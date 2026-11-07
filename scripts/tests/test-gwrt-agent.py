#!/usr/bin/env python3
"""Exercise the production agent with target JSON tools and isolated RPC fixtures."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SYSROOT = Path(os.environ.get("GWRT_TEST_SYSROOT", "/home/godsun/build/immortalwrt-mt7981/staging_dir/target-aarch64_cortex-a53_musl/root-mediatek"))
QEMU = shutil.which("qemu-aarch64")
SOURCE = ROOT / "package/gwrt-agent/files/usr/sbin/gwrt-agent"
HELPER = ROOT / "package/gwrt-agent/files/usr/share/gwrt-agent/json.uc"


class Agent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not QEMU or not (SYSROOT / "usr/bin/ucode").exists():
            raise RuntimeError("GWRT_TEST_SYSROOT needs a target root with ucode/jsonfilter; qemu-aarch64 is required")
        cls.temp = tempfile.TemporaryDirectory(prefix="gwrt-agent-test-")
        cls.path = Path(cls.temp.name)
        for name in ("jsonfilter", "ucode"):
            args = [QEMU, "-L", str(SYSROOT), str(SYSROOT / "usr/bin" / name)]
            if name == "ucode":
                args += ["-L", str(SYSROOT / "usr/lib/ucode")]
            p = cls.path / name
            p.write_text("#!/bin/sh\nexec " + shlex.join(args) + ' "$@"\n')
            p.chmod(0o755)
        cls.env = dict(os.environ, PATH=str(cls.path) + ":" + os.environ["PATH"])
        cls.library = SOURCE.read_text().split('case "${1:-daemon}" in')[0]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def shell(self, code):
        prefix = self.library + "\nJSON_HELPER=" + shlex.quote(str(HELPER)) + "\n"
        prefix += "log(){ :; }; did(){ echo test-device; }; cfg(){ case \"$1\" in report_interval) echo \"${TEST_INTERVAL:-30}\";; mesh_control) echo 1;; esac; };\n"
        return subprocess.check_output(["busybox", "sh", "-c", prefix + code], env=self.env, text=True).strip()

    def helper(self, mode, *args):
        return json.loads(subprocess.check_output([str(self.path / "ucode"), str(HELPER), mode, *map(str, args)], env=self.env, text=True))

    def test_interval_handles_pretty_json_and_invalid_config(self):
        self.assertEqual(self.shell("interval_of '{\"report_interval\": 0}'"), "5")
        self.assertEqual(self.shell("TEST_INTERVAL=garbage; interval_of '{}'"), "30")
        self.assertEqual(self.shell("TEST_INTERVAL=1; interval_of '{}'"), "5")

    def test_no_binary_still_reports_identity_and_mesh(self):
        d = json.loads(self.shell("ORIG=/nonexistent; ubus(){ echo '{}'; }; payload"))
        self.assertEqual(d["device_id"], "test-device")
        self.assertIn("gwrt_mesh", d)
        self.assertEqual(d["arch"], os.uname().machine)

    def test_payload_removes_only_root_hardware_id(self):
        for obj in ({"hardware_id": "x", "a": "quote\"\n"}, {"a": 1, "hardware_id": "x"}, {"hardware_id": "x"}):
            p = self.path / "payload.json"
            p.write_text(json.dumps(obj, indent=2))
            d = self.helper("payload", p, "id", "mipsel", "firmware", '{"available":false}')
            self.assertNotIn("hardware_id", d)
            self.assertEqual(d["device_id"], "id")
            if "a" in obj:
                self.assertEqual(d["a"], obj["a"])

    def test_mesh_preserves_ssids_and_excludes_credentials(self):
        st = {"role": "cap", "mac": "02:00:00:00:00:01", "peers_online": 1, "roam": {"ssids": ["SSID with spaces", "quote\"\n"]}, "backhaul": {"key": "NEVER-EXPOSE"}}
        disc = {"devices": [{"mac": "02:00:00:00:00:02", "ip": "192.0.2.2", "name": "AP\"test", "model": "test", "nonce": "NEVER-EXPOSE"}]}
        d = self.helper("mesh", json.dumps(st), json.dumps(disc), '{"nodes":[]}', "0")
        self.assertEqual(d["ssids"], st["roam"]["ssids"])
        self.assertEqual(d["discover"], ["02:00:00:00:00:02"])
        self.assertTrue(d["discovered_devices"][0]["pairable"])
        self.assertNotIn("NEVER-EXPOSE", json.dumps(d))

    def command(self, cmd, rpc):
        return self.shell("sleep(){ :; }; do_ack(){ echo ACK:$2; }; ubus(){ " + rpc + "; }; run_command " + shlex.quote(json.dumps(cmd, separators=(",", ":"))))

    def test_pair_rejection_is_not_acknowledged_as_success(self):
        out = self.command({"action": "mesh.pair", "command_id": "t", "mac": "02:00:00:00:00:02"}, "echo '{\"ok\":false,\"error\":\"not_found\"}'")
        self.assertIn("ACK:failed", out)
        self.assertNotIn("ACK:success", out)

    def test_pair_acceptance_without_join_is_failure(self):
        out = self.command({"kind": "mesh.pair", "id": "t", "params": {"mac": "02:00:00:00:00:02"}}, "echo '{\"ok\":true,\"nodes\":[]}'")
        self.assertIn("ACK:failed", out)

    def test_pair_success_requires_authenticated_node(self):
        nodes = {"ok": True, "nodes": [{"type": "ap", "mac": "02:00:00:00:00:02", "authed": True, "online": True, "role": "sap"}]}
        out = self.command({"kind": "mesh.pair", "id": "t", "payload": {"mac": "02:00:00:00:00:02"}}, "echo " + shlex.quote(json.dumps(nodes)))
        self.assertIn("ACK:success", out)

    def test_set_sap_rejection_is_failure(self):
        out = self.command({"action": "mesh.role", "command_id": "t", "role": "sap"}, "echo '{\"ok\":false,\"error\":\"sap_via_pairing\"}'")
        self.assertIn("ACK:failed", out)

    def test_ssid_sync_retains_existing_roam_policy(self):
        st = {"role": "cap", "roam": {"enabled": True, "ssids": ["SSID with spaces"], "rssi_profile": "gentle", "rssi_threshold": -80, "ft_mode": "explicit"}}
        record = self.path / "ssid-rpc.json"
        rpc = "case \"$*\" in *status*) echo " + shlex.quote(json.dumps(st)) + ";; *set_roam*) printf '%s\\n' \"$*\" > " + shlex.quote(str(record)) + "; echo '{\"ok\":true}';; esac"
        out = self.command({"action": "mesh.ssid_sync", "id": "t"}, rpc)
        out += record.read_text()
        self.assertIn("gentle", out)
        self.assertIn("-80", out)
        self.assertNotIn("balanced", out)

    def test_pretty_nested_command_batch(self):
        commands = {"commands": [{"action": "mesh.role", "command_id": "first", "params": {"role": "sap"}}, {"kind": "mesh.role", "id": "second", "params": {"role": "invalid"}}]}
        out = self.shell("do_pull(){ echo " + shlex.quote(json.dumps(commands, indent=2)) + "; }; do_ack(){ echo ACK:$1:$2; }; ubus(){ echo '{\"ok\":false}'; }; handle_commands")
        self.assertIn("ACK:first:failed", out)
        self.assertIn("ACK:second:failed", out)

    def test_random_token_has_requested_length(self):
        value = self.shell("rand_hex 48")
        self.assertRegex(value, r"^[0-9a-f]{48}$")

    def test_pull_receives_active_refresh_interval(self):
        out = self.shell("do_pull(){ echo '{\"ok\":true,\"report_interval\":5,\"commands\":[]}'; }; handle_commands; echo INTERVAL:$GWRT_PULL_INTERVAL")
        self.assertIn("INTERVAL:5", out)

    def test_idle_agent_wakes_without_waiting_ten_minutes(self):
        record = self.path / "reports.txt"
        record.unlink(missing_ok=True)
        self.shell("TEST_CLOCK=0; ensure_device_id(){ :; }; ip(){ echo default; }; date(){ echo $TEST_CLOCK; }; "
                   "do_report(){ echo $TEST_CLOCK >> " + shlex.quote(str(record)) + "; echo '{\"ok\":true,\"report_interval\":600}'; }; "
                   "handle_commands(){ if [ $TEST_CLOCK -ge 10 ]; then GWRT_PULL_INTERVAL=5; else GWRT_PULL_INTERVAL=600; fi; }; "
                   "sleep(){ TEST_CLOCK=$((TEST_CLOCK+$1)); [ $TEST_CLOCK -lt 21 ] || exit 0; }; daemon")
        self.assertEqual(record.read_text().splitlines(), ["0", "10", "15", "20"])

    def test_mac_must_be_one_complete_value(self):
        self.assertEqual(self.shell("valid_mac '02:00:00:00:00:02\ninjected' && echo valid || echo invalid"), "invalid")

    def test_report_failure_preserves_binding(self):
        out = self.shell("payload(){ echo '{}'; }; api(){ echo '{\"ok\":false,\"error\":\"unknown device or token\"}'; }; reset_identity(){ echo UNEXPECTED_RESET; }; do_report")
        self.assertNotIn("UNEXPECTED_RESET", out)

    def test_mesh_members_and_legacy_status_agree(self):
        st = {"role": "cap", "mac": "02:00:00:00:00:01", "name": "Main", "peers_online": 1}
        topo = {"self": "020000000001", "nodes": [
            {"id": "020000000001", "type": "ap", "role": "cap", "authed": True},
            {"id": "020000000002", "type": "ap", "role": "sap", "authed": True},
            {"id": "020000000003", "type": "ap", "role": "sap", "authed": False},
            {"id": "020000000004", "type": "client", "parent": "020000000002"}]}
        d = self.helper("mesh-status", json.dumps(st), '{"devices":[]}', json.dumps(topo), "0", "192.0.2.1", "", "2026-11-07")
        self.assertEqual(d["active_node_count"], 1)
        self.assertEqual(len(d["peers"]), 1)
        self.assertEqual(d["peers"][0]["clients"], 1)

    def test_native_binding_command_retains_result(self):
        native = self.path / "native-agent"
        native.write_text('#!/bin/sh\ncat >/dev/null\nprintf \'Content-Type: application/json\\r\\n\\r\\n{"ok":true,"result":"fixture-local-token"}\\n\'\n')
        native.chmod(0o755)
        out = self.shell('ORIG=' + shlex.quote(str(native)) + '; do_ack(){ printf "ACK:%s:%s\\n" "$2" "$3"; }; ubus(){ echo \'{"ipv4-address":[{"address":"192.0.2.1"}]}\'; }; run_command \'{"kind":"agent.issue_local_token","id":"token-test","payload":{}}\'')
        self.assertIn("ACK:success:fixture-local-token", out)

    def test_pair_retry_accepts_an_already_joined_member(self):
        topo = {"nodes": [{"type": "ap", "mac": "02:00:00:00:00:02", "authed": True, "role": "sap"}]}
        rpc = "case \"$*\" in *topology*) echo " + shlex.quote(json.dumps(topo)) + ";; *) echo '{\"ok\":false,\"error\":\"not_found\"}';; esac"
        out = self.command({"kind": "mesh.pair", "id": "retry", "payload": {"mac": "02:00:00:00:00:02"}}, rpc)
        self.assertIn("ACK:success", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
