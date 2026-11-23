#!/usr/bin/env python3
"""Forward adblock library names to dnsmasq through a daed DNS policy.

Run from an admin workstation over root SSH. Secrets stay in memory or a
private temporary SQLite copy; no router Python dependency is introduced.
Rule additions require another sync. Existing category switches are evaluated
by dnsmasq; positive daed/client DNS caches may delay a switch taking effect.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time


def domain_set(library, custom):
    candidates = [line.split()[0] for line in library.splitlines()
                  if line.strip() and not line.lstrip().startswith(("#", "["))]
    candidates.extend(custom.split())
    domains = {d.lower().lstrip(".") for d in candidates}
    domains = {d for d in domains if re.fullmatch(r"[a-z0-9][a-z0-9_.-]*\.[a-z0-9_.-]+", d)
               and ".." not in d and not d.endswith((".", "-"))}
    return sorted(d for d in domains if not any(
        d.endswith("." + parent) for parent in domains if d != parent))


def delegated_policy(current, domains):
    current = re.sub(
        r"(?m)^\s*# GWRT-ADBLOCK-BEGIN.*?^\s*# GWRT-ADBLOCK-END\s*\n",
        "", current, flags=re.S | re.M)
    if "gwrt_adblock:" in current:
        raise RuntimeError("Unmanaged gwrt_adblock upstream already exists")
    upstream = "\n    # GWRT-ADBLOCK-BEGIN upstream\n" \
               "    gwrt_adblock: 'tcp+udp://127.0.0.1:53'\n" \
               "    # GWRT-ADBLOCK-END\n"
    rule = "\n    # GWRT-ADBLOCK-BEGIN request\n    qname(" + ", ".join(
        "suffix: " + d for d in domains) + ") -> gwrt_adblock\n    # GWRT-ADBLOCK-END\n"
    current, n_upstream = re.subn(r"\bupstream\s*\{", lambda m: m[0] + upstream, current, count=1)
    current, n_request = re.subn(r"\brequest\s*\{", lambda m: m[0] + rule, current, count=1)
    if (n_upstream, n_request) != (1, 1):
        raise RuntimeError("Expected one existing upstream and DNS request block")
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-target", required=True, help="Root SSH target, e.g. root@192.168.9.9")
    parser.add_argument("--known-hosts", type=Path)
    parser.add_argument("--state-dir", type=Path, required=True, help="Private backup directory outside the repository")
    parser.add_argument("--check", action="store_true", help="Compare without changing the router")
    parser.add_argument("--restore", action="store_true", help="Restore this directory's original selected DNS policy")
    args = parser.parse_args()
    os.umask(0o077)
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.state_dir.stat().st_mode & 0o077:
        raise RuntimeError("State directory must have mode 0700")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if args.known_hosts:
        ssh += ["-o", "UserKnownHostsFile=" + str(args.known_hosts)]
    ssh.append(args.ssh_target)

    def remote(command, data=None):
        return subprocess.run(ssh + [command], input=data, capture_output=True,
                              check=True, timeout=50).stdout

    with tempfile.NamedTemporaryFile() as copy:
        copy.write(remote("cat /etc/daed/wing.db"))
        copy.flush()
        with sqlite3.connect(copy.name) as db:
            username, secret = db.execute("select username,jwt_secret from users limit 1").fetchone()
    b64 = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=")
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(json.dumps({"role": "admin", "sub": username,
                              "exp": int(time.time()) + 300}, separators=(",", ":")).encode())
    unsigned = header + b"." + payload
    token = (unsigned + b"." + b64(hmac.new(secret.encode(), unsigned, hashlib.sha256).digest())).decode()

    def api(query, variables=None):
        body = json.dumps({"query": query, "variables": variables or {}}, separators=(",", ":"))
        config = 'url = "http://127.0.0.1:2023/graphql"\nheader = "Content-Type: application/json"\n'
        config += "header = " + json.dumps("Authorization: Bearer " + token) + "\n"
        config += "data = " + json.dumps(body) + "\n"
        response = json.loads(remote("curl -fsS --max-time 35 --config -", config.encode()))
        if response.get("errors"):
            (args.state_dir / "api-error.private.json").write_text(json.dumps(response["errors"]))
            raise RuntimeError("daed API rejected the operation; details saved privately")
        return response["data"]

    records = api("{dnss(selected:true){id name selected dns{string}}}")["dnss"]
    if len(records) != 1:
        raise RuntimeError("Expected one selected daed DNS policy")
    current = records[0]
    before_path = args.state_dir / "dns-policy.before.private.json"
    if args.restore:
        original = json.loads(before_path.read_text())["data"]["dnss"][0]
        if current["id"] != original["id"]:
            raise RuntimeError("Selected DNS policy changed; refusing to restore another policy")
        proposed = original["dns"]["string"]
    else:
        library = remote("cat /etc/gwrt-tv-adblock/ads-library.txt").decode()
        custom = remote("uci -q get gwrt-tv-adblock.config.custom_block || :").decode()
        domains = domain_set(library, custom)
        if not domains:
            raise RuntimeError("No adblock domains found")
        proposed = delegated_policy(current["dns"]["string"], domains)
        print(f"Delegated domain suffixes: {len(domains)}")
    if proposed == current["dns"]["string"]:
        print("DNS policy unchanged")
        return
    if args.check:
        print("DNS policy needs synchronization; router unchanged")
        return
    if not before_path.exists():
        before_path.write_text(json.dumps({"data": {"dnss": records}}, indent=2) + "\n")
    (args.state_dir / "dns-policy.proposed.private.txt").write_text(proposed)
    mutation = "mutation($id:ID!,$dns:String!){updateDns(id:$id,dns:$dns){id}}"
    api(mutation, {"id": current["id"], "dns": proposed})
    try:
        api("mutation{run(dry:false)}")
    except Exception:
        api(mutation, {"id": current["id"], "dns": current["dns"]["string"]})
        api("mutation{run(dry:false)}")
        raise
    print("Selected DNS policy applied; daemon process retained")


if __name__ == "__main__":
    main()
