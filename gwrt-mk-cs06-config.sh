#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cs06-config.sh — 由 CS-02 (京东云亚瑟 RE-CS-02, IPQ6018, NAND)
#                           配置派生 JDCloud RE-CS-06 (IPQ5322, eMMC) 配置
#
# 用法:
#   VER=261026-01 sh gwrt-mk-cs06-config.sh [输出文件或目录]
#   （无参数/目录 -> $TOP(config.cs06-$VER)；跑完后需 make defconfig 收敛）
#
# 派生规则（用户指定）:
#   1. 插件集照搬 CS-02（config.cs02-gwrt2-261021-04）
#   2. 剔除 CS-02 机型专属驱动: ath11k 全家 + ipq-wifi-jdcloud_re-cs-02
#      （kmod-ath / kmod-mac80211 / kmod-cfg80211 / wpad-openssl 公共栈保留，
#        ath12k 的 DEPENDS 会继续用它们）
#   3. 目标板切到 qualcommbe/ipq53xx DEVICE_jdcloud_re-cs-06
#      【设备 choice 陷阱】旧设备必须同时停用，否则 defconfig 收敛回旧机型
#   4. CS-06 自身必需驱动不手填，由设备/子目标默认带出（defconfig 自动 select）:
#      ipq-wifi-jdcloud_re-cs-06、kmod-ath12k(含 ATH12K_AHB)、
#      ath12k-firmware-{ipq5332,qcn9274}-ddwrt、kmod-qcom-ppe、
#      kmod-dsa-qca8k(QCA8386)、kmod-qrtr-mhi/smd、kmod-phy-qca83xx
#   5. eMMC: 内核存储选项由 qualcommbe config-6.18 经 defconfig 重新归一，
#      CS-02 的 NAND 选项(CONFIG_NAND_SUPPORT/UBIFS 等)不迁移
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.cs02-gwrt2-261021-04}
VER=${VER:-261026-01}
ARG1=${1:-}
case "$ARG1" in
	"") OUT=$TOP/config.cs06-$VER ;;
	*/)  OUT=$ARG1/config.cs06-$VER ;;
	*)   if [ -d "$ARG1" ]; then OUT=$ARG1/config.cs06-$VER; else OUT=$ARG1; fi ;;
esac

[ -f "$SRC" ] || { echo "missing base config: $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

# --- 1. 目标板切换（旧目标/旧设备停用 + 新目标启用） ------------------------
sed -i \
	-e 's|^CONFIG_TARGET_qualcommax=y$|# CONFIG_TARGET_qualcommax is not set|' \
	-e 's|^CONFIG_TARGET_qualcommax_ipq60xx=y$|# CONFIG_TARGET_qualcommax_ipq60xx is not set|' \
	-e 's|^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2=y$|# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2 is not set|' \
	-e "s|^CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-cs-02-gwrt2\"\$|CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-cs-06\"|" \
	-e "s|^CONFIG_VERSION_NUMBER=.*\$|CONFIG_VERSION_NUMBER=\"$VER\"|" \
	"$OUT"

cat >> "$OUT" <<EOF
CONFIG_TARGET_qualcommbe=y
CONFIG_TARGET_qualcommbe_ipq53xx=y
CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y
EOF

# --- 2. 剔除 CS-02 机型专属驱动（PACKAGE 与 DEFAULT 两条线都清） -----------
for p in \
	ipq-wifi-jdcloud_re-cs-02 \
	ath11k-firmware-ipq6018-ddwrt \
	ath11k-firmware-qcn9074-ddwrt \
	kmod-ath11k \
	kmod-ath11k-ahb \
	kmod-ath11k-pci \
; do
	sed -i "s|^CONFIG_PACKAGE_${p}=y\$|# CONFIG_PACKAGE_${p} is not set|" "$OUT"
	sed -i "s|^CONFIG_DEFAULT_${p}=y\$|# CONFIG_DEFAULT_${p} is not set|" "$OUT"
done

# --- 3. 清掉目标默认包的陈旧显式禁用 -------------------------------------
# CS-02 是 ath11k 机器，config 里存有 "# CONFIG_PACKAGE_kmod-ath12k is not set"
# 之类的显式 n —— 会压过 qualcommbe 目标 DEFAULT_PACKAGES 的
# "default y if DEFAULT_xxx"，导致 kmod-ath12k（IPQ5332 内置 WiFi）装不上。
# 对 qualcommbe/ipq53xx 目标默认包列表：存在陈旧 not-set 行则删除，
# 让 defconfig 的 default/select 机制自己收敛。
for p in \
	autocore automount cpufreq e2fsprogs f2fs-tools losetup luci \
	uboot-envtools wpad-openssl tc-tiny \
	kmod-ath12k kmod-dsa kmod-dsa-qca8k kmod-phy-aquantia kmod-phy-qca83xx \
	kmod-qcom-ppe kmod-qrtr-mhi kmod-qrtr-smd kmod-usb-serial-qualcomm \
	kmod-fs-ext4 kmod-fs-f2fs kmod-gpio-button-hotplug kmod-leds-gpio \
	kmod-usb3 kmod-usb-dwc3 kmod-usb-dwc3-qcom \
	ath12k-firmware-ipq5332-ddwrt ath12k-firmware-qcn9274-ddwrt \
	ipq-wifi-jdcloud_re-cs-06 \
; do
	sed -i "/^# CONFIG_PACKAGE_${p} is not set\$/d" "$OUT"
done

# --- 4. CS-06 必需开关（ath12k PPE-DS 直接引用 ab->debugfs_soc，
#        该成员在 #ifdef CPTCFG_ATH12K_DEBUGFS 内，必须开 MAC80211_DEBUGFS） ---
sed -i "s|^# CONFIG_PACKAGE_MAC80211_DEBUGFS is not set\$|CONFIG_PACKAGE_MAC80211_DEBUGFS=y|" "$OUT"
grep -q "^CONFIG_PACKAGE_MAC80211_DEBUGFS=y\$" "$OUT" || \
	echo "CONFIG_PACKAGE_MAC80211_DEBUGFS=y" >> "$OUT"

echo "==> generated: $OUT"
echo "    base: $(basename "$SRC")  VER: $VER"
echo "    下一步: cp $OUT .config && make defconfig 后复核"
echo "    CONFIG_TARGET_PROFILE 必须 = DEVICE_jdcloud_re-cs-06"
