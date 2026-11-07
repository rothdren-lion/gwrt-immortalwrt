#!/usr/bin/env python3
"""Run production roam/backhaul functions with real, isolated target ucode/UCI."""
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYSROOT = Path(os.environ.get("GWRT_TEST_SYSROOT", "/home/godsun/build/immortalwrt-mt7981/staging_dir/target-aarch64_cortex-a53_musl/root-mediatek"))
UCODE = SYSROOT / "usr/bin/ucode"
QEMU = shutil.which("qemu-aarch64")
if not QEMU or not UCODE.exists():
    raise SystemExit("Set GWRT_TEST_SYSROOT to an aarch64 target root with usr/bin/ucode; qemu-aarch64 is required")
SOURCE = (ROOT / "package/gwrt-device-defaults/files/wifiroam/wifiroamd.uc").read_text()


def production(match):
    name = match.group(1)
    function = re.search(r"^function " + re.escape(name) + r"\(.*?^\}", SOURCE, re.M | re.S)
    if not function:
        raise AssertionError("missing production function " + name)
    return function.group(0)


for name in ("mesh-behavior", "backhaul-behavior"):
    template = (ROOT / "scripts/tests" / (name + ".uc.in")).read_text()
    code = re.sub(r"/\* PRODUCTION:([a-z_]+) \*/", production, template)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".uc") as fixture:
        fixture.write(code)
        fixture.flush()
        subprocess.run([QEMU, "-L", str(SYSROOT), str(UCODE), fixture.name], check=True)
