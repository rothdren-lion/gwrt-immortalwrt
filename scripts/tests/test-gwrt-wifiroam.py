#!/usr/bin/env python3
"""Run production roam/backhaul functions with real, isolated target ucode/UCI."""
import os
import json
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
SHARED = ROOT / "package/gwrt-device-defaults/files/wifiroam"
SOURCES = (
    SHARED / "wifiroamd.uc",
    ROOT / "package/gwrt-wifiroam-v5/files/usr/share/gwrt/wifiroam-v5/wifiroamd.uc",
)


def production(source, match):
    name = match.group(1)
    ident = re.escape(name)
    function = re.search(r"^(?:function " + ident + r"|" + ident + r" = function)\(.*?^\};?",
                         source, re.M | re.S)
    if not function:
        raise AssertionError("missing production function " + name)
    return function.group(0)


for variant, sourcefile in enumerate(SOURCES):
    source = sourcefile.read_text()
    for name in ("mesh-behavior", "backhaul-behavior"):
        if variant and name == "mesh-behavior":
            continue  # The legacy daemon has its own steering/lease behavior.
        template = (ROOT / "scripts/tests" / (name + ".uc.in")).read_text()
        with tempfile.TemporaryDirectory(prefix="gwrt-wifiroam-") as tmp:
            directory = Path(tmp)
            for module in SHARED.glob("mesh-*.uc"):
                code = module.read_text().replace("uci.cursor()",
                    f"uci.cursor({json.dumps(tmp)}, {json.dumps(tmp + '/state')})")
                code = code.replace('"/var/run/gwrt-mesh-apmode/"', json.dumps(tmp + "/run/"))
                code = code.replace('"/usr/libexec/gwrt-mesh-apmode"', json.dumps(tmp + "/controller"))
                (directory / module.name).write_text(code)
            code = re.sub(r"/\* PRODUCTION:([a-z_]+) \*/", lambda m: production(source, m), template)
            (directory / "fixture.uc").write_text(code.replace('"@FIXTURE@"', json.dumps(tmp)))
            command = [QEMU, "-L", str(SYSROOT), str(UCODE), "-L", str(SYSROOT / "usr/lib/ucode")]
            subprocess.run(command + [str(directory / "fixture.uc")], check=True)
            daemon = directory / "wifiroamd.uc"
            daemon.write_text(source.replace('"/usr/share/gwrt/wifiroam/', '"./'))
            subprocess.run(command + ["-c", "-o", str(directory / "daemon.bc"), str(daemon)], check=True)
