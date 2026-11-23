#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/gwrt-select-models.py"
cases = (
    (
        "multi-profile",
        "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1=y\n"
        "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_qihoo_360t7-ubi=y\n",
        "cudy_tr3000-256mb-v1",
    ),
    (
        "single-profile",
        "CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y\n",
        "jdcloud_re-cs-06",
    ),
)

for label, source, selected in cases:
    with TemporaryDirectory(prefix="gwrt-model-select-") as directory:
        config = Path(directory) / ".config"
        config.write_text(source)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(config), selected],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if result.returncode:
            raise SystemExit(f"{label} selection failed: {result.stderr}{result.stdout}")
        resolved = config.read_text()
        if f"DEVICE_{selected}=y" not in resolved:
            raise SystemExit(f"{label} did not retain {selected}")
        if "qihoo_360t7-ubi=y" in resolved:
            raise SystemExit("360T7 UBI profile was not removed")

print("PASS: multi-profile and single-profile model selection")
