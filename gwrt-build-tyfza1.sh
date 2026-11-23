#!/bin/sh
# 编译 TYFZA1（Realtek RTL9617C）固件。
# 配置由 gwrt-mk-tyfza1-config.sh 生成；内核 6.18，插件集与 an7581 序列一致。
#
# 用法（必须在无冒号的本地路径运行，SMB 挂载点含 "server=" 冒号会被 make 误判）：
#   sh gwrt-build-tyfza1.sh 6 261118-01
#
# 注意：本仓库所在的 gvfs 路径形如
#   /run/user/1000/gvfs/smb-share:server=192.168.9.242,share=...
# 路径里的冒号会让 include/toplevel.mk 的规则被解析成静态模式规则并报
#   "*** 目标模式不含有“%”"
# 因此编译必须在本地副本（无冒号路径）进行，源码改动仍以 SMB 工作副本为准。
set -e

JOBS=${1:-6}
VER=${2:-$(date +%y%m%d)-01}
REV=${REV:-$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo 0000000)}

case "$(pwd)" in
*:*) echo "错误：当前路径含冒号，OpenWrt 无法在此编译（$(pwd)）" >&2; exit 1 ;;
esac

echo "==> 生成配置 $VER"
VER="$VER" sh gwrt-mk-tyfza1-config.sh

echo "==> 编译（-j$JOBS, REVISION=$REV）"
make -j"$JOBS" V=s REVISION="$REV" \
	CONFIG_TARGET_rtl9617c=y \
	CONFIG_TARGET_rtl9617c_generic=y \
	CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_tianyi_tyfza1=y

echo "==> 产物："
ls -1 bin/targets/rtl9617c/generic/*sysupgrade* bin/targets/rtl9617c/generic/*.itb 2>/dev/null || true
