#!/bin/sh
# GWRT 回归：AN758x NPU 状态数据链路
#  - gwrt-accelinfo（双副本）必须含 Airoha NPU 探测路径，双副本 SHA 一致，
#    且在无这些节点的主机上输出合法 JSON
#  - luci-app-airoha-npu rpcd 后端 list/getStatus 输出合法 JSON，并带
#    per-SoC 固件回退（纯 ONT 板无 firmware-name 时版本不再显示 Unknown）
#  - an7581 配置必须固化 /dev/mem + busybox devmem（Frame Engine / PLL 数据源）

set -eu

top=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }

theme_v3="$top/gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-accelinfo"
theme_pkg="$top/package/gwrt-theme/luci-theme-gwrt/root/usr/libexec/gwrt-accelinfo"
rpcd="$top/package/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu"
mkcfg="$top/gwrt-mk-an7581-config.sh"
seedcfg="$top/config.an7581-261022-01"

for f in "$theme_v3" "$theme_pkg" "$rpcd" "$mkcfg" "$seedcfg"; do
	[ -f "$f" ] || fail "missing $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

json_ok() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null
	else
		cat >/dev/null
	fi
}

# 1. accelinfo：双副本一致，且含 Airoha NPU 探测路径
sum_v3=$(sha256sum "$theme_v3" | awk '{print $1}')
sum_pkg=$(sha256sum "$theme_pkg" | awk '{print $1}')
[ "$sum_v3" = "$sum_pkg" ] || fail "accelinfo two copies differ"
grep -q '/sys/module/airoha_npu' "$theme_v3" || fail "accelinfo missing /sys/module/airoha_npu"
grep -q '/sys/bus/platform/drivers/airoha-npu/\*.npu' "$theme_v3" || fail "accelinfo missing bound-device probe"
grep -q '/sys/devices/platform/soc/\*npu\*' "$theme_v3" || fail "accelinfo missing soc-bus probe"
grep -q '/sys/devices/platform/soc@0/\*npu\*' "$theme_v3" || fail "accelinfo missing soc@0-bus probe"

# 2. accelinfo：主机上输出合法 JSON
accel_out=$(sh "$theme_v3")
printf '%s\n' "$accel_out" | json_ok || fail "accelinfo output is not valid JSON: $accel_out"
if printf '%s\n' "$accel_out" | grep -q '"npu":true'; then
	echo "INFO: host exposes an acceleration node; skipping all-false expectation"
fi

# 3. rpcd 后端：去掉 OpenWrt 专属 . /lib/functions.sh 后可在主机直跑
sed 's|^\. /lib/functions.sh$|:|' "$rpcd" > "$tmp/luci.airoha_npu"
list_out=$(sh "$tmp/luci.airoha_npu" list)
printf '%s\n' "$list_out" | json_ok || fail "rpcd list is not valid JSON"
for m in getStatus getPpeEntries getTokenInfo getFrameEngine setOverclock; do
	printf '%s\n' "$list_out" | grep -q "\"$m\"" || fail "rpcd list missing $m"
done

# 设备树 / dmesg 在构建主机上不可用属预期，静音 stderr 后只校验 stdout 的 JSON。
status_out=$(sh "$tmp/luci.airoha_npu" call getStatus 2>/dev/null) || \
	fail "rpcd getStatus exited nonzero"
printf '%s\n' "$status_out" | json_ok || fail "rpcd getStatus is not valid JSON: $status_out"
printf '%s\n' "$status_out" | grep -q '"npu_version"' || fail "getStatus missing npu_version"
grep -q 'airoha/en7581_npu_rv32.bin' "$rpcd" || fail "rpcd missing en7581 firmware fallback"
grep -q 'airoha/an7583_npu_rv32.bin' "$rpcd" || fail "rpcd missing an7583 firmware fallback"

# 4. devmem 数据源已固化（mk 脚本 + 种子 config）
grep -q '^CONFIG_KERNEL_DEVMEM=y$' "$seedcfg" || fail "seed config missing CONFIG_KERNEL_DEVMEM=y"
grep -q '^CONFIG_BUSYBOX_DEFAULT_DEVMEM=y$' "$seedcfg" || fail "seed config missing CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
grep -q 'CONFIG_KERNEL_DEVMEM=y' "$mkcfg" || fail "mk-config script missing devmem fixup"
grep -q 'CONFIG_BUSYBOX_DEFAULT_DEVMEM=y' "$mkcfg" || fail "mk-config script missing busybox devmem fixup"

# 5. bandix-plus 已加入固件（流量监控取样唯一源），且不再出现在 unset 清单
grep -q '^	luci-i18n-bandix-plus-zh-cn \\$' "$mkcfg" || fail "mk-config missing bandix i18n in add list"
[ "$(grep -c '^	luci-app-bandix-plus \\$' "$mkcfg")" = "1" ] || fail "luci-app-bandix-plus must appear exactly once (add list)"
[ "$(grep -c '^	bandix-plus \\$' "$mkcfg")" = "1" ] || fail "bandix-plus must appear exactly once (add list)"
grep -q '^CONFIG_PACKAGE_luci-app-bandix-plus=y$' "$seedcfg" || fail "seed config missing luci-app-bandix-plus=y"
grep -q '^CONFIG_PACKAGE_bandix-plus=y$' "$seedcfg" || fail "seed config missing bandix-plus=y"

echo 'PASS: AN758x NPU status data chain (accelinfo + rpcd + devmem + bandix)'
