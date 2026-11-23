#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-sbe1v1k-config.sh — 生成 Askey SBE1V1K (IPQ9570, eMMC) 固件配置
#
# 用法：
#   sh gwrt-mk-sbe1v1k-config.sh          # 生成 configs/config.sbe1v1k-<日期>-01
#   VER=261121-01 sh gwrt-mk-sbe1v1k-config.sh
#   OUT=.config sh gwrt-mk-sbe1v1k-config.sh   # CI 用
#
# 【插件集 = SS-01 Honk + EasyTier 构建】
#   与 gwrt-tyfza1/gwrt-ss01-honk 同一套：honk(Doona Lite) + mesh 四件套 +
#   wifiroam v5 + gwrt 广告拦截 + easytier/iptv/smartdns LuCI + OAF +
#   bandix-plus/ttyd 进阶面板 + GWRT 主题 + coremark。TYFZA1 专属的
#   rtl 内核内无线栈与 PON 用户态不适用本机型，全部去掉。
#
# 【无线栈】
#   ipq9570 内置 2.4/5G radio 走 ath11k-ahb（ath11k-firmware-ipq9574-ddwrt），
#   PCIe QCN9274 6G 走 ath12k（ath12k-firmware-qcn9274-ddwrt，image mk 自带）。
#   标准 backports mac80211，不关闭。PPE 数据面 kmod-qcom-ppe。
#
# 【存储】
#   eMMC（EmmcImage）：不装 NAND/UBI 工具链，换 ext4/f2fs + automount。
#
# 【不影响其它 SoC】
#   脚本只写自己的 .config（先备份现有），不改 feeds/、不改其它 target。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/configs/config.sbe1v1k-$VER}
# CI 会传相对路径 OUT=.config；统一成绝对路径，后面的「是否同一个文件」判断才可靠
case "$OUT" in
	/*) ;;
	*) OUT="$TOP/$OUT" ;;
esac
BAK="$TOP/.config.bak-$(date +%Y%m%d-%H%M%S)"
DEVICE=${DEVICE:-askey_sbe1v1k}

echo "==> 目标: qualcommbe/ipq95xx / $DEVICE"
echo "==> 输出: $OUT"

if [ -f "$TOP/.config" ]; then
	cp "$TOP/.config" "$BAK"
	echo "==> 已备份现有 .config -> $BAK"
fi

mkdir -p "$TOP/configs"
# 单 profile 模式（与 xer5/cs06 序列一致）：不用 MULTI_PROFILE，
# PROFILE 串由 defconfig 从设备符号推导。
cat >"$OUT" <<EOF
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_HOST_OS_LINUX=y
CONFIG_TARGET_qualcommbe=y
CONFIG_TARGET_qualcommbe_ipq95xx=y
$( [ "$DEVICE" = all ] || echo "CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_${DEVICE}=y" )
CONFIG_LINUX_6_18=y
# honk eBPF 需要 /sys/kernel/btf/vmlinux；与 TYFZA1 相同策略，vmlinux-btf-builtin 占位
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

# CI 里用 OUT=.config，这时 OUT 就是 .config，不能自拷贝
[ "$OUT" = "$TOP/.config" ] || cp "$OUT" "$TOP/.config"
make defconfig >/dev/null

if [ "$DEVICE" = "all" ]; then
	sed -i -E "s|^# (CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_[A-Za-z0-9_.-]+) is not set$|\\1=y|" "$TOP/.config"
	echo "==> 全设备模式: $(grep -c "^CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_.*=y$" "$TOP/.config") 个设备"
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

mod_pkg() {
	sym=$1
	grep -q "^CONFIG_PACKAGE_${sym}=m$" "$TOP/.config" && return 0
	if grep -q "^# CONFIG_PACKAGE_${sym} is not set$" "$TOP/.config"; then
		sed -i "s|^# CONFIG_PACKAGE_${sym} is not set$|CONFIG_PACKAGE_${sym}=m|" "$TOP/.config"
	elif grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config"; then
		sed -i "s|^CONFIG_PACKAGE_${sym}=y$|CONFIG_PACKAGE_${sym}=m|" "$TOP/.config"
	else
		echo "CONFIG_PACKAGE_${sym}=m" >>"$TOP/.config"
	fi
	echo "  =m $sym"
}

echo "[sbe1v1k] 无线栈（ath11k-ahb 内置 + ath12k QCN9274，backports mac80211）:"
for p in \
	kmod-ath11k-ahb \
	kmod-ath12k \
	ath11k-firmware-ipq9574-ddwrt \
	wpad-mbedtls \
	wifi-scripts \
	iw \
	wireless-regdb \
	kmod-qcom-ppe \
	kmod-qrtr-mhi ; do
	add_pkg "$p"
done

echo "[sbe1v1k] eMMC 存储（无 NAND/UBI 工具链）:"
for p in \
	mtd \
	block-mount \
	blockd \
	automount \
	kmod-fs-ext4 \
	kmod-fs-f2fs \
	e2fsprogs \
	f2fs-tools \
	losetup \
	kmod-zram \
	zram-swap ; do
	add_pkg "$p"
done

echo "[sbe1v1k] 网络与基础:"
for p in \
	dnsmasq-full \
	ppp-mod-pppoe \
	ip-full \
	luci-proto-ppp \
	luci-proto-ipv6 \
	luci-app-firewall \
	luci-app-opkg \
	luci-app-attendedsysupgrade \
	usbutils ; do
	add_pkg "$p"
done

# mesh 四件套与 SS-01 honk / tyfza1 一致；wifiroam v5 覆盖层由 97 默认值激活。
echo "[sbe1v1k] GWRT mesh 组网（四件套 + wifiroam v5 覆盖层）:"
for p in \
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	gwrt-agent \
	gwrt-wifiroam-v5 ; do
	add_pkg "$p"
done

echo "[sbe1v1k] GWRT 广告拦截:"
for p in \
	gwrt-tv-adblock \
	luci-app-gwrt-tvadblock ; do
	add_pkg "$p"
done

echo "[sbe1v1k] 插件面板（只要 LuCI，不要本体）:"
for p in \
	luci-app-iptv \
	smartdns \
	luci-app-smartdns ; do
	add_pkg "$p"
done

echo "[sbe1v1k] OAF 应用过滤:"
for p in \
	appfilter \
	kmod-oaf \
	luci-app-oaf ; do
	add_pkg "$p"
done

# honk eBPF proxy (daeuniverse feed) with its LuCI page.  UI is Doona Lite,
# preset in feeds/daeuniverse/honk/files/config.dae.
echo "[sbe1v1k] honk (Doona Lite) + LuCI:"
for p in \
	honk \
	luci-app-honk \
	luci-lib-daeuniverse \
	vmlinux-btf-builtin \
	v2ray-geoip \
	v2ray-geosite ; do
	add_pkg "$p"
done

echo "[sbe1v1k] 进阶面板（bandix 流量统计 + ttyd 终端）:"
for p in \
	bandix-plus \
	luci-app-bandix-plus \
	ttyd \
	luci-app-ttyd ; do
	add_pkg "$p"
done

echo "[sbe1v1k] 主题（与整个项目同一版本）:"
add_pkg luci-theme-gwrt

echo "[sbe1v1k] CoreMark 跑分（仪表盘 SoC/主频/CPU 分数）:"
add_pkg coremark

echo "[sbe1v1k] 清除（后期设备自行安装，固件不带）:"
for p in \
	openclash \
	luci-app-openclash \
	easytier \
	easytier-noweb \
	gecoosac \
	luci-app-gecoosac \
	luci-theme-argon \
	ubi-utils \
	nand-utils ; do
	unset_pkg "$p"
done

echo "[sbe1v1k] 可手动安装的模块（=m，不编入固件）:"
for p in \
	docker \
	dockerd \
	docker-compose \
	podman \
	kmod-wireguard \
	kmod-nft-tproxy \
	kmod-inet-diag \
	kmod-fs-nfsd \
	kmod-fs-nfs \
	kmod-fs-nfs-common \
	kmod-fs-cifs ; do
	mod_pkg "$p"
done

echo "[sbe1v1k] 集成插件（编入固件）:"
for p in \
	gwrt-eqos \
	ksmbd-tools \
	nfs-kernel-server \
	aria2 ; do
	add_pkg "$p"
done

make defconfig >/dev/null

if [ "$OUT" != "$TOP/.config" ]; then
	cp "$TOP/.config" "$OUT"
fi

echo
echo "==> 完成: $OUT"
echo "==> 设备: $(grep -c "^CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_.*=y$" "$OUT") 个"
echo "==> profile: $(sed -n 's/^CONFIG_TARGET_PROFILE="\(.*\)"$/\1/p' "$OUT" || echo '空')"
echo "==> 无线: $(grep -E '^CONFIG_PACKAGE_(kmod-ath11k-ahb|kmod-ath12k|wpad-mbedtls|wifi-scripts)=y$' "$OUT" | tr '\n' ' ')"
echo "==> 主题: $(grep -E '^CONFIG_PACKAGE_luci-theme-gwrt=y$' "$OUT" || echo '缺失')"
echo "==> honk: $(grep -E '^CONFIG_PACKAGE_(honk|luci-app-honk|vmlinux-btf)' "$OUT" | tr '\n' ' ')"
echo "==> 进阶: $(grep -E '^CONFIG_PACKAGE_(bandix-plus|luci-app-bandix-plus|ttyd|luci-app-ttyd)=y$' "$OUT" | tr '\n' ' ')"
echo "==> mesh: $(grep -E '^CONFIG_PACKAGE_(gwrt-device-defaults|gwrt-agent|gwrt-mesh-apmode|gwrt-mesh-led|gwrt-wifiroam-v5)=y$' "$OUT" | tr '\n' ' ')"
echo "==> BTF:  $(grep -E '^CONFIG_KERNEL_DEBUG_INFO_BTF=y$' "$OUT" || echo '缺失')"
cat <<'EOF'

[hint] honk uses Doona Lite (feeds/daeuniverse/honk/files/config.dae).
[hint] CONFIG_KERNEL_DEBUG_INFO_BTF is enabled above, so the kernel carries
[hint] its own BTF (/sys/kernel/btf/vmlinux). vmlinux-btf-builtin stands in
[hint] for vmlinux-btf; no VMLINUX_BTF_SRC blob is needed.
[hint] honk itself needs Rust (stable + nightly with rust-src) and bpf-linker;
[hint] use the gwrt-sbe1v1k-build workflow or install them on the build host.
EOF
