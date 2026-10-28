#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-build-cs08.sh — 编译 JDCloud RE-CS-08 太乙2plus (IPQ5322 eMMC, no WiFi + SFP 10G) 固件
#
# 用法:
#   sh gwrt-build-cs08.sh [jobs] [version]
#
# 注意: 编译树（rsync 同步，无 .git）必须显式传 REVISION，
#       否则 apk 会因 "版本~unknown" 报非法版本（package/base-files 先炸）。
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
JOBS=${1:-6}
VER=${2:-261026-01}
REV=${REVISION:-$(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo 8dff4aa)}
LOG="$TOP/.gwrt-logs/build-cs08-$(date +%y%m%d-%H%M).log"
mkdir -p "$TOP/.gwrt-logs"

echo "==> log: $LOG"
echo "==> REVISION=$REV"

nice -n 15 make -j"$JOBS" \
	REVISION="$REV" \
	CONFIG_VERSION_DIST=GWRT \
	CONFIG_VERSION_NUMBER="$VER" \
	2>&1 | tee "$LOG"

echo "==> done, 产物:"
ls -lh bin/targets/qualcommbe/ipq53xx/*cs-06* 2>/dev/null || true
