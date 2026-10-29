#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-pzl8-config.sh — 生成 IPQ5018 (CMCC PZ-L8 / 移动PL08 AX3000) 配置
#
# 用法：
#   VER=261029-01 sh gwrt-mk-pzl8-config.sh
#
# 硬件：IPQ5018 (2x Cortex-A53 aarch64) + QCN6122 5G，128M NAND，**DRAM 仅 256M**
#       （内核起来后可用约 184M，两路 ath11k 还要吃掉大块 reserved）
#       树内已有 cmcc_pz-l8 定义；WiFi 靠 pz-l8-wifi-board（原厂 BDF）+ DTS 使能
#
# 定位：GWRT mesh 子 AP（纯 AP 用途）。**内存是硬约束**：
#   2026-10-29 实测 261027-02（含 xray+geo+easytier 核心）启动即 OOM →
#   watchdog 重启循环 → WiFi 起不来。故本配置只留 mesh + 小工具，
#   并加 zram-swap 兜底。代理/easytier 核心一律不进镜像（需要就 sideload，
#   且装完须评估内存）。
#
# 进镜像(=y)：mesh 三件套（含 wifiroam 预置包）+ LuCI中文 + 精简主题 +
#            wol / upnp / IPTV / 常用工具 + zram
# 不进：xray/sing-box/geo/chinadns/ssr-UI/homeproxy（内存炸弹）、
#      easytier 核心（仅留界面，用户自理）、ppp 全套
#   瘦身换件：wpad-openssl→wpad-mesh-wolfssl（保留 11r），dnsmasq-full→dnsmasq
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.pzl8-$VER}

cat > "$OUT" <<EOF
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_cmcc_pz-l8=y
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
# --- WiFi 固件（设备定义未自带，必须显式选）---
CONFIG_PACKAGE_ath11k-firmware-ipq5018-qcn6122=y
CONFIG_PACKAGE_pz-l8-wifi-board=y
# --- 内存兜底 ---
CONFIG_PACKAGE_kmod-zram=y
CONFIG_PACKAGE_zram-swap=y
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
# --- 常用工具 ---
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_fdisk=y
# --- easytier：只留界面（核心不入镜像，内存所限）---
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-i18n-easytier-zh-cn=y
# --- 瘦身换件 ---
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
