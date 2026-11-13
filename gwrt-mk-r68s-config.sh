#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-r68s-config.sh — Lunzn FastRhino R68S (RK3568) 配置生成器
#
# 用法:
#   VER=261113-01 sh gwrt-mk-r68s-config.sh [输出文件或目录]
#   （无参数/目录 -> $TOP(config.r68s-$VER)；跑完后需 make defconfig 收敛）
#
# 硬件（用户确认）:
#   R68S = RK3568 + 2x 2.5G RTL8125 (PCIe) + 2x 1G GMAC (RGMII) + eMMC
#   内核 DTS 有两个 FastRhino:
#     rk3568-fastrhino-r66s.dts  -> TF 卡 (sdmmc0)，无 2.5G
#     rk3568-fastrhino-r68s.dts  -> eMMC (sdhci, non-removable) + 双 2.5G + 双千兆
#   本脚本固定选 r68s 的 eMMC DTS，不用 r66s/TF。
#
# 派生规则（用户指定）:
#   1. 插件集照搬 SS-01（config.ss01-261101-01-nss），不是驱动；
#      驱动由 R68S 自己的设备定义带出（kmod-r8125）。
#   2. 剔除 SS-01 的高通/ath11k/NSS/SSDK/QCA PHY/USB-QCOM 等机型驱动，
#      以及 NAND 工具（R68S 是 eMMC）。
#   3. 目标切到 rockchip/armv8 DEVICE_lunzn_fastrhino-r68s。
#   4. 去掉 passwall（含 INCLUDE_* 与中文包），保留 daed/daed-geoip/daed-geosite。
#   5. eMMC 布局: 256M kernel + 4096M rootfs，保留 sgdisk/e2fsprogs/f2fs-tools。
#      （rockchip 的 sysupgrade 由 platform.sh 整盘 dd，不依赖 emmc.sh）
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.ss01-261101-01-nss}
VER=${VER:-$(date -u +%y%m%d)-01}
ARG1=${1:-}
case "$ARG1" in
	"") OUT=${OUT:-$TOP/config.r68s-$VER} ;;
	*/)  OUT=$ARG1/config.r68s-$VER ;;
	*)   if [ -d "$ARG1" ]; then OUT=$ARG1/config.r68s-$VER; else OUT=$ARG1; fi ;;
esac

[ -f "$SRC" ] || { echo "missing base config: $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

# --- 1. 清掉 SS-01 的目标选择与 target 默认包（defconfig 会按新目标重建） ---
sed -i \
	-e '/^CONFIG_TARGET_/d' \
	-e '/^# CONFIG_TARGET_/d' \
	-e '/^CONFIG_DEFAULT_/d' \
	-e '/^CONFIG_HAS_SUBTARGETS/d' \
	-e '/^CONFIG_HAS_DEVICES/d' \
	-e '/^CONFIG_CPU_TYPE/d' \
	-e '/^CONFIG_CPU_SUBTYPE/d' \
	-e '/^CONFIG_DEFAULT_TARGET_OPTIMIZATION/d' \
	"$OUT"

# --- 2. 剔除 SS-01 机型驱动（高通/NSS/ath11k/QCA PHY/USB-QCOM）与 NAND 工具 --
for p in \
	ath11k-firmware-ipq6018-ddwrt \
	ipq-wifi-jdcloud_re-ss-01 \
	kmod-ath \
	kmod-ath11k \
	kmod-ath11k-ahb \
	kmod-qca-nss-dp \
	kmod-qca-nss-drv \
	kmod-qca-nss-drv-bridge-mgr \
	kmod-qca-nss-drv-vlan-mgr \
	kmod-qca-nss-ecm \
	kmod-qca-ssdk \
	nss-eip-firmware \
	nss-firmware \
	nss-firmware-ipq60xx \
	kmod-dsa-qca8k \
	kmod-phylib-qcom \
	kmod-phy-qca83xx \
	kmod-phy-aquantia \
	kmod-atlantic \
	kmod-mhi-bus \
	kmod-qrtr \
	kmod-qrtr-mhi \
	kmod-qrtr-smd \
	kmod-usb-dwc3-qcom \
	kmod-usb-serial-qualcomm \
	kmod-r8169 \
	mtd \
	ubi-utils \
	nand-utils \
; do
	sed -i "/^CONFIG_PACKAGE_${p}=y\$/d" "$OUT"
	sed -i "/^CONFIG_PACKAGE_${p}=m\$/d" "$OUT"
done

# --- 3. 去掉 passwall（保留 daed） ------------------------------------------
sed -i \
	-e '/^CONFIG_PACKAGE_luci-app-passwall/d' \
	-e '/^CONFIG_PACKAGE_luci-i18n-passwall/d' \
	"$OUT"

# --- 4. 新目标 + eMMC 分区 + 版本 ------------------------------------------
# 单设备 profile，避免 multi-profile 串台
sed -i '/^CONFIG_TARGET_ROOTFS_INITRAMFS=/d' "$OUT"

cat >> "$OUT" <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_lunzn_fastrhino-r68s=y
CONFIG_TARGET_PROFILE="DEVICE_lunzn_fastrhino-r68s"
CONFIG_TARGET_BOARD="rockchip"
CONFIG_TARGET_SUBTARGET="armv8"
CONFIG_TARGET_KERNEL_PARTSIZE=256
CONFIG_TARGET_ROOTFS_PARTSIZE=4096
# CONFIG_TARGET_ROOTFS_INITRAMFS is not set
CONFIG_VERSION_DIST="GWRT"
CONFIG_VERSION_NUMBER="$VER"
EOF

# --- 5. R68S 必需项（驱动/eMMC/daed/GWRT 组件） ----------------------------
# sgdisk 供 eMMC 分区维护；文件系统工具与 SS-01 保持一致。
for p in \
	kmod-r8125 \
	sgdisk \
	e2fsprogs \
	f2fs-tools \
	f2fsck \
	losetup \
	block-mount \
	automount \
	daed \
	daed-geoip \
	daed-geosite \
	luci-app-daed \
	luci-i18n-daed-zh-cn \
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	gwrt-agent \
	luci-theme-gwrt \
; do
	sed -i "/^# CONFIG_PACKAGE_${p} is not set\$/d" "$OUT"
	sed -i "/^# CONFIG_${p} is not set\$/d" "$OUT"
	grep -q "^CONFIG_PACKAGE_${p}=y\$" "$OUT" && continue
	grep -q "^CONFIG_${p}=y\$" "$OUT" && continue
	echo "CONFIG_PACKAGE_${p}=y" >> "$OUT"
done

echo "==> generated: $OUT"
echo "    base: $(basename "$SRC")  VER: $VER"
echo "    target: rockchip/armv8 DEVICE_lunzn_fastrhino-r68s (eMMC DTS)"
echo "    passwall removed, daed kept; drivers: kmod-r8125 only"
echo "    下一步: cp $OUT .config && make defconfig 后复核"
