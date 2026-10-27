#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-pzl8-config.sh — 生成 IPQ5018 (CMCC PZ-L8 / 移动PL08 AX3000) 配置
#
# 用法：
#   VER=261027-01 sh gwrt-mk-pzl8-config.sh
#
# 硬件：IPQ5018 (2x Cortex-A53 aarch64) + QCN6122 5G，128M NAND (59392k 预算)
#       树内已有 cmcc_pz-l8 设备定义（leds/network/platform.sh 齐全）
#
# 定位：GWRT mesh 子 AP。主要集成 easytier + gwrt-agent + mesh 最低集。
#       128M NAND 空间充足，easytier 核心（~15M）直接进镜像。
#       WiFi 固件必须选 ath11k-firmware-ipq5018-qcn6122（设备定义未自带）。
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/config.pzl8-$VER}

cat > "$OUT" <<EOF
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_cmcc_pz-l8=y
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
CONFIG_PACKAGE_ath11k-firmware-ipq5018-qcn6122=y
CONFIG_PACKAGE_gwrt-agent=y
CONFIG_PACKAGE_gwrt-device-defaults=y
CONFIG_PACKAGE_gwrt-mesh-apmode=y
CONFIG_PACKAGE_ucode-mod-socket=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_easytier=y
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-i18n-easytier-zh-cn=y
EOF

echo "==> 输出: $OUT"
echo "==> 构建树使用: cp $OUT <build-tree>/.config && make defconfig"
