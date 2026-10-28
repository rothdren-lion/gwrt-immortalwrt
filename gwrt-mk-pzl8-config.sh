#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-pzl8-config.sh — 生成 IPQ5018 (CMCC PZ-L8 / 移动PL08 AX3000) 配置
#
# 用法：
#   VER=261028-01 sh gwrt-mk-pzl8-config.sh
#
# 硬件：IPQ5018 (2x Cortex-A53 aarch64) + QCN6122 5G，128M NAND (59392k 预算)
#       树内已有 cmcc_pz-l8 设备定义（leds/network/platform.sh 齐全）
#
# 定位：GWRT mesh 子 AP。最优方案（58M 预算内最大化，镜像约 42M）：
#   进镜像(=y)：mesh 最低集 + LuCI中文 + SSR 全套（含 xray-core+geo）+
#              HomeProxy 前端 + IPTV + UPnP + 常用工具 + easytier 界面
#   编apk手动装(=m)：sing-box（15M，太大；overlay/ubi 剩余空间手动装）
#   WiFi：上游默认禁用（缺 board 文件），已用原厂 BDF 做
#         package/firmware/pz-l8-wifi-board 包 + DTS/hotplug 使能，刷机后验证
#   easytier：只留 LuCI 界面，核心用户自理（暂不编入）
#
# 分区说明：DTS 用 qcom,smem-part（分区表由 SBL 经 SMEM 给，DTS 改不了）。
#   UbiFit + autoresize 会自动吃掉 ubi 分区全部剩余空间做 overlay。
#   想放大 IMAGE_SIZE 或重做分区表，先上机取 `cat /proc/mtd; ubinfo -a` 再定。
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
# --- SSR 全套（58M 预算充足，xray 核心直接进镜像）---
CONFIG_PACKAGE_gwrt-ssr-plus-luci=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_dns2tcp=y
CONFIG_PACKAGE_ipt2socks=y
CONFIG_PACKAGE_microsocks=y
# --- HomeProxy（前端+核心共 16M，58M 预算放不下，双双编 apk 装 overlay）---
# 注意：luci-app-homeproxy 硬依赖 +sing-box（Makefile 写死），=y 会把 15M 核心拽进镜像
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
CONFIG_PACKAGE_fdisk=y
# --- easytier：只留界面，核心自理 ---
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-i18n-easytier-zh-cn=y
EOF

echo "==> 输出: $OUT"
echo "==> 构建树使用: cp $OUT <build-tree>/.config && make defconfig"
