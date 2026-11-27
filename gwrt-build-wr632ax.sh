#!/bin/sh
# gwrt-build-wr632ax.sh — 编译 MT7981 (COMFAST CF-WR632AX / XINGLOO) 固件
# 用法: sh gwrt-build-wr632ax.sh [jobs]
set -e
# dash 不支持 pipefail；bash 下启用，避免 tee 吞掉 make 的失败
if (set -o pipefail) 2>/dev/null; then
	set -o pipefail
fi
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"
JOBS=${1:-6}
REV=${REVISION:-$(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo 8dff4aa)}
LOG="$TOP/.gwrt-logs/build-wr632ax-$(date +%y%m%d-%H%M).log"
mkdir -p "$TOP/.gwrt-logs"
echo "==> log: $LOG"
nice -n 15 make -j"$JOBS" \
	REVISION="$REV" \
	CONFIG_VERSION_DIST=GWRT \
	CONFIG_VERSION_NUMBER=261025-01 \
	2>&1 | tee "$LOG"
echo "==> done, 产物:"
ls -lh bin/targets/mediatek/filogic/*wr632ax* 2>/dev/null || true
