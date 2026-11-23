#!/usr/bin/env python3
"""Exercise the production agent with target JSON tools and isolated RPC fixtures."""
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

    def setUp(self):
        self.state = self.path / self._testMethodName
        self.state.mkdir()

    def shell(self, code):
        prefix = self.library + "\nJSON_HELPER=" + shlex.quote(str(HELPER)) + "\n"
        prefix += "STATE_DIR=" + shlex.quote(str(self.state)) + "\n"
        prefix += "log(){ :; }; did(){ echo test-device; }; cfg(){ case \"$1\" in report_interval) echo \"${TEST_INTERVAL:-30}\";; mesh_control) echo 1;; esac; };\n"
        return subprocess.check_output(["busybox", "sh", "-c", prefix + code], env=self.env, text=True).strip()

    def transport(self, code, *, direct=None, tunnel=None):
        scenario = self.state / "responses.json"
        scenario.write_text(json.dumps({
            "direct": direct or {"code": 200, "body": {"ok": True, "route": "ipv6"}},
            "tunnel": tunnel or {"code": 200, "body": {"ok": True, "route": "tunnel"}},
        }))
        mock = self.state / "curl.py"
        mock.write_text('''import json, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(__file__).parent
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(args) + '\\n')
url = args[-1]
route = 'direct' if 'op6.' in url or 'direct.' in url else 'tunnel'
response = json.loads((root / 'responses.json').read_text())[route]
body = response.get('body', '')
if not isinstance(body, str): body = json.dumps(body)
if '-o' in args:
    pathlib.Path(args[args.index('-o') + 1]).write_text(body)
    print(response.get('code', 0), end='')
else:
    print(body + '\\n__HTTP__' + str(response.get('code', 0)), end='')
if response.get('rc'): print('fixture transport failure', file=sys.stderr)
sys.exit(response.get('rc', 0))
''')
        setup = """
cfg(){
    case "$1" in
        endpoint) echo "${TEST_ENDPOINT:-https://op.gwrt.uk}";;
        endpoint_ipv6) [ -n "$TEST_ENDPOINT_IPV6" ] && echo "$TEST_ENDPOINT_IPV6";;
        prefer_ipv6) echo "${TEST_PREFER_IPV6:-1}";;
        pair_token) echo fixture-token;;
        *) return 1;;
    esac
}
ip(){ case "$*" in '-6 route show default') [ "$TEST_IPV6" != 0 ] && echo 'default via fe80::1 dev wan';; esac; }
"""
        setup += "curl(){ python3 " + shlex.quote(str(mock)) + ' "$@"; };\n'
        output = self.shell(setup + code)
        calls = self.state / "calls.jsonl"
        return output, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def test_transport_prefers_ipv6_with_existing_config(self):
        out, calls = self.transport("api /api/agent/pull '{}'")
        self.assertEqual(json.loads(out)["route"], "ipv6")
        self.assertEqual(len(calls), 1)
        self.assertIn('-6', calls[0])
        self.assertEqual(calls[0][-1], 'https://op6.gwrt.uk:8443/api/agent/pull')
        self.assertNotIn('-k', calls[0])
        self.assertNotIn('--insecure', calls[0])
        self.assertEqual(calls[0][calls[0].index('--connect-timeout') + 1], '2')
        self.assertEqual(calls[0][calls[0].index('-m') + 1], '4')

    def test_transport_failure_falls_back_and_recovers_after_cooldown(self):
        code = """
TEST_CLOCK=1000
date(){ echo "$TEST_CLOCK"; }
first=$(api /api/agent/pull '{}'); echo "$first"
second=$(api /api/agent/report '{}'); echo "$second"
TEST_CLOCK=1061
third=$(api /api/agent/pull '{}'); echo "$third"
"""
        out, calls = self.transport(code, direct={"rc": 6, "code": 0})
        self.assertEqual([json.loads(line)["route"] for line in out.splitlines()], ['tunnel'] * 3)
        self.assertEqual([('-6' in call) for call in calls], [True, False, False, True, False])
        self.assertTrue(all('-4' not in call for call in calls))
        self.assertTrue(all('Authorization: Bearer fixture-token' in call for call in calls))

    def test_transport_fallback_handles_tls_timeout_and_gateway_failure(self):
        for response in ({"rc": 28, "code": 0}, {"rc": 60, "code": 0},
                         {"code": 502, "body": '<html>Bad gateway</html>'},
                         {"code": 200, "body": '<html>Wrong upstream</html>'}):
            with self.subTest(response=response):
                out, calls = self.transport("rm -f \"$STATE_DIR/ipv6-retry\"; api /api/agent/report '{}'", direct=response)
                self.assertEqual(json.loads(out)["route"], "tunnel")
                self.assertEqual(calls[-1][-1], 'https://op.gwrt.uk/api/agent/report')

    def test_transport_auth_failure_does_not_retry_or_reset_identity(self):
        out, calls = self.transport("api /api/agent/ack '{}'; echo RC:$?",
                                    direct={"code": 401, "body": {"ok": False, "error": "bad token"}})
        self.assertIn('__API_FAIL__ http 401', out)
        self.assertTrue(out.endswith('RC:1'))
        self.assertEqual(len(calls), 1)

    def test_transport_semantic_rejection_does_not_retry(self):
        out, calls = self.transport("api /api/agent/register '{}'",
                                    direct={"code": 200, "body": {"ok": False, "error": "identity conflict"}})
        self.assertFalse(json.loads(out)['ok'])
        self.assertEqual(len(calls), 1)

    def test_transport_ipv4_only_and_disabled_ipv6_skip_direct(self):
        out, calls = self.transport("TEST_IPV6=0; api /api/agent/pull '{}'")
        self.assertEqual(json.loads(out)['route'], 'tunnel')
        self.assertEqual(len(calls), 1)
        out, calls = self.transport("TEST_PREFER_IPV6=0; api /api/agent/pull '{}'")
        self.assertEqual(json.loads(out)['route'], 'tunnel')
        self.assertEqual(len(calls), 2)

    def test_transport_custom_server_never_uses_official_ipv6(self):
        out, calls = self.transport("TEST_ENDPOINT=https://private.example/; api /api/agent/pull '{}'")
        self.assertEqual(json.loads(out)['route'], 'tunnel')
        self.assertEqual([call[-1] for call in calls], ['https://private.example/api/agent/pull'])

    def test_transport_custom_ipv6_endpoint_is_supported(self):
        out, calls = self.transport("TEST_ENDPOINT=https://private.example; TEST_ENDPOINT_IPV6=https://direct.example:9443/; api /api/agent/pull '{}'")
        self.assertEqual(json.loads(out)['route'], 'ipv6')
        self.assertEqual(calls[0][-1], 'https://direct.example:9443/api/agent/pull')

    def test_transport_both_links_failed_returns_failure(self):
        out, calls = self.transport("api /api/agent/pull '{}'; echo RC:$?",
                                    direct={"rc": 7, "code": 0}, tunnel={"rc": 28, "code": 0})
        self.assertIn('__API_FAIL__', out)
        self.assertTrue(out.endswith('RC:1'))
        self.assertEqual(len(calls), 2)
        self.assertNotIn('fixture-token', out)

    def test_daemon_reports_with_only_an_ipv6_default_route(self):
        record = self.state / 'reports'
        self.shell("ensure_device_id(){ :; }; ip(){ case \"$*\" in '-6 route show default') echo default;; esac; }; "
                   "handle_commands(){ :; }; do_report(){ echo report >> " + shlex.quote(str(record)) +
                   "; echo '{\"ok\":true}'; }; sleep(){ exit 0; }; daemon")
        self.assertTrue(record.exists())

    def test_transport_real_https_ipv6_fallback_and_recovery(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.server.requests.append((self.path, self.headers.get('Authorization'),
                                             self.rfile.read(int(self.headers['Content-Length']))))
                response = json.dumps({'ok': self.server.reply_code == 200,
                                       'route': self.server.route}).encode()
                self.send_response(self.server.reply_code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        class IPv6Server(ThreadingHTTPServer):
            address_family = socket.AF_INET6

        key, cert = self.state / 'test.key', self.state / 'test.crt'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ed25519', '-nodes', '-days', '1',
                        '-keyout', str(key), '-out', str(cert), '-subj', '/CN=direct.test',
                        '-addext', 'subjectAltName=DNS:direct.test,DNS:fallback.test'],
                       check=True, capture_output=True)
        servers = [IPv6Server(('::1', 0), Handler), ThreadingHTTPServer(('127.0.0.1', 0), Handler)]
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        for server, route in zip(servers, ('ipv6', 'tunnel')):
            server.socket = tls.wrap_socket(server.socket, server_side=True)
            server.reply_code, server.route, server.requests = 200, route, []
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
        for thread in threads:
            thread.start()
        direct, fallback = servers
        fixture = "cfg(){ case \"$1\" in endpoint) echo https://fallback.test:" + str(fallback.server_port)
        fixture += ";; endpoint_ipv6) echo https://direct.test:" + str(direct.server_port)
        fixture += ";; pair_token) echo fixture-token;; esac; }; ip(){ echo default; };\n"
        target_curl = SYSROOT / 'usr/bin/curl'
        curl_args = [QEMU, '-L', str(SYSROOT), str(target_curl)] if target_curl.exists() else ['curl']
        fixture += 'curl(){ command ' + shlex.join(curl_args) + ' --cacert ' + shlex.quote(str(cert))
        fixture += ' --resolve ' + shlex.quote('direct.test:' + str(direct.server_port) + ':[::1]')
        fixture += ' --resolve ' + shlex.quote('fallback.test:' + str(fallback.server_port) + ':127.0.0.1')
        fixture += ' "$@"; };\n'
        request = fixture + 'api /api/agent/pull \'{"device_id":"fixture"}\''
        try:
            self.assertEqual(json.loads(self.shell(request))['route'], 'ipv6')
            self.assertEqual(len(fallback.requests), 0)
            direct.reply_code = 503
            self.assertEqual(json.loads(self.shell(request))['route'], 'tunnel')
            direct.reply_code = 200
            self.assertEqual(json.loads(self.shell(request))['route'], 'tunnel')
            self.assertEqual(len(direct.requests), 2)  # Cooldown skips the restored direct link.
            (self.state / 'ipv6-retry').unlink()
            self.assertEqual(json.loads(self.shell(request))['route'], 'ipv6')
            self.assertEqual(len(direct.requests), 3)
            self.assertEqual(len(fallback.requests), 2)
            for server in servers:
                for path, auth, body in server.requests:
                    self.assertEqual(path, '/api/agent/pull')
                    self.assertEqual(auth, 'Bearer fixture-token')
                    self.assertEqual(json.loads(body), {'device_id': 'fixture'})
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()

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
