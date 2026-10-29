#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cp02-config.sh — 生成 MT7621 (京东云鲁班 RE-CP-02) 配置
#
# 用法：
#   VER=261028-03 sh gwrt-mk-cp02-config.sh
#
# 目标：ramips/mt7621 DEVICE_jdcloud_re-cp-02（MT7621A + MT7915, 16M SPI NOR
#       装系统 + 32G eMMC 做数据盘，真上限是 mtd3 firmware 分区 16187392 字节）
#
# 定位：GWRT mesh 子 AP（核心需求），小插件顺带。
#   进镜像(=y)：mesh 全套（含 wifiroam 预置包，开箱即有漫游）+ LuCI中文 +
#              GWRT 精简主题 + UPnP + IPTV + 常用工具 + easytier 界面
#   编apk手动装(=m)：fdisk（eMMC 分区用，overlay 空间装）
#   不编：代理全套（xray/sing-box/geo/chinadns/ssr-UI/homeproxy，16M 放不下
#         且无核心报错，不如不装）、easytier 核心（用户自理）、ppp 全套
#   瘦身换件：wpad-openssl→wpad-mesh-wolfssl（保留 11r），
#            dnsmasq-full→dnsmasq（DHCPv6 由 odhcpd 接）
#   主机名默认 gwrt（97 脚本，出厂默认时改一次）
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
# --- mesh 全套（漫游守护+LuCI 预置包，开箱即用）---
CONFIG_PACKAGE_gwrt-agent=y
CONFIG_PACKAGE_gwrt-device-defaults=y
CONFIG_PACKAGE_gwrt-mesh-apmode=y
CONFIG_PACKAGE_ucode-mod-socket=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-theme-gwrt-lite=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_kmod-tun=y
# --- UPnP ---
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
# CONFIG_PACKAGE_miniupnpd-iptables is not set
CONFIG_PACKAGE_miniupnpd-nftables=y
# --- IPTV ---
CONFIG_PACKAGE_igmpproxy=y
CONFIG_PACKAGE_udpxy=y
# --- 网络唤醒 ---
CONFIG_PACKAGE_luci-app-wol=y
CONFIG_PACKAGE_luci-i18n-wol-zh-cn=y
# --- EQoS（自家 gwrt-eqos + tc-full；feeds 的 luci-app-eqos 要 tc，两者互斥不共存）---
CONFIG_PACKAGE_gwrt-eqos=y
# --- Windows/Office 激活（KMS）---
CONFIG_PACKAGE_vlmcsd=y
CONFIG_PACKAGE_luci-app-vlmcsd=y
CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn=y
# --- 常用工具 ---
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_fdisk=y
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
