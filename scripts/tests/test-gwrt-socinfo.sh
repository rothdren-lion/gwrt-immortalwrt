#!/bin/sh
set -eu

top=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
helper="$top/gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-socinfo"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

printf 'processor : 0\nprocessor : 1\n' > "$tmp/cpuinfo"
printf '1300000\n' > "$tmp/frequency"
: > "$tmp/machine"

check_soc() {
	expected=$1
	shift
	compatible=$*
	printf '%s\0' "$@" > "$tmp/compatible"
	actual=$(GWRT_SOCINFO_COMPATIBLE_FILE="$tmp/compatible" \
		GWRT_SOCINFO_MACHINE_FILE="$tmp/machine" \
		GWRT_SOCINFO_CPUINFO_FILE="$tmp/cpuinfo" \
		GWRT_SOCINFO_FREQ_FILE="$tmp/frequency" sh "$helper")
	want=$(printf '%s\n2\n1300000' "$expected")
	[ "$actual" = "$want" ] || {
		echo "unexpected SoC info for $compatible: $actual" >&2
		exit 1
	}
}

check_soc ipq5332 jdcloud,re-cs-06 qcom,ipq5332
check_soc mt7981 mediatek,mt7981
check_soc en7581 nokia,xg-040g-md airoha,an7581 airoha,en7581
printf 'IPQ6010\n' > "$tmp/machine"
check_soc ipq6010 jdcloud,re-ss-01 qcom,ipq6018
if command -v busybox >/dev/null 2>&1; then
	mkdir "$tmp/bin"
	ln -s "$(command -v busybox)" "$tmp/bin/tr"
	PATH="$tmp/bin:$PATH" check_soc ipq6010 jdcloud,re-ss-01 qcom,ipq6018
fi
printf 'JDCloud RE-SS-01\n' > "$tmp/machine"
check_soc ipq6018 jdcloud,re-ss-01 qcom,ipq6018
echo 'PASS: SoC identifiers and CPU thread counts'
