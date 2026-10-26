#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cs07-config.sh — 由 ss-01 配置派生 JDCloud RE-CS-07 配置
#
# 用法：
#   sh gwrt-mk-cs07-config.sh            # 生成 config.cs07-261021-01 并跑 defconfig
#
# 派生规则（相对 config.ss01-261018-01）：
#   1. 目标板切到 DEVICE_jdcloud_re-cs-07
#   2. 去掉 ss-01 的整套 wifi 驱动（按 CS-07 的 DTS 判定）
#   3. 去掉 KixDNS
#   4. 版本号改成 261021-01
#   其余包（插件）原样继承
#
# 【为什么按 DTS 判定】
#   target/linux/qualcommax/dts/ipq6010-re-cs-07.dts
#     - 没有 &wifi 节点（ipq6018.dtsi 里 wifi@c000000 默认 status="disabled"）
#     - 没有 &pcie0 节点（无 PCIe 无线）
#     - 只有 &switch(swport1=wan, swport2..4=lan1..3) + &edma + USB3 + eMMC
#   ⇒ CS-07 本机没有任何射频，内核里不存在 wifi 平台设备。
#
#   树里 ipq60xx.mk 的 cs-07 设备定义已经用 '-' 语法把这三项从默认包里剔除：
#       DEVICE_PACKAGES := -ath11k-firmware-ipq6018 -kmod-ath11k-ahb -wpad-openssl
#   defconfig 之后 tmp/.config-target.in 里 cs-07 的 select 列表确实不再含
#   DEFAULT_ath11k-firmware-ipq6018 / DEFAULT_kmod-ath11k-ahb / DEFAULT_wpad-openssl
#   / DEFAULT_ipq-wifi-*，与 ss-01 的设备块形成对照。
#
#   注意 kmod-ath（ath9k/ath10k 公共部分）原先是被 kmod-ath11k 的
#   `DEPENDS += +kmod-ath` 拉进来的；它会 select kmod-mac80211，
#   进而把 hostapd-common / cfg80211 / wifi-scripts / wireless-regdb /
#   libiwinfo 全部带回来。所以 kmod-ath 必须一起去掉，否则 wifi 栈去不干净。
#
# 【KixDNS】
#   去掉 kixdns / luci-app-kixdns-lite / luci-i18n-kixdns-lite-zh-cn。
#   luci-app-kixdns-lite 是 +kixdns 硬依赖，defconfig 会自动级联去掉。
#   主题包里的 39_gwrt-wifi-firstboot 等脚本对 /etc/kixdns/pipeline.json
#   全部是 [ -f ] 判断，kixdns 不在也不会报错。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.ss01-261018-01}
OUT=${OUT:-$TOP/config.cs07-261021-01}
VER=${VER:-261021-01}

[ -f "$SRC" ] || { echo "missing source config: $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

# --- 1. 目标板 -------------------------------------------------------------
sed -i \
  -e 's|^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07 is not set$|CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07=y|' \
  -e 's|^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y$|# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01 is not set|' \
  -e 's|^CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-ss-01"$|CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-07"|' \
  "$OUT"

# --- 2. 去包 ---------------------------------------------------------------
unset_pkg() {
  sym=$1
  if grep -q "^CONFIG_PACKAGE_${sym}=y\$" "$OUT"; then
    sed -i "s|^CONFIG_PACKAGE_${sym}=y\$|# CONFIG_PACKAGE_${sym} is not set|" "$OUT"
    echo "  - $sym"
  fi
}

echo "[cs07] dropping wireless stack (CS-07 DTS has no &wifi / no &pcie0):"
for p in \
  ipq-wifi-jdcloud_re-ss-01 \
  ath11k-firmware-ipq6018-ddwrt \
  ath11k-firmware-ipq6018 \
  ath11k-firmware-qcn9074 \
  kmod-ath11k \
  kmod-ath11k-ahb \
  kmod-ath11k-pci \
  kmod-ath \
  kmod-cfg80211 \
  kmod-mac80211 \
  kmod-crypto-ccm \
  kmod-crypto-cmac \
  kmod-crypto-gcm \
  kmod-crypto-michael-mic \
  kmod-qrtr \
  kmod-qrtr-smd \
  kmod-qrtr-mhi \
  hostapd-common \
  wpad-openssl \
  libiwinfo \
  libiwinfo-data \
  rpcd-mod-iwinfo \
  wifi-scripts \
  wireless-regdb \
  MAC80211_DEBUGFS \
  MAC80211_MESH
do
  unset_pkg "$p"
done

echo "[cs07] dropping KixDNS:"
for p in kixdns luci-app-kixdns-lite luci-i18n-kixdns-lite-zh-cn; do
  unset_pkg "$p"
done

# --- 3. 版本号 -------------------------------------------------------------
sed -i "s|^CONFIG_VERSION_NUMBER=\"[0-9-]*\"\$|CONFIG_VERSION_NUMBER=\"$VER\"|" "$OUT"

# --- 4. 交给 kconfig 收敛（依赖级联 / DEFAULT_* 重算）---------------------
cp "$OUT" "$TOP/.config"
( cd "$TOP" && make defconfig )
cp "$TOP/.config" "$OUT"

# --- 5. 重复符号自检（.config 里同名符号出现两次 = 后者覆盖前者）-----------
sh "$TOP/gwrt-cfg-dupcheck.sh" "$OUT" || {
	echo "[cs07] FATAL: $OUT 有重复符号，见上方输出" >&2
	exit 1
}

echo "[cs07] OK -> $OUT"
