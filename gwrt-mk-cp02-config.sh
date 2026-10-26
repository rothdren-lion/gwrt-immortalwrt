#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cp02-config.sh — 生成 MT7621 (京东云鲁班 RE-CP-02) 最低集成配置
#
# 用法：
#   VER=261026-01 sh gwrt-mk-cp02-config.sh
#
# 目标：ramips/mt7621 DEVICE_jdcloud_re-cp-02（MT7621A + MT7915, 32G eMMC）
#
# 套装（最低 mesh 集成）：
#   gwrt-device-defaults : wifiroamd.uc 配对守护 + 自动配对 + SSID/LAN 默认值
#                          + 防火墙放行(50607/udp 50608/tcp)
#   gwrt-mesh-apmode     : 路由 ↔ 真 AP 状态机（主路由/AP 那套逻辑）
#   gwrt-agent           : APP 遥测/命令 shim（mesh.pair/role/apmode/ssid_sync）
#   ucode-mod-socket     : wifiroamd.uc 依赖（mipsel 直接编入，不走预置 apk）
#   uhttpd               : 提供 /www/mesh.html + mesh_status 网页
#
# 不含：luci / gwrt-theme / turboacc / ssr-plus 等重型组件。
#
# 注意：gwrt-agent 预编译二进制是 aarch64，MT7621(mipsel) 不安装（Makefile
#       已做架构条件），shell shim 自动退回最小遥测载荷，mesh.* 命令不受影响。
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.cp02-$VER}

cat > "$OUT" <<EOF
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_jdcloud_re-cp-02=y
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
CONFIG_PACKAGE_gwrt-agent=y
CONFIG_PACKAGE_gwrt-device-defaults=y
CONFIG_PACKAGE_gwrt-mesh-apmode=y
CONFIG_PACKAGE_ucode-mod-socket=y
CONFIG_PACKAGE_uhttpd=y
EOF

echo "==> 输出: $OUT"
echo "==> 构建树使用: cp $OUT <build-tree>/.config && make defconfig"
