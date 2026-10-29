#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-wr632ax-config.sh — 生成 MT7981 (COMFAST CF-WR632AX / XINGLOO 星鹿盒子) 配置
#
# 用法：
#   sh gwrt-mk-wr632ax-config.sh
#   VER=261025-02 sh gwrt-mk-wr632ax-config.sh
#
# 硬件（串口 115200n8 + MAC OUI 40:A5:EF 已确认）：
#   SoC   : MediaTek MT7981B (2x Cortex-A53 1.3GHz)
#   RAM   : DDR3 512MiB
#   Flash : SPI-NAND 128MiB (Winbond)
#   WLAN  : MT7976CN (2.4G + 5G WiFi6)
#   网口  : WAN 2.5G (MaxLinear GPY211C) + LAN 1G
#   USB   : 1x USB3.0   风扇: 4-wire PWM
#   串口  : 115200n8，U-Boot 恢复页 http://192.168.1.1
#
# 插件集：沿用 AN7581 (config.an7581-261022-01) 的通用部分，去掉 PON 全家桶
#         （airoha-ponctl / airoha-pond / luci-app-pon / luci-app-iptv /
#           luci-app-pon-wan / airoha xpon 驱动）和 airoha-npu 面板。
#
# 三个 profile 一起出：
#   comfast_cf-wr632ax           原厂 MTD 布局（第一次刷机用，sysupgrade.bin）
#   comfast_cf-wr632ax-ubootmod  OpenWrt U-Boot 布局（sysupgrade.itb + preloader/fip）
#   comfast_cf-wr632ax-ubi       all-in-UBI 安装器布局（sysupgrade.itb）
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/configs/config.mt7981-wr632ax-$VER}
BAK="$TOP/.config.bak-$(date +%Y%m%d-%H%M%S)"

echo "==> 输出: $OUT"

if [ -f "$TOP/.config" ]; then
	cp "$TOP/.config" "$BAK"
	echo "==> 已备份现有 .config -> $BAK"
fi

# --- 1. 最小 seed config ----------------------------------------------------
cat >"$OUT" <<EOF
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_HOST_OS_LINUX=y
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr632ax=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr632ax-ubootmod=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr632ax-ubi=y
CONFIG_TARGET_ROOTFS_PARTSIZE=48
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE=y
CONFIG_LINUX_6_18=y
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="GWRT"
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_FILENAMES=y
EOF

cp "$OUT" "$TOP/.config"

# --- 2. defconfig 展开 ------------------------------------------------------
make defconfig >/dev/null

add_pkg() {
	sym=$1
	grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config" && return 0
	if grep -q "^# CONFIG_PACKAGE_${sym} is not set$" "$TOP/.config"; then
		sed -i "s|^# CONFIG_PACKAGE_${sym} is not set$|CONFIG_PACKAGE_${sym}=y|" "$TOP/.config"
	else
		echo "CONFIG_PACKAGE_${sym}=y" >>"$TOP/.config"
	fi
	echo "  + $sym"
}

unset_pkg() {
	sym=$1
	if grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config"; then
		sed -i "s|^CONFIG_PACKAGE_${sym}=y$|# CONFIG_PACKAGE_${sym} is not set|" "$TOP/.config"
		echo "  - $sym"
	fi
}

echo "[wr632ax] LuCI / 中文:"
for p in \
	luci-compat \
	luci-i18n-base-zh-cn \
	luci-i18n-firewall-zh-cn \
	luci-i18n-package-manager-zh-cn \
	luci-i18n-attendedsysupgrade-zh-cn \
	luci-proto-ipv6 \
	luci-proto-ppp \
	luci-app-firewall \
	luci-app-package-manager \
	luci-app-attendedsysupgrade ; do
	add_pkg "$p"
done

echo "[wr632ax] 插件面板（对齐 an7581，去掉 PON / airoha-npu）:"
for p in \
	luci-app-route-tool \
	luci-app-easytier \
	luci-i18n-easytier-zh-cn ; do
	add_pkg "$p"
done

echo "[wr632ax] zram / NAND 工具链:"
for p in \
	kmod-zram \
	zram-swap \
	nand-utils \
	ubi-utils \
	mtd \
	fitblk \
	uboot-envtools ; do
	add_pkg "$p"
done

echo "[wr632ax] 网络与基础:"
for p in \
	dnsmasq-full \
	ppp-mod-pppoe \
	ip-full \
	usbutils \
	blockd \
	block-mount \
	ethtool \
	tcpdump ; do
	add_pkg "$p"
done

echo "[wr632ax] 主题:"
add_pkg luci-theme-gwrt

echo "[wr632ax] 清除（PON 及后期自装重包）:"
for p in \
	airoha-ponctl \
	airoha-pond \
	airoha-pon-debug \
	luci-app-pon \
	luci-i18n-pon-zh-cn \
	luci-app-iptv \
	luci-i18n-iptv-zh-cn \
	luci-app-pon-wan \
	luci-app-airoha-npu \
	kmod-airoha-xpon \
	kmod-airoha-pon-frontend \
	kmod-airoha-en7572 \
	kmod-airoha-paged-bosa \
	openclash \
	luci-app-openclash \
	easytier \
	easytier-noweb \
	gecoosac \
	luci-app-gecoosac \
	docker \
	dockerd \
	docker-compose \
	podman \
	kmod-wireguard \
	kmod-tun \
	kmod-nft-tproxy \
	kmod-inet-diag \
	luci-app-bandix-plus \
	bandix-plus \
	coremark \
	luci-app-ttyd \
	ttyd \
	appfilter \
	kmod-oaf \
	luci-app-oaf ; do
	unset_pkg "$p"
done

# --- 3. 复检 ----------------------------------------------------------------
make defconfig >/dev/null

echo "[wr632ax] defconfig 后复检（主题 fragment 带入的重包）:"
for p in \
	openclash \
	luci-app-openclash \
	luci-app-bandix-plus \
	bandix-plus \
	coremark \
	luci-app-ttyd \
	ttyd \
	appfilter \
	kmod-oaf \
	luci-app-oaf \
	gecoosac \
	luci-app-gecoosac ; do
	unset_pkg "$p"
done

cp "$TOP/.config" "$OUT"

echo
echo "==> 完成: $OUT"
echo "==> 目标设备:"
grep -E '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr632ax' "$OUT" || true
echo "==> 体积/布局:"
grep -E '^CONFIG_TARGET_(ROOTFS_PARTSIZE|MULTI_PROFILE|PER_DEVICE_ROOTFS|ROOTFS_INITRAMFS)=' "$OUT" || true
