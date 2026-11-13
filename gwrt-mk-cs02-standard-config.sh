#!/bin/sh
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${OUT:-$top/config.cs02-${VER:-261107-02}}
src=${SRC:-$top/config.ci-cs02-gwrt2-261030-01}
[ "$src" != "$out" ] || { echo 'source and output must differ' >&2; exit 1; }
cp "$src" "$out"
sed -i \
	-e 's/^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2=y$/# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02-gwrt2 is not set/' \
	-e 's/^# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02 is not set$/CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y/' \
	-e 's/^CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-02-gwrt2"$/CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-02"/' \
	"$out"
grep -qx 'CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y' "$out" || {
	echo 'standard CS-02 profile missing from seed' >&2; exit 1;
}

# GWRT 广告拦截（电视 + 国内通用, 纯文本规则库）: CI seed 未含时显式补上
for p in gwrt-tv-adblock luci-app-gwrt-tvadblock; do
	grep -q "^CONFIG_PACKAGE_${p}=y$" "$out" && continue
	sed -i "/^# CONFIG_PACKAGE_${p} is not set$/d" "$out"
	echo "CONFIG_PACKAGE_${p}=y" >> "$out"
done
echo "generated standard CS-02: $out"
