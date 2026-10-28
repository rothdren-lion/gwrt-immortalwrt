#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-nezha-config.sh — 生成 IPQ5018 (京东云 AX3000 / 羿哪吒 RE-CS-03) 配置
#
# 用法：
#   VER=261028-01 sh gwrt-mk-nezha-config.sh
#
# 硬件：IPQ5018 (2x Cortex-A53 aarch64) + QCN6122 5G，
#       eMMC GPT：0:HLOS 6M（内核 FIT 上限）+ rootfs 256M + rootfs_data 960M，
#       ESS + 外置 QCA8337（LAN1-4），WAN 走内部 GE PHY（gmac0 直连），
#       按键 reset gpio25 / wps gpio38，LED 蓝31/绿32/红33。
#       树内无此机型，本配置配套移植：dts ipq5018-jdcloud-ax3000 +
#       image/ipq50xx.mk Device/jdcloud_ax3000 + wifi-board 包 + caldata。
#       硬件信息来源：Nwrt factory.bin（FIT 内 DTB 反编译 + rootfs 内 BDF）。
#
# 定位：GWRT mesh 子 AP。rootfs 分区 256M，空间管够，全套进镜像：
#   mesh 最低集 + LuCI中文 + SSR 全套（含 xray-core+geo）+ HomeProxy 全套
#   （含 sing-box）+ IPTV + UPnP + 常用工具 + easytier 界面（核心自理）。
#
# 刷机：Nwrt 同为 OpenWrt 分区名（0:HLOS + rootfs），可 sysupgrade；
#   首刷建议先跑 initramfs.itb 验证网口/WiFi/串口。
#   待实机验证：WAN(GEPHY) 通断、LAN1-4、双频 WiFi、MAC、LED 极性、内存水位。
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.nezha-$VER}

cat > "$OUT" <<EOF
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_jdcloud_ax3000=y
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
# --- WiFi 固件（上游无 board 文件，用原厂 BDF 包）---
CONFIG_PACKAGE_ath11k-firmware-ipq5018-qcn6122=y
CONFIG_PACKAGE_jdcloud-ax3000-wifi-board=y
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
CONFIG_PACKAGE_kmod-inet-diag=y
# --- SSR 全套 ---
CONFIG_PACKAGE_gwrt-ssr-plus-luci=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_dns2tcp=y
CONFIG_PACKAGE_ipt2socks=y
CONFIG_PACKAGE_microsocks=y
# --- HomeProxy 全套 ---
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y
CONFIG_PACKAGE_sing-box=y
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
