#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TREE="$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)"

if [ "${1:-}" = "--tree" ]; then
	[ "$#" -ge 2 ] || { echo "--tree requires a directory" >&2; exit 2; }
	TREE="$2"
	shift 2
fi

# 每次整机编译自动生成 GWRT YYMMDD-NN 版本号（日期 + 当天编译次数）。
# 版本号写进 .config 的 CONFIG_VERSION_NUMBER 和主题的 firmware-version，
# 因此 /etc/openwrt_release、SSH banner、仪表盘和镜像文件名保持一致。
if [ "${GWRT_NO_VERSION_BUMP:-0}" != "1" ]; then
	ver_script="$TREE/scripts/gwrt-next-firmware-version.sh"
	[ -x "$ver_script" ] || ver_script="$PROJECT_DIR/../scripts/gwrt-next-firmware-version.sh"
	[ -x "$ver_script" ] && "$ver_script" --tree "$TREE"
fi

"$SCRIPT_DIR/integrate.sh" --tree "$TREE"
exec make -C "$TREE" "$@"
