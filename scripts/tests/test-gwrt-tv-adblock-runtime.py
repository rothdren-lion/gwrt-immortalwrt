#!/usr/bin/env python3
"""Exercise the real init rule generator and DNS over IPv4/IPv6 UDP/TCP."""

import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "package/gwrt-tv-adblock"
INIT = PACKAGE / "files/etc/init.d/gwrt-tv-adblock"
LIBRARY = PACKAGE / "files/etc/gwrt-tv-adblock/ads-library.txt"
ROOTS = (
    "360.cn", "360safe.com", "360safe.cn", "qhupdate.com",
    "mayi360.cn", "ads360.cn", "360os.com",
)


def available_port():
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
        sock.bind(("::1", 0))
        return sock.getsockname()[1]


for binary in ("dnsmasq", "dig"):
    assert shutil.which(binary), f"{binary} is required for real DNS tests"

with tempfile.TemporaryDirectory(prefix="gwrt-adblock-test-") as folder:
    base = Path(folder)
    lib = base / "ads-library.txt"
    dnsconf = base / "dnsmasq.conf"
    lib.write_bytes(LIBRARY.read_bytes())
    dnsconf.write_text("# unrelated configuration must survive\n")
    mockbin = base / "bin"
    mockbin.mkdir()
    for name, body in {
        "uci": 'case "$*" in *custom_allow) printf "%s\\n" "$TEST_ALLOW";; esac\nexit 0\n',
        "logger": "exit 0\n",
        "sync": "exit 0\n",
        "pgrep": "exit 1\n",
    }.items():
        path = mockbin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
    env = {**os.environ, "PATH": str(mockbin) + ":" + os.environ["PATH"]}

    def apply(action="apply_mode", allow=""):
        # Source unchanged production functions; isolate all mutable paths and
        # skip legacy system cleanup, which is unrelated to these regressions.
        script = '''. "$1"
DNSCONF="$2/dnsmasq.conf"
LIB_ETC="$2/ads-library.txt"
LIB_SHARE="$2/template.txt"
RULES_TMP="$2/rules.tmp"
cleanup_legacy() { :; }
"$3"
'''
        return subprocess.run(
            ["sh", "-c", script, "test", str(INIT), str(base), action],
            env={**env, "TEST_ALLOW": allow}, capture_output=True, text=True,
        )

    result = apply()
    assert result.returncode == 0, result.stderr
    rules = dnsconf.read_text()
    assert rules.startswith("# unrelated configuration must survive\n")
    for domain in ROOTS:
        assert rules.count(f"address=/{domain}/\n") == 1, domain
    assert "address=/hao123.com/" in rules
    assert "address=/api.ad.xiaomi.com/" in rules

    # Upgrade with a preserved pre-360 conffile must keep custom categories and
    # old service configuration, add the missing roots, and remain idempotent.
    old = "# preserved user library\n[tv]\nlegacy-ad.example\n[user]\nkeep-user.example\n[kill]\nhao123.com\n"
    lib.write_text(old)
    result = apply()
    assert result.returncode == 0, result.stderr
    assert lib.read_text().startswith(old)
    assert (base / "ads-library.txt.before-360").read_text() == old
    migrated = lib.read_bytes()
    assert "address=/legacy-ad.example/" in dnsconf.read_text()
    assert apply().returncode == 0
    assert lib.read_bytes() == migrated, "migration must be idempotent"

    # A malformed replacement cannot erase active rules or report success.
    previous = dnsconf.read_bytes()
    lib.write_text("not a categorized library\n")
    assert apply("reload").returncode != 0
    assert dnsconf.read_bytes() == previous

    lib.write_bytes(LIBRARY.read_bytes())
    assert apply(allow="360safe.com").returncode == 0
    assert "address=/360safe.com/" not in dnsconf.read_text()
    assert "server=/360safe.com/#" in dnsconf.read_text()
    assert apply().returncode == 0
    rules = dnsconf.read_text()

    port = available_port()
    runtime = base / "runtime.conf"
    runtime.write_text(
        f"port={port}\nlisten-address=127.0.0.1,::1\nbind-interfaces\n"
        "no-resolv\nno-hosts\n"
        "host-record=allowed.example,192.0.2.10,2001:db8::10\n" + rules
    )
    logfile = (base / "dnsmasq.log").open("w+")
    proc = subprocess.Popen(
        ["dnsmasq", "--keep-in-foreground", "--conf-file=" + str(runtime),
         "--user=" + pwd.getpwuid(os.geteuid()).pw_name,
         "--pid-file=" + str(base / "dnsmasq.pid"), "--log-facility=-"],
        stdout=logfile, stderr=subprocess.STDOUT,
    )
    count = 0

    def query(host, domain, qtype, tcp=False):
        command = ["dig", "-6" if ":" in host else "-4", "@" + host,
                   "-p", str(port), domain, qtype, "+time=1", "+tries=1",
                   "+noall", "+comments", "+answer"]
        if tcp:
            command.append("+tcp")
        return subprocess.run(command, capture_output=True, text=True, timeout=3)

    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                logfile.seek(0)
                raise AssertionError(logfile.read())
            if query("::1", "allowed.example", "AAAA").returncode == 0:
                break
            time.sleep(.05)
        else:
            raise AssertionError("temporary dnsmasq did not start")
        for host in ("127.0.0.1", "::1"):
            for tcp in (False, True):
                for domain in ROOTS:
                    for name in (domain, "www." + domain, "nested.ad." + domain):
                        for qtype in ("A", "AAAA"):
                            response = query(host, name, qtype, tcp)
                            assert response.returncode == 0, response.stderr
                            assert "status: NXDOMAIN" in response.stdout, (host, tcp, name, qtype, response.stdout)
                            count += 1
                for qtype, address in (("A", "192.0.2.10"), ("AAAA", "2001:db8::10")):
                    response = query(host, "allowed.example", qtype, tcp)
                    assert "status: NOERROR" in response.stdout and address in response.stdout, response.stdout
                    count += 1
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        logfile.close()

print(f"PASS production rules: {count} IPv4/IPv6 UDP/TCP DNS queries, upgrade migration, allow list and failure preservation")
