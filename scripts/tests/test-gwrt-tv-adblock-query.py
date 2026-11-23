#!/usr/bin/env python3
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "package/gwrt-tv-adblock"
HELPER = PACKAGE / "files/usr/libexec/gwrt-tv-adblock-query"
LIBRARY = PACKAGE / "files/etc/gwrt-tv-adblock/ads-library.txt"


def parse(response: str) -> str:
    result = subprocess.run(
        [str(HELPER), "--parse"], input=response, text=True,
        capture_output=True, check=True,
    )
    return result.stdout.strip()


library = LIBRARY.read_text()
sections = {}
current = None
for line in library.splitlines():
    match = re.fullmatch(r"\[([^]]+)\]", line)
    if match:
        current = match.group(1)
        sections[current] = []
    elif current and line.strip() and not line.lstrip().startswith("#"):
        sections[current].append(line.strip())

section = re.search(r"^\[360\]\n(.*?)(?=^\[|\Z)", library, re.M | re.S)
assert section, "missing 360 rule category"
roots = {
    line.strip() for line in section.group(1).splitlines()
    if line.strip() and not line.lstrip().startswith("#")
}
expected = {
    "360.cn", "360safe.com", "360safe.cn", "qhupdate.com",
    "mayi360.cn", "ads360.cn", "360os.com",
}
assert roots == expected, f"unexpected 360 category roots: {sorted(roots)}"
counts = {name: len(domains) for name, domains in sections.items()}
assert counts == {"tv": 218, "tv-ext": 115, "cn": 148, "360": 7, "sec": 30, "kill": 4}, counts
assert sum(counts.values()) == 522
assert "分类条目: tv=218 tv-ext=115 cn=148 360=7 sec=30 kill=4" in library
assert "option cat_360 '1'" in (PACKAGE / "files/etc/config/gwrt-tv-adblock").read_text()

assert parse("Name: www.360.cn\nAddress: 93.184.216.34\n") == "unblocked"
assert parse("Name: www.360.cn\nAddress 1: 2001:db8::1\n") == "unblocked"
assert parse("nslookup: can't resolve 'www.360.cn': Non-existent domain\n") == "blocked"
assert parse("Name: ipv4-only.example\n") == "no-record"
assert parse("nslookup: read: Connection refused\n") == "dns-error"
assert parse("") == "unknown"

print("PASS 360 A/AAAA rule coverage and BusyBox DNS response classification")
