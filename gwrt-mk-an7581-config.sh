#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-an7581-config.sh — 生成 Airoha AN7581 光猫固件配置
#
# 用法：
#   sh gwrt-mk-an7581-config.sh            # 生成 config.an7581-<日期>-01 并跑 defconfig
#   VER=261022-02 sh gwrt-mk-an7581-config.sh
#
# 目标：
#   首个目标机型 nokia xg-040g-md（UBI 变体），同时保留全部 AN7581 ONT 设备条目。
#
# 【存储 profile】
#   NAND 板统一 UBI（squashfs on UBI + KERNEL_IN_UBI + UBOOTENV_IN_UBI）；
#   eMMC 板（evb-emmc-eagle / evb-emmc-kite）保留 CONFIG_MMC* 并追加
#   mmc-utils / parted / dosfstools / f2fs-tools 轻量套件（见 image/Makefile
#   的 AIROHA_EMMC_STORAGE_PACKAGES）。
#
# 【PON 驱动】
#   kmod-airoha-xpon / kmod-airoha-pon-frontend / kmod-airoha-en7572 /
#   kmod-airoha-paged-bosa + airoha-ponctl / airoha-pond / luci-app-pon /
#   luci-app-iptv。设备条目里也带了 kmod-airoha-en7572 + kmod-airoha-xpon +
#   airoha-ponctl + airoha-pond，两边都会生效。
#
# 【体积预算 ~50MB】
#   固件内：基础系统 + LuCI + 主题 + PON + npu/bandix/route-tool/easytier 面板 + zram。
#   （261120 加回 bandix-plus：主题流量监控取样唯一源是 Bandix，光猫固件不带它
#   首页流量卡就没有数据；aarch64 预编译二进制约 2.6MB 压缩包。）
#   固件外（后期设备自行安装）：gecoosac(15.6MB)、openclash 面板(带 ruby)、
#   openclash/easytier 本体、docker/podman、kmod-wireguard。
#   注意：gwrt-theme-V3/manifest/config.fragment 里带 openclash/bandix/
#   coremark/ttyd，本脚本不并入该 fragment；coremark 由本脚本显式加入，
#   其余重包不装，避免顶破体积预算。
#
# 【不覆盖隔壁编译】
#   本脚本只写自己的 .config（先备份现有 .config），不改动 feeds/ 与其它
#   target；target/linux/airoha 的改动只影响 airoha 目标。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/configs/config.an7581-$VER}
BAK="$TOP/.config.bak-$(date +%Y%m%d-%H%M%S)"

DEVICE=${DEVICE:-nokia_xg-040g-md-ubi}
SUB=${SUB:-an7581}                 # an7581 / an7583
WITH_OPENCLASH=${WITH_OPENCLASH:-0} # 1 = 带 OpenClash 面板
WITH_SMB=${WITH_SMB:-0}             # 1 = 带 Samba4

echo "==> 目标: $SUB / $DEVICE"
echo "==> 输出: $OUT"

# --- 0. 备份现有 .config（避免影响同树其它 profile）-------------------------
if [ -f "$TOP/.config" ]; then
	cp "$TOP/.config" "$BAK"
	echo "==> 已备份现有 .config -> $BAK"
fi

# --- 1. 最小 seed config ----------------------------------------------------
cat >"$OUT" <<EOF
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_HOST_OS_LINUX=y
CONFIG_TARGET_airoha=y
CONFIG_TARGET_airoha_${SUB}=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
$( [ "$DEVICE" = all ] || echo "CONFIG_TARGET_DEVICE_airoha_${SUB}_DEVICE_${DEVICE}=y" )
CONFIG_LINUX_6_18=y
# honk（eBPF 透明代理）需要 /sys/kernel/btf/vmlinux，vmlinux-btf 从内核 BTF
# 导出；不开这一项 honk 运行时 CO-RE 重定位会失败。
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

if [ "$OUT" != ".config" ] && [ "$OUT" != "$TOP/.config" ]; then
	cp "$OUT" "$TOP/.config"
fi

# --- 2. defconfig 展开出完整选项 -------------------------------------------
make defconfig >/dev/null

if [ "$DEVICE" = "all" ]; then
	sed -i -E "s|^# (CONFIG_TARGET_DEVICE_airoha_${SUB}_DEVICE_[A-Za-z0-9_.-]+) is not set$|\\1=y|" "$TOP/.config"
	echo "==> 全设备模式: $(grep -c "^CONFIG_TARGET_DEVICE_airoha_${SUB}_DEVICE_.*=y$" "$TOP/.config") 个设备"
fi

# --- 3. 追加选包 ------------------------------------------------------------
add_pkg() {
	sym=$1
	grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config" && return 0
	if grep -q "^# CONFIG_PACKAGE_${sym} is not set$" "$TOP/.config"; then
		sed -i "s|^# CONFIG_PACKAGE_${sym} is not set$|CONFIG_PACKAGE_${sym}=y|" "$TOP/.config"
	else
		# Hidden symbols are absent from .config; append and let defconfig keep it.
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

echo "[an7581] PON 驱动与用户态:"
for p in \
	kmod-airoha-xpon \
	kmod-airoha-pon-frontend \
	kmod-airoha-en7572 \
	kmod-airoha-paged-bosa \
	airoha-ponctl \
	airoha-pond \
	airoha-pon-debug \
	luci-app-pon \
	luci-i18n-pon-zh-cn \
	luci-app-iptv \
	luci-i18n-iptv-zh-cn \
	luci-app-pon-wan \
	luci-app-pon-info ; do
	add_pkg "$p"
done

echo "[an7581] 插件面板（只要 LuCI，不要本体/内核扩展）:"
for p in \
	luci-app-airoha-npu \
	luci-app-bandix-plus \
	luci-i18n-bandix-plus-zh-cn \
	bandix-plus \
	luci-app-route-tool \
	luci-app-easytier \
	luci-i18n-easytier-zh-cn ; do
	add_pkg "$p"
done

# Honk（daeuniverse，需 configs/an758x-feeds.conf 里的 daeuniverse feed）
# 与 OpenAppFilter（feeds/packages/net/open-app-filter，luci-app-oaf 会带
# appfilter + kmod-oaf + luci-compat）。
echo "[$SUB] Honk + OpenAppFilter:"
for p in \
	honk \
	luci-app-honk \
	luci-app-oaf ; do
	add_pkg "$p"
done

echo "[an7581] zram / NAND 工具链:"
for p in \
	kmod-zram \
	zram-swap \
	nand-utils \
	ubi-utils \
	mtd \
	fitblk ; do
	add_pkg "$p"
done

echo "[an7581] NPU 插件数据源（/dev/mem + busybox devmem）:"
# luci-app-airoha-npu 的 Frame Engine 段、CPU PLL 读取和直接超频都依赖
# /sbin/devmem + /dev/mem。261022-01 首版两者都关着，插件状态详情整段无数据；
# 261110-07 实机验证已开启，这里固化为默认（261119）。
sed -i 's|^# CONFIG_KERNEL_DEVMEM is not set$|CONFIG_KERNEL_DEVMEM=y|' "$TOP/.config"
grep -q '^CONFIG_KERNEL_DEVMEM=y$' "$TOP/.config" || echo 'CONFIG_KERNEL_DEVMEM=y' >>"$TOP/.config"
sed -i 's|^# CONFIG_BUSYBOX_DEFAULT_DEVMEM is not set$|CONFIG_BUSYBOX_DEFAULT_DEVMEM=y|' "$TOP/.config"
grep -q '^CONFIG_BUSYBOX_DEFAULT_DEVMEM=y$' "$TOP/.config" || echo 'CONFIG_BUSYBOX_DEFAULT_DEVMEM=y' >>"$TOP/.config"
echo "  + CONFIG_KERNEL_DEVMEM / CONFIG_BUSYBOX_DEFAULT_DEVMEM"

echo "[an7581] 网络与基础:"
for p in \
	dnsmasq-full \
	ppp-mod-pppoe \
	ip-full \
	luci-proto-ipv6 \
	luci-app-firewall \
	luci-app-opkg \
	luci-app-attendedsysupgrade \
	usbutils \
	blockd \
	block-mount ; do
	add_pkg "$p"
done

echo "[$SUB] GWRT mesh 组网（所有机型必备）:"
for p in \
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	gwrt-agent ; do
	add_pkg "$p"
done

echo "[$SUB] GWRT 广告拦截（电视 + 国内通用, 纯文本规则库）:"
for p in \
	gwrt-tv-adblock \
	luci-app-gwrt-tvadblock ; do
	add_pkg "$p"
done

echo "[an7581] CoreMark 跑分（仪表盘 SoC/主频/CPU 分数）:"
add_pkg coremark

echo "[an7581] 主题:"
for p in \
	luci-theme-gwrt ; do
	add_pkg "$p"
done

echo "[an7581] 清除（后期设备自行安装，固件不带）:"
for p in \
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
	luci-app-ttyd \
	ttyd ; do
	unset_pkg "$p"
done

if [ "${WITH_OPENCLASH}" != "1" ]; then
	unset_pkg openclash
	unset_pkg luci-app-openclash
fi

if [ "${WITH_SMB}" = "1" ]; then
	echo "[$SUB] Samba4:"
	for p in \
		samba4-server luci-app-samba4 \
		kmod-fs-ext4 kmod-fs-exfat kmod-fs-vfat kmod-fs-ntfs3 kmod-fs-f2fs \
		e2fsprogs f2fs-tools automount block-mount ; do
		add_pkg "$p"
	done
fi

if [ "${WITH_OPENCLASH}" = "1" ]; then
	echo "[$SUB] OpenClash（面板+脚本，clash 内核运行期下载）:"
	for p in \
		luci-app-openclash dnsmasq-full bash curl ca-bundle unzip ruby ruby-yaml \
		kmod-inet-diag kmod-nft-tproxy kmod-tun luci-compat ; do
		add_pkg "$p"
	done
fi

# --- 4. 再次 defconfig 并强制复检 --------------------------------------------
make defconfig >/dev/null

# 主题整合脚本（gwrt-theme-V3/scripts/integrate.sh）会把 manifest/config.fragment
# 并进 .config，里面带 openclash / bandix-plus / ttyd / oaf。
# 本固件要控体积，这些一律不留；coremark 由前面显式加入并保留。
echo "[an7581] defconfig 后复检（主题 fragment 带入的重包）:"
OC_KEEP=""
[ "${WITH_OPENCLASH}" = "1" ] && OC_KEEP="1"
for p in \
	openclash \
	luci-app-openclash \
	luci-app-ttyd \
	ttyd \
	kmod-tun \
	kmod-nft-tproxy \
	kmod-inet-diag \
	gecoosac \
	luci-app-gecoosac ; do
	case "$p" in
		openclash|luci-app-openclash|kmod-tun|kmod-nft-tproxy|kmod-inet-diag)
			[ -n "$OC_KEEP" ] && continue ;;
	esac
	unset_pkg "$p"
done
make defconfig >/dev/null

# honk 的 BTF 由内核自带（CONFIG_KERNEL_DEBUG_INFO_BTF=y），改用
# vmlinux-btf-builtin 提供 @vmlinux-btf；真正的 vmlinux-btf 需要外部 blob，
# 编译必失败（"the BTF blob is missing"），必须排除。
for f in "$TOP/.config" "$OUT"; do
	[ -f "$f" ] || continue
	sed -i -e 's|^CONFIG_PACKAGE_vmlinux-btf=y$|# CONFIG_PACKAGE_vmlinux-btf is not set|' \
	       -e 's|^# CONFIG_PACKAGE_vmlinux-btf-builtin is not set$|CONFIG_PACKAGE_vmlinux-btf-builtin=y|' "$f"
	grep -q '^# CONFIG_PACKAGE_vmlinux-btf is not set$' "$f" || echo '# CONFIG_PACKAGE_vmlinux-btf is not set' >>"$f"
	grep -q '^CONFIG_PACKAGE_vmlinux-btf-builtin=y$' "$f" || echo 'CONFIG_PACKAGE_vmlinux-btf-builtin=y' >>"$f"
done

if [ "$OUT" != ".config" ] && [ "$OUT" != "$TOP/.config" ]; then
	cp "$TOP/.config" "$OUT"
fi

echo
echo "==> 完成: $OUT"
echo "==> 设备: $(grep -c "^CONFIG_TARGET_DEVICE_airoha_${SUB}_DEVICE_.*=y$" "$OUT") 个"
echo "==> PON:  $(grep -E '^CONFIG_PACKAGE_(kmod-airoha|airoha-pon|luci-app-pon)' "$OUT" | tr '\n' ' ')"
echo "==> 体积预算检查（下面是 .config 里仍为 y 的重包，实际体积以构建为准）:"
grep -E '^CONFIG_PACKAGE_(gecoosac|openclash|docker|podman|kmod-wireguard)=y$' "$OUT" || echo "  重包均已排除"
echo "==> 插件: $(grep -E '^CONFIG_PACKAGE_(honk|luci-app-honk|luci-app-oaf|appfilter|kmod-oaf)=y$' "$OUT" | tr '\n' ' ')"
echo "==> BTF:  $(grep -E '^CONFIG_KERNEL_DEBUG_INFO_BTF=y$' "$OUT" || echo '缺失')"
