#!/usr/bin/env python3
"""Run the private-runtime helper with only the minimal OpenWrt applets."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-runtime-dir"


class RuntimeDirTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.runtime = self.base / "runtime"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        # No stat applet: this matches the failing SS-01 image. Use the real
        # numeric ls output, remapping only the expected root UID for CI.
        for applet in ("mkdir", "ls", "awk", "chmod"):
            (self.bin / applet).symlink_to(shutil.which("busybox") or shutil.which(applet))

    def run_helper(self, expected_uid=None):
        source = HELPER.read_text().replace("runtime_dir=/tmp/gwrt-theme", f"runtime_dir={self.runtime}")
        source = source.replace("PATH=/usr/sbin:/usr/bin:/sbin:/bin", f"PATH={self.bin}")
        if expected_uid is None:
            expected_uid = os.geteuid()
        source = source.replace('[ "$owner" = 0 ]', f'[ "$owner" = {expected_uid} ]')
        script = self.base / "helper.sh"
        script.write_text(source)
        return subprocess.run(["/bin/sh", str(script)], capture_output=True, text=True)

    def test_creates_and_reuses_private_directory_without_stat(self):
        for _ in range(2):
            result = self.run_helper()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(self.runtime))
            self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o700)

    def test_tightens_existing_directory_permissions(self):
        self.runtime.mkdir(mode=0o755)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o700)

    def test_rejects_other_owner_before_chmod(self):
        self.runtime.mkdir(mode=0o755)
        self.assertNotEqual(self.run_helper(os.geteuid() + 1).returncode, 0)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o755)

    def test_rejects_symlink_and_preserves_target(self):
        target = self.base / "target"
        target.mkdir(mode=0o755)
        self.runtime.symlink_to(target)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_rejects_file_and_dangling_symlink(self):
        self.runtime.write_text("keep")
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.runtime.read_text(), "keep")
        self.runtime.unlink()
        self.runtime.symlink_to(self.base / "absent")
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_failed_owner_lookup_does_not_grant_access(self):
        (self.bin / "ls").unlink()
        self.assertNotEqual(self.run_helper().returncode, 0)


if __name__ == "__main__":
    unittest.main()
