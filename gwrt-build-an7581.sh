#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-build-an7581.sh — 编译 Airoha AN7581 光猫固件
#
# 用法：
#   sh gwrt-build-an7581.sh              # 用当前 .config 编译
#   JOBS=8 sh gwrt-build-an7581.sh       # 指定并行度（默认 6，nice 15，避免抢隔壁编译）
#
# 说明：
#   - 主题包已由 gwrt-theme-V3/scripts/integrate.sh 同步到 package/gwrt-theme/，
#     本脚本不再并入 manifest/config.fragment（那份带 openclash/bandix/coremark，
#     会顶破 50MB 体积预算）。
#   - 产物在 bin/targets/airoha/an7581/。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

JOBS=${JOBS:-6}
PROFILE=$(grep -E "^CONFIG_TARGET_PROFILE=" .config 2>/dev/null | cut -d'"' -f2)

echo "==> 目标机型: ${PROFILE:-未知}"
echo "==> 并行度: $JOBS (nice 15)"

nice -n 15 make -j"$JOBS"

echo
echo "==> 产物:"
ls -lh bin/targets/airoha/an7581/ 2>/dev/null || true
