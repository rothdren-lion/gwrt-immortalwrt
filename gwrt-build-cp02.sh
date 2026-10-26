#!/bin/sh
# gwrt-build-cp02.sh — 编译 MT7621 (京东云鲁班 RE-CP-02) 固件
# 用法: sh gwrt-build-cp02.sh [jobs] [version]
#
# 注意：本地树没有 .git 时 OpenWrt 的 REVISION 会取成 "unknown"，
#       apk 打包时 "版本~unknown" 被判非法 → 显式传 REVISION。
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"
JOBS=${1:-6}
VER=${2:-$(date +%y%m%d)-01}
REV=${REVISION:-$(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo cb793d3)}
LOG="$TOP/.gwrt-logs/build-cp02-$(date +%y%m%d-%H%M).log"
mkdir -p "$TOP/.gwrt-logs"
echo "==> log: $LOG"
echo "==> REVISION=$REV"
nice -n 15 make -j"$JOBS" \
	REVISION="$REV" \
	CONFIG_VERSION_DIST=GWRT \
	CONFIG_VERSION_NUMBER="$VER" \
	2>&1 | tee "$LOG"
echo "==> done, 产物:"
ls -lh bin/targets/ramips/mt7621/*cp-02* 2>/dev/null || true
