#!/bin/sh
# 回归：RE-CS-02 / GWRT2 的 QCN9074（5.2G）必须能拿到 PCI 校准数据。
#
# 2026-11-27 真机日志：ath11k_pci 0000:01:00.0 枚举正常、固件加载成功，但
#   qmi failed to load CAL data file: cal-pci-0000:01:00.0.bin
#   failed to load board data file: -12
# radio2 因此永远不出现。根因是 hotplug 只匹配 jdcloud,re-cs-02，
# 而 GWRT2 的 board_name 是 jdcloud,re-cs-02-gwrt2，且 gwrt-caldata 只补 AHB。
set -eu

root=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
hotplug="$root/target/linux/qualcommax/ipq60xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata"
init="$root/target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

for f in "$hotplug" "$init"; do
	[ -f "$f" ] || fail "missing $f"
done

# --- hotplug：AHB 与 PCI 两种 firmware 都要覆盖 GWRT2
ahb_block=$(awk '/ath11k\/IPQ6018\/hw1.0\/cal-ahb-c000000.wifi.bin/{f=1} /ath11k\/QCN9074\/hw1.0\/cal-pci/{f=0} f' "$hotplug")
printf '%s\n' "$ahb_block" | grep -q 'jdcloud,re-cs-02-gwrt2[|)]' ||
	fail "AHB caldata hotplug does not match jdcloud,re-cs-02-gwrt2"

pci_block=$(awk '/ath11k\/QCN9074\/hw1.0\/cal-pci-0000:01:00.0.bin/{f=1} f' "$hotplug")
printf '%s\n' "$pci_block" | grep -q 'jdcloud,re-cs-02-gwrt2[|)]' ||
	fail "PCI caldata hotplug does not match jdcloud,re-cs-02-gwrt2"
printf '%s\n' "$pci_block" | grep -q 'caldata_extract_mmc "0:ART" 0x26800 0x20000' ||
	fail "PCI caldata must come from 0:ART 0x26800 0x20000"

# --- init：必须单独补 PCI cal，且偏移/长度与 ART 布局一致
grep -q '^CAL_PCI=/lib/firmware/ath11k/QCN9074/hw1.0/cal-pci-0000:01:00.0.bin$' "$init" ||
	fail "gwrt-caldata has no QCN9074 cal path"

off=$(sed -n 's/^ART_PCI_OFFSET=//p' "$init")
len=$(sed -n 's/^ART_PCI_LEN=//p' "$init")
[ "${off:-0}" = "157696" ] || fail "ART_PCI_OFFSET must be 157696 (0x26800), got '${off:-}'"
[ "${len:-0}" = "131072" ] || fail "ART_PCI_LEN must be 131072 (0x20000), got '${len:-}'"

pci_radio=$(awk '/^has_pci_radio\(\)/,/^}$/' "$init")
printf '%s\n' "$pci_radio" | grep -q 'jdcloud,re-cs-02-gwrt2' ||
	fail "has_pci_radio() must cover jdcloud,re-cs-02-gwrt2"
printf '%s\n' "$pci_radio" | grep -q 'jdcloud,re-cs-02[|)]' ||
	fail "has_pci_radio() must cover jdcloud,re-cs-02"

start_fn=$(awk '/^start\(\)/,/^}$/' "$init")
printf '%s\n' "$start_fn" | grep -q 'cal_ensure "\$CAL_PCI"' ||
	fail "start() must extract the PCI caldata when missing"

sh -n "$init" || fail "gwrt-caldata has a syntax error"

printf 'PASS: QCN9074 caldata covered for RE-CS-02 and GWRT2\n'
