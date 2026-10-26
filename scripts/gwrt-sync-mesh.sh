#!/bin/sh
# gwrt-sync-mesh.sh — 把 GWRT mesh 相关包同步到任意 OpenWrt/ImmortalWrt 源码树
#
# 用法:
#   sh scripts/gwrt-sync-mesh.sh /path/to/openwrt
#
# 会复制:
#   package/gwrt-mesh-led        mesh 状态灯 + 一键配对
#   package/gwrt-mesh-apmode     路由 <-> 真 AP 状态机
#   package/gwrt-device-defaults 首启默认值 / SSID / wifiroam 补丁 / 防火墙
#   package/gwrt-agent           APP 控制（mesh.* 命令）
#   package/gwrt-theme           主题（SSID 命名保护）
#   docs/GWRT-MESH.md            设计文档
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
DST=${1:-}

if [ -z "$DST" ]; then
	echo "用法: $0 <目标 OpenWrt 源码树>" >&2
	exit 1
fi
if [ ! -d "$DST/package" ] || [ ! -f "$DST/rules.mk" ]; then
	echo "错误: $DST 不是 OpenWrt/ImmortalWrt 源码树" >&2
	exit 1
fi

for p in gwrt-mesh-led gwrt-mesh-apmode gwrt-device-defaults gwrt-agent; do
	if [ -d "$SRC/package/$p" ]; then
		rsync -a --delete "$SRC/package/$p/" "$DST/package/$p/"
		echo "  synced package/$p"
	fi
done

# 主题是嵌套结构（package/gwrt-theme/luci-theme-gwrt/...）
if [ -d "$SRC/package/gwrt-theme" ]; then
	rsync -a --delete "$SRC/package/gwrt-theme/" "$DST/package/gwrt-theme/"
	echo "  synced package/gwrt-theme"
fi

mkdir -p "$DST/docs"
cp -f "$SRC/docs/GWRT-MESH.md" "$DST/docs/GWRT-MESH.md"
echo "  synced docs/GWRT-MESH.md"

cat <<'EOF'

完成。在目标树的配置里加上：

  CONFIG_PACKAGE_gwrt-device-defaults=y
  CONFIG_PACKAGE_gwrt-mesh-led=y
  CONFIG_PACKAGE_gwrt-mesh-apmode=y
  CONFIG_PACKAGE_gwrt-agent=y
  CONFIG_PACKAGE_luci-theme-gwrt=y
  CONFIG_PACKAGE_libuci-lua=y          # OAF rule_manager 需要
  CONFIG_PACKAGE_kmod-tun=y            # easytier 需要

并把 gwrt-device-defaults 加进对应设备的 DEVICE_PACKAGES。
EOF
