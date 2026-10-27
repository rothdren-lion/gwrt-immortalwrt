#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-sync-qualcommbe.sh — 源码树 → qualcommbe 编译树 全量同步
#
# 用法:
#   sh scripts/gwrt-sync-qualcommbe.sh [目标树]
#
# 默认目标树: /home/godsun/build/immortalwrt-qualcommbe
# 首次建树与以后核心树更新（target/package 补丁同步）都用它，一条命令。
# 日常插件（gwrt-* 包）更新请用 scripts/gwrt-sync-mesh.sh，不需要全量。
#
# 说明:
#   - dl/ 不复制，软链回源码树共享下载缓存
#   - feeds/ 随树同步（排除 .git），编译树不自行 feeds update
#   - .config / config.* 不在排除列表：gwrt-mk-cs06-config.sh 需要
#     config.cs02-gwrt2-261021-04 作为派生基准
# ---------------------------------------------------------------------------
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
DST=${1:-/home/godsun/build/immortalwrt-qualcommbe}

[ -d "$SRC/target/linux/qualcommbe" ] || { echo "错误: $SRC 缺少 qualcommbe 目标" >&2; exit 1; }
mkdir -p "$DST"

rsync -a --delete \
	--exclude=.git \
	--exclude=/build_dir --exclude=/staging_dir --exclude=/tmp \
	--exclude=/dl --exclude=/bin --exclude=/bin-* \
	--exclude=/logs --exclude=/.gwrt-logs --exclude='*.log' \
	--exclude=/.config --exclude=/ipk --exclude=/backup-* \
	--exclude='feeds/*/.git' --exclude='feeds/*.tmp' \
	--exclude='feeds/*.index' --exclude='feeds/*.targetindex' \
	"$SRC/" "$DST/"

[ -e "$DST/dl" ] || ln -s "$SRC/dl" "$DST/dl"

echo "==> synced: $SRC -> $DST"
echo "==> dl:     $(readlink "$DST/dl")"
