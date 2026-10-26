#!/bin/sh
# gwrt-build-wr630ax.sh — 编译 MT7981 (XINGLOO AX3000 / COMFAST CF-WR630AX) 固件
# 用法: sh gwrt-build-wr630ax.sh [jobs] [version]
#
# 注意：本地树如果没有 .git，OpenWrt 的 REVISION 会取成 "unknown"，
#       而 apk 打包时 "版本~unknown" 会被判为非法版本（package/base-files 首先报错）。
#       所以这里显式传 REVISION。
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"
JOBS=${1:-6}
VER=${2:-261025-01}
REV=${REVISION:-$(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo cb793d3)}
LOG="$TOP/.gwrt-logs/build-wr630ax-$(date +%y%m%d-%H%M).log"
mkdir -p "$TOP/.gwrt-logs"
echo "==> log: $LOG"
echo "==> REVISION=$REV"
nice -n 15 make -j"$JOBS" \
	REVISION="$REV" \
	CONFIG_VERSION_DIST=GWRT \
	CONFIG_VERSION_NUMBER="$VER" \
	2>&1 | tee "$LOG"
echo "==> done, 产物:"
ls -lh bin/targets/mediatek/filogic/*ax3000* bin/targets/mediatek/filogic/*wr630ax* 2>/dev/null || true
