#!/bin/sh
# gwrt-sync-mesh.sh — 把 GWRT 全部自定义包 / mesh / 文档同步到任意 OpenWrt 源码树
#
# 用法:
#   sh scripts/gwrt-sync-mesh.sh /path/to/openwrt [--with-theme]
#
# airoha(AN7581) 目标树会自动跳过 package/gwrt-theme（该树主题独立维护）。
#
# 同步内容:
#   package/gwrt-*       全部 GWRT 自定义包（mesh、device-defaults、theme、agent、
#                        eqos、bandix、oaf、ssr-plus、pon-wan、athena-led）
#   AGENTS.md            项目说明（给 agent 看）
#   docs/GWRT-MESH.md    mesh 设计文档
#   docs/WORKLOG-*.md    操作日志
#   BUILD-NOTES-*.md     构建/调试记录
#   gwrt-mk-*.sh         配置生成器
#   gwrt-build-*.sh      编译脚本
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

# 全部 GWRT 自定义包
FORCE_THEME=0
for a in "$@"; do
	[ "$a" = "--with-theme" ] && FORCE_THEME=1
done
SKIP_THEME=0
if [ "$FORCE_THEME" = "0" ] && grep -q '^CONFIG_TARGET_BOARD="airoha"' "$DST/.config" 2>/dev/null; then
	SKIP_THEME=1
	echo "检测到 airoha(AN7581) 目标树：跳过 package/gwrt-theme"
	echo "  该树的主题是独立线（PPE/PON/动态 WAN/固件版本），用 --with-theme 可强制覆盖"
fi
for d in "$SRC"/package/gwrt-*; do
	[ -d "$d" ] || continue
	p=$(basename "$d")
	if [ "$p" = "gwrt-theme" ] && [ "$SKIP_THEME" = "1" ]; then
		echo "  skip package/$p"
		continue
	fi
	rsync -a --delete "$d/" "$DST/package/$p/"
	echo "  synced package/$p"
done

# 文档
mkdir -p "$DST/docs"
[ -f "$SRC/AGENTS.md" ] && cp -f "$SRC/AGENTS.md" "$DST/AGENTS.md" && echo "  synced AGENTS.md"
for f in "$SRC"/docs/GWRT-MESH.md "$SRC"/docs/WORKLOG-*.md; do
	[ -f "$f" ] || continue
	cp -f "$f" "$DST/docs/"
	echo "  synced docs/$(basename "$f")"
done
for f in "$SRC"/BUILD-NOTES-*.md; do
	[ -f "$f" ] || continue
	cp -f "$f" "$DST/"
	echo "  synced $(basename "$f")"
done

# 生成器 / 编译脚本
for f in "$SRC"/gwrt-mk-*.sh "$SRC"/gwrt-build-*.sh; do
	[ -f "$f" ] || continue
	cp -f "$f" "$DST/"
	chmod +x "$DST/$(basename "$f")"
	echo "  synced $(basename "$f")"
done

cat <<'EOF'

完成。在目标树的配置里确保包含：

  CONFIG_PACKAGE_gwrt-device-defaults=y
  CONFIG_PACKAGE_gwrt-mesh-led=y
  CONFIG_PACKAGE_gwrt-mesh-apmode=y
  CONFIG_PACKAGE_gwrt-agent=y
  CONFIG_PACKAGE_luci-theme-gwrt=y
  CONFIG_PACKAGE_gwrt-eqos=y
  CONFIG_PACKAGE_libuci-lua=y          # OAF rule_manager 需要
  CONFIG_PACKAGE_kmod-tun=y            # easytier 需要

并把 gwrt-device-defaults 加进对应设备的 DEVICE_PACKAGES。
EOF
