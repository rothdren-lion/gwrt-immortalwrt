#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-tyfza1-config.sh — 生成 Realtek RTL9617C / TYFZA1 光猫固件配置
#
# 用法：
#   sh gwrt-mk-tyfza1-config.sh            # 生成 configs/config.tyfza1-<日期>-01
#   VER=261118-01 sh gwrt-mk-tyfza1-config.sh
#   WITH_SMB=1 sh gwrt-mk-tyfza1-config.sh
#
# 【与 an7581 序列对齐】
#   内核线同为 6.18（CONFIG_LINUX_6_18），插件集沿用 gwrt-mk-an7581-config.sh：
#   GWRT mesh 四件套、广告拦截、主题、zram/NAND 工具链、网络基础。
#   PON 用户态换成 TYFZA1 自有实现（tyfza1-pon-control / tyfza1-storage /
#   luci-app-tyfza1-pon）+ 通用 luci-app-pon-wan。
#
# 【无线栈】
#   rtl9617c 目标把 cfg80211/mac80211 与 rtl_ax_ap 编译进内核树，
#   kmod-rtl-ax-ap 直接打包这些 .ko；因此必须关闭 backports 版
#   kmod-mac80211 / kmod-cfg80211，否则同名模块冲突。
#
# 【不影响其它 SoC】
#   脚本只写自己的 .config（先备份现有），不改 feeds/、不改其它 target。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/configs/config.tyfza1-$VER}
# CI 会传相对路径 OUT=.config；统一成绝对路径，后面的「是否同一个文件」判断才可靠
case "$OUT" in
	/*) ;;
	*) OUT="$TOP/$OUT" ;;
esac
BAK="$TOP/.config.bak-$(date +%Y%m%d-%H%M%S)"
DEVICE=${DEVICE:-tianyi_tyfza1}
WITH_SMB=${WITH_SMB:-0}

echo "==> 目标: rtl9617c / $DEVICE"
echo "==> 输出: $OUT"

if [ -f "$TOP/.config" ]; then
	cp "$TOP/.config" "$BAK"
	echo "==> 已备份现有 .config -> $BAK"
fi

mkdir -p "$TOP/configs"
cat >"$OUT" <<EOF
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_HOST_OS_LINUX=y
CONFIG_TARGET_rtl9617c=y
CONFIG_TARGET_rtl9617c_generic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
$( [ "$DEVICE" = all ] || echo "CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_${DEVICE}=y" )
CONFIG_LINUX_6_18=y
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

# CI 里用 OUT=.config，这时 OUT 就是 .config，不能自拷贝
[ "$OUT" = "$TOP/.config" ] || cp "$OUT" "$TOP/.config"
make defconfig >/dev/null

if [ "$DEVICE" = "all" ]; then
	sed -i -E "s|^# (CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_[A-Za-z0-9_.-]+) is not set$|\\1=y|" "$TOP/.config"
	echo "==> 全设备模式: $(grep -c "^CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_.*=y$" "$TOP/.config") 个设备"
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
	grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config" || return 0
	sed -i "s|^CONFIG_PACKAGE_${sym}=y$|# CONFIG_PACKAGE_${sym} is not set|" "$TOP/.config"
	echo "  - $sym"
}

echo "[tyfza1] 无线栈（内核内 mac80211 + rtl_ax_ap，关闭 backports 版）:"
for p in \
	kmod-rtl-ax-ap \
	kmod-tyfza1-usb-led \
	wpad-mbedtls \
	wifi-scripts \
	iw \
	wireless-regdb ; do
	add_pkg "$p"
done
for p in kmod-mac80211 kmod-cfg80211 ; do
	unset_pkg "$p"
done

echo "[tyfza1] PON 用户态:"
for p in \
	tyfza1-pon-control \
	tyfza1-storage \
	luci-app-tyfza1-pon \
	luci-app-pon-wan \
	luci-app-pon-info ; do
	add_pkg "$p"
done

echo "[tyfza1] NAND / UBI 工具链:"
for p in \
	ubi-utils \
	nand-utils \
	uboot-envtools \
	mtd \
	kmod-zram \
	zram-swap ; do
	add_pkg "$p"
done

echo "[tyfza1] 网络与基础:"
for p in \
	dnsmasq-full \
	ppp-mod-pppoe \
	ip-full \
	luci-proto-ppp \
	luci-proto-ipv6 \
	luci-app-firewall \
	luci-app-opkg \
	luci-app-attendedsysupgrade \
	usbutils \
	blockd \
	block-mount ; do
	add_pkg "$p"
done

# mesh 四件套与 an7581 一致；额外带 gwrt-wifiroam-v5 覆盖层（mesh 优化：
# v5 守护进程 + 拓扑/客户端页面 + NFQUEUE 应用识别），由 97 默认值激活。
echo "[tyfza1] GWRT mesh 组网（四件套 + wifiroam v5 覆盖层）:"
for p in \
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	gwrt-agent \
	gwrt-wifiroam-v5 ; do
	add_pkg "$p"
done

echo "[tyfza1] GWRT 广告拦截:"
for p in \
	gwrt-tv-adblock \
	luci-app-gwrt-tvadblock ; do
	add_pkg "$p"
done

echo "[tyfza1] 插件面板（只要 LuCI，不要本体）:"
for p in \
	luci-app-easytier \
	luci-app-iptv \
	smartdns \
	luci-app-smartdns ; do
	add_pkg "$p"
done

echo "[tyfza1] OAF 应用过滤:"
for p in \
	appfilter \
	kmod-oaf \
	luci-app-oaf ; do
	add_pkg "$p"
done

# honk eBPF proxy (daeuniverse feed) with its LuCI page.  UI is Doona Lite,
# preset in feeds/daeuniverse/honk/files/config.dae for this ONU only.
echo "[tyfza1] honk (Doona Lite) + LuCI:"
for p in \
	honk \
	luci-app-honk \
	luci-lib-daeuniverse \
	vmlinux-btf-builtin \
	v2ray-geoip \
	v2ray-geosite ; do
	add_pkg "$p"
done

# 流量统计与网页终端。两者的默认值由 gwrt-device-defaults 的
# files/96_gwrt-lite-panels 写入：bandix 只统计 br-lan（8787），
# ttyd 只监听 LAN（7681，/bin/login）。
echo "[tyfza1] 进阶面板（bandix 流量统计 + ttyd 终端）:"
for p in \
	bandix-plus \
	luci-app-bandix-plus \
	ttyd \
	luci-app-ttyd ; do
	add_pkg "$p"
done

echo "[tyfza1] 主题（与整个项目同一版本）:"
add_pkg luci-theme-gwrt

# The dashboard shows the SoC, its clock and a CoreMark score.  CoreMark is
# small and the theme renders it on the TYFZA1 overview, so keep it in the
# image instead of leaving it to a manual post-flash install.
echo "[tyfza1] CoreMark 跑分（仪表盘 SoC/主频/CPU 分数）:"
add_pkg coremark

echo "[tyfza1] 清除（后期设备自行安装，固件不带）:"
for p in \
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
	kmod-nft-tproxy \
	kmod-inet-diag \
	luci-theme-argon ; do
	unset_pkg "$p"
done

if [ "${WITH_SMB}" = "1" ]; then
	echo "[tyfza1] Samba4:"
	for p in \
		samba4-server luci-app-samba4 \
		kmod-fs-ext4 kmod-fs-exfat kmod-fs-vfat kmod-fs-ntfs3 \
		e2fsprogs automount block-mount ; do
		add_pkg "$p"
	done
fi

make defconfig >/dev/null

if [ "$OUT" != "$TOP/.config" ]; then
	cp "$TOP/.config" "$OUT"
fi

echo
echo "==> 完成: $OUT"
echo "==> 设备: $(grep -c "^CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_.*=y$" "$OUT") 个"
echo "==> 无线: $(grep -E '^CONFIG_PACKAGE_(kmod-rtl-ax-ap|wpad-mbedtls|wifi-scripts)=y$' "$OUT" | tr '\n' ' ')"
echo "==> PON:  $(grep -E '^CONFIG_PACKAGE_(tyfza1|luci-app-tyfza1|luci-app-pon)' "$OUT" | tr '\n' ' ')"
echo "==> 主题: $(grep -E '^CONFIG_PACKAGE_luci-theme-gwrt=y$' "$OUT" || echo '缺失')"
echo "==> honk: $(grep -E '^CONFIG_PACKAGE_(honk|luci-app-honk|vmlinux-btf)' "$OUT" | tr '\n' ' ')"
echo "==> 进阶: $(grep -E '^CONFIG_PACKAGE_(bandix-plus|luci-app-bandix-plus|ttyd|luci-app-ttyd)=y$' "$OUT" | tr '\n' ' ')"
echo "==> 冲突检查（应为空）: $(grep -E '^CONFIG_PACKAGE_(kmod-mac80211|kmod-cfg80211)=y$' "$OUT" || true)"
cat <<'EOF'

[hint] honk uses Doona Lite (feeds/daeuniverse/honk/files/config.dae).
[hint] config-6.18 enables CONFIG_KERNEL_DEBUG_INFO_BTF, so the kernel carries
[hint] its own BTF (/sys/kernel/btf/vmlinux). vmlinux-btf-builtin stands in for
[hint] vmlinux-btf there; no VMLINUX_BTF_SRC blob is needed.
[hint] honk itself needs Rust (stable + nightly with rust-src) and bpf-linker;
[hint] use the gwrt-tyfza1-build workflow or install them on the build host.
EOF
