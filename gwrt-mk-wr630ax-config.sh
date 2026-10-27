#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-wr630ax-config.sh — 生成 MT7981 (COMFAST CF-WR630AX / XINGLOO 星鹿) 配置
#
# 用法：
#   sh gwrt-mk-wr630ax-config.sh
#   VER=261025-02 sh gwrt-mk-wr630ax-config.sh
#
# 硬件（串口 115200n8 实机确认 + 原厂 DTB 反编译确认）：
#   SoC   : MediaTek MT7981B (2x Cortex-A53)
#   RAM   : DDR3 256 MiB
#   Flash : SPI-NAND 128 MiB (Winbond), NMBM
#           0x000000 BL2 1M / 0x100000 u-boot-env 512K / 0x180000 Factory 2M
#           0x380000 FIP 2M / 0x580000 ubi 64M
#   交换  : MT7531AE (MDIO 0x1f) -> lan1..lan4 (port 0..3), CPU port 6 @2.5G
#   网口  : eth1 = WAN，MT7981 内置 GbE PHY (mdio-bus 0x00)
#   WLAN  : MT7976CN (2.4G + 5G WiFi6)，eeprom 在 Factory@0
#   LED   : red gpio8 / wan gpio13 / green gpio34 / blue gpio35（低有效）
#   按键  : reset gpio0，mesh/wps gpio1（低有效）
#   串口  : 115200n8，U-Boot 2023.10-rc4，192.168.1.1 上有 Web failsafe
#
# 插件集：沿用 AN7581 (config.an7581-261022-01) 的通用部分，去掉 PON 全家桶
#         （airoha-ponctl / airoha-pond / luci-app-pon / luci-app-iptv /
#           luci-app-pon-wan / airoha xpon 驱动）和 airoha-npu 面板。
#
# 单一 profile：comfast_cf-wr630ax（保持原厂 U-Boot + NMBM/UBI 布局）
#   sysupgrade.bin : OpenWrt 标准 sysupgrade 包（tar）
#   factory.bin    : append-ubi 整包（可整块写入 ubi 分区）
#   *-initramfs-kernel.bin : 内存运行镜像，刷机前验证用
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.mt7981-wr630ax-$VER}
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
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr630ax=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_comfast_cf-wr630ax-512m=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_qihoo_360t7=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_qihoo_360t7-ubi=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_h3c_magic-nx30-pro=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xiaomi_mi-router-ax3000t=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xiaomi_mi-router-ax3000t-ubootmod=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m=y
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

echo "[wr630ax] LuCI / 中文:"
for p in \
	luci-compat \
	luci-i18n-base-zh-cn \
	luci-i18n-firewall-zh-cn \
	luci-i18n-package-manager-zh-cn \
	luci-proto-ipv6 \
	luci-proto-ppp \
	luci-app-firewall \
	luci-app-package-manager \
	luci-app-turboacc \
	gwrt-agent ; do
	add_pkg "$p"
done

echo "[wr630ax] 主题配套插件（面板 + 后端，主题功能必需）:"
for p in \
	luci-app-route-tool \
	luci-app-oaf \
	luci-i18n-oaf-zh-cn \
	appfilter \
	libuci-lua \
	kmod-oaf \
	luci-app-bandix-plus \
	bandix-plus \
	coremark \
	luci-app-ttyd \
	ttyd \
	gwrt-ssr-plus-luci \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	kmod-tun \
	easytier \
	luci-app-easytier ; do
	add_pkg "$p"
done

echo "[wr630ax] 主题依赖（CoreMark 选项 / 下载与解压 / 测温）:"
for p in \
	autocore \
	curl \
	ca-bundle \
	ca-certificates \
	jsonfilter \
	xz \
	tc-full \
	lsblk \
	blkid \
	nano \
	htop \
	lua-neturl \
	lyaml \
	resolveip \
	bind-dig \
	dns2tcp \
	ipt2socks \
	microsocks \
	nping ; do
	add_pkg "$p"
done
# CoreMark 编译选项（主题首页跑分卡）
sed -i 's|^# CONFIG_COREMARK_OPTIMIZE_O3 is not set$|CONFIG_COREMARK_OPTIMIZE_O3=y|' "$TOP/.config"
grep -q '^CONFIG_COREMARK_OPTIMIZE_O3=y$' "$TOP/.config" || echo 'CONFIG_COREMARK_OPTIMIZE_O3=y' >>"$TOP/.config"
sed -i 's|^# CONFIG_COREMARK_ENABLE_MULTITHREADING is not set$|CONFIG_COREMARK_ENABLE_MULTITHREADING=y|' "$TOP/.config"
grep -q '^CONFIG_COREMARK_ENABLE_MULTITHREADING=y$' "$TOP/.config" || echo 'CONFIG_COREMARK_ENABLE_MULTITHREADING=y' >>"$TOP/.config"
# TurboACC：软件流量卸载（FW3）+ 全锥 NAT1（xt_FULLCONENAT/nft-fullcone），拥塞控制保持 CUBIC
for opt in luci-app-turboacc_INCLUDE_OFFLOADING luci-app-turboacc_INCLUDE_NFT_FULLCONE; do
	grep -q "^CONFIG_PACKAGE_$opt=y$" "$TOP/.config" || echo "CONFIG_PACKAGE_$opt=y" >>"$TOP/.config"
done

echo "[wr630ax] zram / NAND 工具链:"
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

echo "[wr630ax] 网络与基础:"
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

echo "[wr630ax] 主题:"
add_pkg luci-theme-gwrt

echo "[wr630ax] 清除（PON 及后期自装重包）:"
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
	gecoosac \
	luci-app-gecoosac \
	docker \
	dockerd \
	docker-compose \
	podman \
	kmod-wireguard \
	kmod-nft-tproxy \
	kmod-inet-diag ; do
	unset_pkg "$p"
done

# --- 3. 复检 ----------------------------------------------------------------
make defconfig >/dev/null

echo "[wr630ax] defconfig 后复检（只清 openclash / gecoosac，主题插件全部保留）:"
for p in \
	openclash \
	luci-app-openclash \
	gecoosac \
	luci-app-gecoosac ; do
	unset_pkg "$p"
done

cp "$TOP/.config" "$OUT"

echo
echo "==> 完成: $OUT"
echo "==> 目标设备:"
grep -E '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_(comfast_cf-wr630ax|qihoo_360t7|h3c_magic|xiaomi_mi-router-ax3000t|cmcc_rax3000m)' "$OUT" || true
echo "==> 体积/布局:"
grep -E '^CONFIG_TARGET_(ROOTFS_PARTSIZE|MULTI_PROFILE|PER_DEVICE_ROOTFS|ROOTFS_INITRAMFS)=' "$OUT" || true
