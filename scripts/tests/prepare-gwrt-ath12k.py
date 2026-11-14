#!/usr/bin/env python3
"""Prepare ath12k sources for host tests without building target firmware.

Use the package's hash-checked source archive and apply its ath12k patches in
order with zero fuzz. Non-ath12k hunks are excluded; the full OpenWrt prepare
and target compilation remain mandatory in the firmware build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("backports_archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    makefile = (args.repository / "package/kernel/mac80211/Makefile").read_text()
    version = re.search(r"^PKG_SOURCE_VERSION:=(\S+)$", makefile, re.M).group(1)
    expected = re.search(r"^PKG_HASH:=(\S+)$", makefile, re.M).group(1)
    with args.backports_archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise SystemExit(f"backports source SHA-256 mismatch: {actual}")
    args.destination.mkdir(parents=True, exist_ok=False)
    prefix = f"backports-{version}/drivers/net/wireless/ath/ath12k/"
    with subprocess.Popen(["zstd", "-dc", str(args.backports_archive)], stdout=subprocess.PIPE) as unpack:
        with tarfile.open(fileobj=unpack.stdout, mode="r|") as archive:
            for member in archive:
                if member.name.startswith(prefix) and member.isfile():
                    archive.extract(member, args.destination, filter="data")
        if unpack.wait():
            raise SystemExit("failed to decompress backports archive")

    prepared = args.destination / f"backports-{version}"
    records = []
    for patch in sorted((args.repository / "package/kernel/mac80211/patches/ath12k").glob("*.patch")):
        blocks = re.split(r"(?=^--- (?:a/|/dev/null))", patch.read_text(), flags=re.M)
        selected = []
        for block in blocks:
            paths = re.findall(r"^(?:--- a/|\+\+\+ b/)([^\s]+)", block, re.M)
            if paths and all(path.startswith("drivers/net/wireless/ath/ath12k/") for path in paths):
                selected.append(block)
        if not selected:
            continue
        result = subprocess.run(["patch", "--batch", "--fuzz=0", "-p1"], cwd=prepared,
                                input="".join(selected), text=True, capture_output=True)
        records.append(dict(patch=patch.name, returncode=result.returncode,
                            output=result.stdout + result.stderr))
        if result.returncode:
            raise SystemExit(str(records[-1]))
    (args.destination / "patch-application.json").write_text(json.dumps(records, indent=2) + "\n")
    print(f"PASS backports source SHA-256: {actual}")
    print(f"PASS {len(records)} ath12k patches applied with zero fuzz: {prepared}")


if __name__ == "__main__":
    main()
