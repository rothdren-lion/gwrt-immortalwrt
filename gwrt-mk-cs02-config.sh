#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cs02-config.sh — 派生 JDCloud RE-CS-02 / CS-02-GWRT2 配置
#
# 用法：
#   sh gwrt-mk-cs02-config.sh              # 生成 config.cs02-gwrt2-261021-01
#   SRC=... OUT=... sh gwrt-mk-cs02-config.sh
#
# 【CS-02 相对 SS-01 的三个独特驱动】
#
#  1) 集成 2.4G/5G 射频（AHB 总线）
#     - ath11k-firmware-ipq6018-ddwrt   固件（DD-WRT 构建，树里已有）
#     - kmod-ath11k-ahb                 AHB 总线驱动
#     - ipq-wifi-jdcloud_re-cs-02       board-2.bin（.ipq6018 那份）
#
#  2) PCIe QCN9074 5.2G 射频（PCIe 总线）—— CS-02 独有
#     - ath11k-firmware-qcn9074-ddwrt   固件（树里原本没有，本次新增）
#     - kmod-ath11k-pci                PCIe 总线驱动
#     - ipq-wifi-jdcloud_re-cs-02       board-2.bin（.qcn9074 那份，同一个包）
#
#  3) LED 点阵屏（JDCloud AX6600 "Athena"）—— CS-02 独有
#     - athena-led                      Rust 守护进程（驱动 TM1628A 点阵屏）
#     - luci-app-athena-led             LuCI 界面
#     屏幕用 GPIO 69/70/73/74（STB_L/STB_R/CLK/DIO），
#     按键用 GPIO 71（CS-02 DTS 里的 "screen" 按键就是 gpio71）。
#
# 【为什么用 ddwrt 固件而不是上游固件】
#   上游 ath11k-firmware-ipq6018 / -qcn9074 在 CS-02 上 radio 全死
#   （见 BUILD-NOTES "cs-02-gwrt2 配置用标准 ath11k 固件 → radio 全死"），
#   所以 DEVICE_PACKAGES 里用 '-' 剔掉上游固件、换成 ddwrt 那份。
#
# 【不选 athena-led 的机型】
#   CS-07 的 DTS 没有 screen 按键、没有 &pcie、也没有 &wifi —— 它压根没有
#   射频和点阵屏，所以 CS-07 的配置里不能带这三个包。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.ss01-261018-01}
OUT=${OUT:-$TOP/config.cs02-gwrt2-261021-01}
PROFILE=${PROFILE:-DEVICE_jdcloud_re-cs-02-gwrt2}
VER=${VER:-261021-01}

[ -f "$SRC" ] || { echo "missing source config: $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

# --- 1. 目标板 -------------------------------------------------------------
# DEVICE_jdcloud_re-cs-02-gwrt2 的 Kconfig 块在 tmp/.config-target.in 里
# 会 select 下面这些 DEFAULT_*，配置层只需把名字对上。
sed -i \
  -e 's|^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2 is not set$|CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2=y|' \
  -e 's|^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01 is not set$|CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y|' \
  -e "s|^CONFIG_TARGET_PROFILE=\"DEVICE_jdcloud_re-ss-01\"$|CONFIG_TARGET_PROFILE=\"$PROFILE\"|" \
  "$OUT"

# --- 2. 去包 ---------------------------------------------------------------
unset_pkg() {
  sym=$1
  if grep -q "^CONFIG_PACKAGE_${sym}=y\$" "$OUT"; then
    sed -i "s|^CONFIG_PACKAGE_${sym}=y\$|# CONFIG_PACKAGE_${sym} is not set|" "$OUT"
    echo "  - $sym"
  fi
}

echo "[cs02] dropping SS-01-only wireless stack:"
for p in \
  ipq-wifi-jdcloud_re-ss-01 \
  ath11k-firmware-ipq6018-ddwrt \
  kmod-ath11k \
  kmod-ath11k-ahb \
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

echo "[cs02] dropping upstream ath11k firmware (radio 全死, 改用 ddwrt):"
for p in ath11k-firmware-ipq6018 ath11k-firmware-qcn9074; do
  unset_pkg "$p"
done

echo "[cs02] dropping KixDNS:"
for p in kixdns luci-app-kixdns-lite luci-i18n-kixdns-lite-zh-cn; do
  unset_pkg "$p"
done

# --- 3. 加上 CS-02 独有的驱动 ---------------------------------------------
# 固件 / 驱动 / 界面包在 defconfig 后会由 DEVICE_PACKAGES 与 Kconfig 依赖
# 自动选上；这里显式写出，确保即使设备定义变了配置也不会丢。
# 注意是**原地替换**而不是追加 —— 追加会在文件末尾产生重复符号
# （.config 里同名符号出现两次时，最后一条生效，前面的就成了垃圾）。
set_pkg() {
  sym=$1
  if grep -q "^CONFIG_PACKAGE_${sym}=y\$" "$OUT"; then
    return
  fi
  if grep -q "^# CONFIG_PACKAGE_${sym} is not set\$" "$OUT"; then
    sed -i "s|^# CONFIG_PACKAGE_${sym} is not set\$|CONFIG_PACKAGE_${sym}=y|" "$OUT"
  else
    echo "CONFIG_PACKAGE_${sym}=y" >> "$OUT"
  fi
  echo "  + $sym"
}

echo "[cs02] adding CS-02 unique drivers:"
for p in \
  ath11k-firmware-ipq6018-ddwrt \
  ath11k-firmware-qcn9074-ddwrt \
  ipq-wifi-jdcloud_re-cs-02 \
  kmod-ath11k \
  kmod-ath11k-ahb \
  kmod-ath11k-pci \
  athena-led \
  luci-app-athena-led \
  wpad-openssl
do
  set_pkg "$p"
done

# --- 4. 版本号 -------------------------------------------------------------
sed -i "s|^CONFIG_VERSION_NUMBER=\"[0-9-]*\"\$|CONFIG_VERSION_NUMBER=\"$VER\"|" "$OUT"

# --- 5. 交给 kconfig 收敛 --------------------------------------------------
cp "$OUT" "$TOP/.config"
( cd "$TOP" && make defconfig )
cp "$TOP/.config" "$OUT"

# --- 6. 重复符号自检 -------------------------------------------------------
sh "$TOP/gwrt-cfg-dupcheck.sh" "$OUT" || {
	echo "[cs02] FATAL: $OUT 有重复符号，见上方输出" >&2
	exit 1
}

echo "[cs02] OK -> $OUT"
