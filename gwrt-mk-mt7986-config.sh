#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-mt7986-config.sh — 生成 MT7986 配置（磊科 N60 / N60 Pro、京东云 RE-CP-03）
#
# 用法：
#   sh gwrt-mk-mt7986-config.sh
#   VER=261105-01 sh gwrt-mk-mt7986-config.sh
#
# 设备（均为 MT7986A，SPI-NAND / eMMC）：
#   netcore_n60      磊科 N60        NAND 128M，mt7986a
#   netcore_n60-pro  磊科 N60 Pro    NAND，mt7986a（别名 NX62），带 USB3
#   jdcloud_re-cp-03 京东云 RE-CP-03 eMMC，sysupgrade.itb
#
# RE-CS-05 是 RE-CP-03 的新名称；两者使用现有 jdcloud_re-cp-03 profile。
#   京东云 RE-CS-03（哪吒 AX3000）不是 MT7986，是 IPQ5018 → 用 nezha 预设。
#
# 插件集：与 MT7981 预设同一套 GWRT 插件
#
# 产物：
#   sysupgrade.bin / sysupgrade.itb : 标准升级包
#   factory.bin                     : 整包（视设备而定）
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.mt7986-$VER}
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
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_jdcloud_re-cp-03=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_clx_s20p=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_clx_s20l=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_clx_s20m=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_glinet_gl-mt6000=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_netcore_n60-pro=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xiaomi_redmi-router-ax6000-stock=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xiaomi_redmi-router-ax6000-ubootmod=y
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

# OUT 可能就是 .config（CI 用 OUT=.config 直接生成顶层配置），此时不能 cp 自己
if [ "$(readlink -f "$OUT")" != "$(readlink -f "$TOP/.config")" ]; then
	cp "$OUT" "$TOP/.config"
fi

# --- 2. defconfig 展开 ------------------------------------------------------
# GWRT_NO_SELF_DEFCONFIG=1 时跳过：CI 用 OUT=.config 时顶层会自己 make defconfig，
# 而且生成器内部跑 defconfig 在 CI 上会挂在 scripts/config/conf 上。
# 跳过时 add_pkg/unset_pkg 走"直接追加行"分支，后面顶层 defconfig 会认。
if [ -z "$GWRT_NO_SELF_DEFCONFIG" ]; then
	make defconfig >/dev/null
fi

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
	elif ! grep -q "^# CONFIG_PACKAGE_${sym} is not set$" "$TOP/.config"; then
		# 行不存在（如跳过内部 defconfig 时）也强制写一条 not set，
		# 否则 dnsmasq 与 dnsmasq-full 会冲突
		echo "# CONFIG_PACKAGE_${sym} is not set" >>"$TOP/.config"
		echo "  - $sym (appended)"
	fi
}

echo "[mt7986] LuCI / 中文:"
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

echo "[mt7986] GWRT 广告拦截（电视 + 国内通用, 纯文本规则库）:"
for p in \
	gwrt-tv-adblock \
	luci-app-gwrt-tvadblock ; do
	add_pkg "$p"
done

echo "[mt7986] 主题配套插件（面板 + 后端，主题功能必需）:"
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
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	kmod-tun \
	kmod-mtd-rw \
	easytier \
	luci-app-easytier ; do
	add_pkg "$p"
done

# kmod-mtd-rw（package/kernel/mtd-rw）: 解锁 DTS 里 `read-only` 的 MTD 分区
# （filogic 机型的 Factory 分区就是 read-only）。开机自动
# `insmod mtd-rw i_want_a_brick=1`，之后 `mtd write Factory ...` 才可用。
# 2026-11-02 360T7 校准丢失事故后补入，详见
# docs/WORKLOG-20261102-360t7-ubi-migration-factory-bdf.md §6.3

echo "[mt7986] 主题依赖（CoreMark 选项 / 下载与解压 / 测温）:"
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
# TurboACC：软件流量卸载（FW3）+ 全锥 NAT1（xt_FULLCONENAT/nft-fullcone）+ MTK WED（mt7915e wed_enable=Y），拥塞控制保持 CUBIC
for opt in luci-app-turboacc_INCLUDE_OFFLOADING luci-app-turboacc_INCLUDE_NFT_FULLCONE; do
	grep -q "^CONFIG_PACKAGE_$opt=y$" "$TOP/.config" || echo "CONFIG_PACKAGE_$opt=y" >>"$TOP/.config"
done
# mac80211 特性与已知好版本（261025-45）对齐：defconfig 曾把这两项丢掉，
# 会造成 mac80211.ko 与 mt76 驱动 ABI 不一致 → mt798x-wmac probe -12、无 WiFi
for opt in PACKAGE_MAC80211_DEBUGFS PACKAGE_MAC80211_MESH; do
	if grep -q "^# CONFIG_${opt} is not set$" "$TOP/.config"; then
		sed -i "s|^# CONFIG_${opt} is not set$|CONFIG_${opt}=y|" "$TOP/.config"
	elif ! grep -q "^CONFIG_${opt}=y$" "$TOP/.config"; then
		echo "CONFIG_${opt}=y" >>"$TOP/.config"
	fi
done

echo "[mt7986] zram / NAND 工具链:"
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

echo "[mt7986] 网络与基础:"
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

echo "[mt7986] 主题:"
add_pkg luci-theme-gwrt

echo "[mt7986] 清除（PON 及后期自装重包）:"
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
	gecoosac \
	luci-app-gecoosac \
	docker \
	dockerd \
	docker-compose \
	podman \
	kmod-wireguard ; do
	unset_pkg "$p"
done

# --- 3. 复检 ----------------------------------------------------------------
if [ -z "$GWRT_NO_SELF_DEFCONFIG" ]; then
	make defconfig >/dev/null
fi

echo "[mt7986] defconfig 后复检（只清 openclash / gecoosac，主题插件全部保留）:"
for p in \
	gecoosac \
	luci-app-gecoosac ; do
	unset_pkg "$p"
done

# --- 4. 追加插件（放在所有 unset 之后，否则会被清掉） ----------------------
echo "[mt7986] 代理 / 任务管理 / 资源管理器:"
unset_pkg dnsmasq          # openclash 依赖 dnsmasq-full，与预装 dnsmasq 互斥
for p in \
	luci-app-openclash \
	dnsmasq-full \
	taskd \
	luci-lib-taskd \
	luci-app-harbor-file ; do
	add_pkg "$p"
done

echo "[mt7986] NVMe / USB / 共享（eMMC 机型）:"
for p in \
	kmod-nvme \
	nvme-cli \
	kmod-usb3 \
	kmod-usb-storage \
	kmod-usb-storage-uas \
	kmod-usb-storage-extras \
	kmod-fs-ext4 \
	kmod-fs-exfat \
	kmod-fs-vfat \
	kmod-fs-f2fs \
	kmod-fs-ntfs3 \
	samba4-server \
	luci-app-samba4 \
	luci-i18n-samba4-zh-cn \
	kmod-fs-nfs \
	kmod-fs-nfs-common \
	kmod-fs-nfsd \
	nfs-kernel-server-v4 \
	libuuid \
	libblkid \
	aria2 \
	luci-app-aria2 \
	luci-i18n-aria2-zh-cn \
	miniupnpd-nftables \
	luci-app-upnp \
	automount \
	block-mount \
	f2fs-tools \
	f2fsck \
	e2fsprogs ; do
	add_pkg "$p"
done

if [ "$(readlink -f "$TOP/.config")" != "$(readlink -f "$OUT")" ]; then
	cp "$TOP/.config" "$OUT"
fi

echo
echo "==> 完成: $OUT"
echo "==> 目标设备 (MT7986):"
grep -E '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_(jdcloud_re-cp-03|clx_s20[pml]|glinet_gl-mt6000|netcore_n60-pro|xiaomi_redmi-router-ax6000-(stock|ubootmod))' "$OUT" || true
echo "==> 体积/布局:"
grep -E '^CONFIG_TARGET_(ROOTFS_PARTSIZE|MULTI_PROFILE|PER_DEVICE_ROOTFS|ROOTFS_INITRAMFS)=' "$OUT" || true
