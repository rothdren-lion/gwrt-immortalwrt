import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location("gwrt_release_server", os.environ.get("GWRT_CONTROL_SERVER", str(ROOT / "server.py")))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class Contract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gwrt-control-contract-")
        server.DB_PATH = Path(self.temp.name) / "test.sqlite3"
        with patch.dict(os.environ, {"GWRT_ADMIN_PASSWORD": "isolated-test-only", "GWRT_ADMIN_USER": "release-test"}):
            server.init_db()
        self.mesh = {"available": True, "role": "cap", "peers_online": 1,
                     "members": [{"mac": "02:00:00:00:00:03", "name": "Joined", "online": True}],
                     "discovered_devices": [{"mac": "02:00:00:00:00:02", "ip": "192.0.2.2", "name": "Candidate", "pairable": True}]}
        with server.db() as conn:
            owner = conn.execute("SELECT id FROM users LIMIT 1").fetchone()[0]
            other = conn.execute("INSERT INTO users(username,password_hash,created_at) VALUES('other','unused',?)", (server.now(),)).lastrowid
            for token, uid in (("owner-session", owner), ("other-session", other)):
                conn.execute("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)", (server.hash_token(token), uid, server.now()+3600))
            conn.execute("INSERT INTO devices(device_id,owner_id,pair_token_hash,mac,model,arch,agent_version,last_seen,mesh,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                         ("GWRT-release-test", owner, server.hash_token("device-token"), "02:00:00:00:00:01", "Test AP", "aarch64", 1712, server.now(), json.dumps(self.mesh), server.now(), server.now()))
        class QuietHandler(server.Handler):
            def log_message(self, *args):
                pass
        self.http = server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:%s" % self.http.server_port

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, path, payload=None, session="owner-session", csrf=True, agent=False):
        headers = {"Content-Type": "application/json"}
        if agent:
            headers["Authorization"] = "Bearer device-token"
        elif session:
            headers["Cookie"] = "gwrt_session=" + session
            if csrf:
                headers["X-GWRT-CSRF"] = server.csrf_token(session)
        req = Request(self.base+path, data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
        try:
            with urlopen(req, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            try:
                return error.code, json.load(error)
            finally:
                error.close()

    def stored_mesh(self):
        with server.db() as conn:
            return json.loads(conn.execute("SELECT mesh FROM devices WHERE device_id='GWRT-release-test'").fetchone()[0])

    def pair(self, mac="02:00:00:00:00:02", **options):
        return self.request("/api/devices/GWRT-release-test/commands", {"kind": "mesh.pair", "payload": {"mac": mac}}, **options)

    def test_new_mesh_report_is_stored_and_returned(self):
        code, _ = self.request("/api/agent/report", {"device_id": "GWRT-release-test", "gwrt_mesh": self.mesh, "mesh": {}}, agent=True)
        self.assertEqual(code, 200)
        self.assertEqual(self.stored_mesh(), self.mesh)
        code, data = self.request("/api/devices")
        self.assertEqual(code, 200)
        self.assertEqual(data["devices"][0]["mesh"], self.mesh)

    def test_missing_mesh_preserves_previous_report(self):
        self.assertEqual(self.request("/api/agent/report", {"device_id": "GWRT-release-test"}, agent=True)[0], 200)
        self.assertEqual(self.stored_mesh(), self.mesh)

    def test_invalid_mesh_is_rejected_without_replacement(self):
        self.assertEqual(self.request("/api/agent/report", {"device_id": "GWRT-release-test", "gwrt_mesh": []}, agent=True)[0], 400)
        self.assertEqual(self.stored_mesh(), self.mesh)

    def test_pair_flows_through_queue_pull_and_verified_ack(self):
        code, data = self.pair()
        self.assertEqual(code, 202, data)
        command_id = data["command_id"]
        code, pulled = self.request("/api/agent/pull", {"device_id": "GWRT-release-test"}, agent=True)
        self.assertEqual(code, 200)
        self.assertEqual(pulled["report_interval"], 5)
        self.assertEqual(pulled["commands"][0]["payload"], {"mac": "02:00:00:00:00:02"})
        self.assertEqual(pulled["commands"][0]["kind"], "mesh.pair")
        code, _ = self.request("/api/agent/ack", {"device_id": "GWRT-release-test", "command_id": command_id, "status": "success", "result": "joined"}, agent=True)
        self.assertEqual(code, 200)
        code, data = self.request("/api/commands/"+command_id)
        self.assertEqual(code, 200)
        self.assertEqual(data["command"]["status"], "success")

    def test_pair_rejects_absent_or_stale_candidate(self):
        self.assertEqual(self.pair("02:00:00:00:00:99")[0], 409)
        with server.db() as conn:
            conn.execute("UPDATE devices SET last_seen=?", (server.now()-181,))
        self.assertEqual(self.pair()[0], 409)

    def test_existing_owner_and_csrf_boundaries_remain(self):
        self.assertEqual(self.pair(csrf=False)[0], 403)
        self.assertIn(self.pair(session="other-session")[0], (403, 404))
        self.assertEqual(self.pair(session="")[0], 401)
        with server.db() as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM commands").fetchone()[0], 0)

    def test_invalid_command_inputs_are_rejected(self):
        for kind, payload in (("mesh.pair", {"mac": "02:00:00:00:00:02\nBAD"}), ("mesh.apmode", {}), ("mesh.apmode", {"enabled": 2}), ("mesh.role", {"role": "sap"})):
            with self.subTest(kind=kind, payload=payload):
                with self.assertRaises(server.RequestError):
                    server.validate_command(kind, payload)
        self.assertEqual(server.validate_command("mesh.unpair", {"mac": "02:00:00:00:00:02"}), {"mac": "02:00:00:00:00:02"})
        self.assertEqual(server.validate_command("mesh.ssid_sync", {}), {})


if __name__ == "__main__":
    unittest.main()
