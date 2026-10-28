#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cs08-config.sh — 由 CS-06（赵云 / JDCloud BE6500, IPQ5322 eMMC）
#                          配置派生 CS-08（太乙2plus / JDCloud ER2-Plus）配置
#
# 用法:
#   VER=261026-01 sh gwrt-mk-cs08-config.sh [输出文件或目录]
#
# 硬件关系（用户确认 + 上游设备定义）:
#   cs-06 赵云     : IPQ5322 + QCA8386 交换 + ath12k(内置WiFi) + eMMC
#   cs-08 太乙2plus: **同一方案**，但**无 WiFi**，带 **SFP 万兆**
#   上游 image/ipq53xx.mk 对照:
#     cs-06: DEVICE_PACKAGES := ipq-wifi-jdcloud_re-cs-06
#     cs-08: DEVICE_PACKAGES := -kmod-ath12k -wpad-openssl kmod-sfp \
#                               kmod-phy-marvell kmod-phy-marvell-10g
#   两者同为 FitImage+EmmcImage / KERNEL_SIZE 7168k / config@mi01.6 / SOC ipq5322
#
# 派生规则:
#   1. 目标板切到 qualcommbe/ipq53xx DEVICE_jdcloud_re-cs-08（旧设备必须同时停用）
#   2. 去干净整条无线栈（cs-07 的经验：kmod-ath → mac80211 → cfg80211 →
#      hostapd-common/wpad → libiwinfo → wifi-scripts → wireless-regdb）
#   3. 去掉 ath12k 固件（子目标 DEFAULT 带的，无射频设备不需要）
#   4. SFP/万兆驱动由设备定义带出（kmod-sfp / kmod-phy-marvell /
#      kmod-phy-marvell-10g），内核 CONFIG_SFP=y 已在 ipq53xx/config-default
#   5. 其余插件集照 cs-06（= cs-02 插件集）
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.cs06-261026-01}
VER=${VER:-261026-01}
ARG1=${1:-}
case "$ARG1" in
	"") OUT=$TOP/config.cs08-$VER ;;
	*/)  OUT=$ARG1/config.cs08-$VER ;;
	*)   if [ -d "$ARG1" ]; then OUT=$ARG1/config.cs08-$VER; else OUT=$ARG1; fi ;;
esac

[ -f "$SRC" ] || { echo "missing base config: $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

# --- 1. 目标板切换（旧设备停用 + 新设备启用 + 版本号） ----------------------
sed -i \
	-e 's|^CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y$|# CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06 is not set|' \
	-e "s|^CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-cs-06\"\$|CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-cs-08\"|" \
	-e "s|^CONFIG_VERSION_NUMBER=.*\$|CONFIG_VERSION_NUMBER=\"$VER\"|" \
	"$OUT"

cat >> "$OUT" <<EOF
CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-08=y
EOF

# --- 2. 去无线栈（PACKAGE + DEFAULT 两条线） --------------------------------
for p in \
	wpad-openssl wpad-basic-mbedtls hostapd-common wifi-scripts \
	libiwinfo libiwinfo-data rpcd-mod-iwinfo wireless-regdb \
	kmod-ath kmod-ath12k kmod-cfg80211 kmod-mac80211 \
	MAC80211_DEBUGFS \
	ipq-wifi-jdcloud_re-cs-06 \
	ath12k-firmware-ipq5332-ddwrt ath12k-firmware-qcn9274-ddwrt \
; do
	sed -i "s|^CONFIG_PACKAGE_${p}=y\$|# CONFIG_PACKAGE_${p} is not set|" "$OUT"
	sed -i "s|^CONFIG_DEFAULT_${p}=y\$|# CONFIG_DEFAULT_${p} is not set|" "$OUT"
done

# 清掉陈旧显式 n，让 cs-08 设备定义的 +kmod-sfp/+kmod-phy-marvell* 生效
for p in kmod-sfp kmod-phy-marvell kmod-phy-marvell-10g \
         kmod-phy-aquantia kmod-phy-qca83xx kmod-phy-realtek \
         kmod-qcom-ppe kmod-dsa-qca8k kmod-qrtr-mhi kmod-qrtr-smd \
         kmod-usb3 kmod-usb-dwc3 kmod-usb-dwc3-qcom; do
	sed -i "/^# CONFIG_PACKAGE_${p} is not set\$/d" "$OUT"
done

echo "==> generated: $OUT"
echo "    base: $(basename "$SRC")  VER: $VER"
echo "    期望: CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-cs-08\""
echo "    下一步: cp $OUT .config && make defconfig 后复核（无 ath12k/wpad，有 kmod-sfp）"
