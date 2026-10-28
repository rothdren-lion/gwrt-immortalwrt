#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cp02-config.sh — 生成 MT7621 (京东云鲁班 RE-CP-02) 配置
#
# 用法：
#   VER=261028-01 sh gwrt-mk-cp02-config.sh
#
# 目标：ramips/mt7621 DEVICE_jdcloud_re-cp-02（MT7621A + MT7915, 16M SPI NOR
#       装系统 + 32G eMMC 做数据盘，IMAGE_SIZE=16000k，经 check-size 硬限制）
#
# 定位：GWRT mesh 子 AP。16M  flash 按“塞满但不超过线”原则分配：
#   进镜像(=y)：mesh 最低集 + LuCI中文 + SSR/Proxy 前端 + IPTV + UPnP + 常用工具
#   编apk手动装(=m)：xray-core / sing-box / geoip+geosite / chinadns-ng / fdisk
#              （CI artifact 收集，刷机后装到 eMMC/overlay；apks 不占 flash）
#   瘦身换件：wpad-openssl→wpad-mesh-wolfssl（省~0.3M，保留 11r 漫游），
#            dnsmasq-full→dnsmasq（odhcpd 管 DHCPv6，不影响），去 ppp 全套
#            （子AP 用不上拨号；pppoe 用户请用路由模式固件或手动装包）
#   easytier：只留 LuCI 界面（70K），核心用户自理（暂不编入）
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
# --- mesh 最低集 ---
CONFIG_PACKAGE_gwrt-agent=y
CONFIG_PACKAGE_gwrt-device-defaults=y
CONFIG_PACKAGE_gwrt-mesh-apmode=y
CONFIG_PACKAGE_ucode-mod-socket=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_kmod-tun=y
# --- SSR（前端进镜像，核心编 apk 装 eMMC）---
CONFIG_PACKAGE_gwrt-ssr-plus-luci=y
CONFIG_PACKAGE_xray-core=m
CONFIG_PACKAGE_v2ray-geoip=m
CONFIG_PACKAGE_v2ray-geosite=m
CONFIG_PACKAGE_chinadns-ng=m
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_dns2tcp=y
CONFIG_PACKAGE_ipt2socks=y
CONFIG_PACKAGE_microsocks=y
# --- HomeProxy（UI+核心都太大，16M 放不下，双双编 apk 装 eMMC）---
# 注意：luci-app-homeproxy 硬依赖 +sing-box（Makefile 写死），=y 会把 19M 核心拽进镜像
CONFIG_PACKAGE_luci-app-homeproxy=m
CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=m
CONFIG_PACKAGE_sing-box=m
CONFIG_PACKAGE_kmod-inet-diag=m
# --- IPTV ---
CONFIG_PACKAGE_igmpproxy=y
CONFIG_PACKAGE_udpxy=y
# --- UPnP ---
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
# CONFIG_PACKAGE_miniupnpd-iptables is not set
CONFIG_PACKAGE_miniupnpd-nftables=y
# --- 常用工具 ---
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_fdisk=m
# --- easytier：只留界面，核心自理 ---
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-i18n-easytier-zh-cn=y
# --- 16M 瘦身换件 ---
# CONFIG_PACKAGE_wpad-openssl is not set
CONFIG_PACKAGE_wpad-mesh-wolfssl=y
# CONFIG_PACKAGE_dnsmasq-full is not set
CONFIG_PACKAGE_dnsmasq=y
# CONFIG_PACKAGE_ppp is not set
# CONFIG_PACKAGE_ppp-mod-pppoe is not set
# CONFIG_PACKAGE_luci-proto-ppp is not set
EOF

echo "==> 输出: $OUT"
echo "==> 构建树使用: cp $OUT <build-tree>/.config && make defconfig"
