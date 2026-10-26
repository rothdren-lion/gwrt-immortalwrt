#!/bin/sh
# Unit checks for the Route Tool swap / partition helpers.
# Runs on any Linux host with busybox ash (no router needed).
#   sh tests/check-swap-helpers.sh [path-to-files/usr/libexec]
#
# Copyright (c) 2026 数码罗记 · godsun.pro

BASE="${1:-$(dirname "$0")/../files/usr/libexec}"
RT_DIR="$(cd "$BASE" 2>/dev/null && pwd)"
if [ -z "$RT_DIR" ] || [ ! -d "$RT_DIR/route-tool.d" ]; then
	echo "ERROR: cannot find the route-tool scripts (looked in '$BASE')" >&2
	exit 1
fi

ASHD=""
for c in busybox; do
	command -v "$c" >/dev/null 2>&1 && { ASHD="$c ash"; break; }
done
[ -n "$ASHD" ] || ASHD="sh"

# load the helpers under test
. "$RT_DIR/route-tool.d/storage_partition.sh"
. "$RT_DIR/route-tool.d/storage_swap.sh"

fail=0
check(){
	got="$1"; want="$2"; name="$3"
	if [ "$got" = "$want" ]; then
		printf '  ok   %-42s = %s\n' "$name" "$got"
	else
		printf '  FAIL %-42s = %s (want %s)\n' "$name" "$got" "$want"
		fail=$(( fail + 1 ))
	fi
}

echo "== GPT type codes =="
check "$(rt_type_code 0657FD6D-A4AB-43C4-84E5-0933C84B4F4F)" 8200 "Linux swap GUID"
check "$(rt_type_code 0FC63DAF-8483-4772-8E79-3D69D8477DE4)" 8300 "Linux filesystem GUID"
check "$(rt_type_code 8200)" 8200 "raw type code"
check "$(rt_type_code 0x8200)" 8200 "0x prefixed type code"
check "$(rt_type_code something-else)" "" "unknown type"

echo "== partition names =="
check "$(rt_clean_name '0:rootfs')" "rootfs" "strip the numeric prefix"
check "$(rt_clean_name 'swap')" "swap" "plain name stays"

echo "== alignment =="
check "$(rt_align_up 1)" 2048 "1 -> 1MB boundary"
check "$(rt_align_up 2048)" 2048 "already aligned"
check "$(rt_align_up 2049)" 4096 "next boundary"

echo "== swap size suggestion (by RAM) =="
check "$(rt_swap_suggest_mb 128)" 512 "128MB RAM"
check "$(rt_swap_suggest_mb 512)" 512 "512MB RAM"
check "$(rt_swap_suggest_mb 768)" 768 "768MB RAM"
check "$(rt_swap_suggest_mb 1024)" 1024 "1GB RAM"
check "$(rt_swap_suggest_mb 2048)" 0 "2GB RAM -> recommend off"
check "$(rt_swap_suggest_mb 0)" 0 "unknown RAM"

echo "== requested capacity =="
check "$(rt_swap_resolve_size auto 0 512)" 512 "auto follows the suggestion"
check "$(rt_swap_resolve_size min 0 512)" 64 "minimum"
check "$(rt_swap_resolve_size custom 256 512)" 256 "custom"

echo "== lsblk pair parsing =="
line='NAME="mmcblk0p26" PARTLABEL="swap" PARTTYPE="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" PARTTYPENAME="Linux swap"'
check "$(rt_lsblk_val "$line" NAME)" "mmcblk0p26" "NAME"
check "$(rt_lsblk_val "$line" PARTLABEL)" "swap" "PARTLABEL"
check "$(rt_lsblk_val "$line" PARTTYPE)" "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" "PARTTYPE"
check "$(rt_lsblk_val "$line" PARTTYPENAME)" "Linux swap" "PARTTYPENAME (with space)"
check "$(rt_lsblk_val "$line" PARTLABELX)" "" "unknown key"

echo "== swap partition state =="
tmp="/tmp/route-tool-swap-test-$$.img"
rm -f "$tmp"
dd if=/dev/zero of="$tmp" bs=1M count=4 2>/dev/null
check "$(rt_swap_state "$tmp")" "blank" "zeroed partition"
if command -v mkswap >/dev/null 2>&1; then
	mkswap "$tmp" >/dev/null 2>&1
	check "$(rt_swap_state "$tmp")" "swap" "after mkswap"
fi
rm -f "$tmp"

echo "== /etc/config/fstab section parsing =="
fake='fstab.@swap[0]=swap
fstab.@swap[0].device=/dev/mmcblk0p26
fstab.rttool_swap=swap
fstab.rttool_swap.device=/dev/mmcblk0p9
fstab.@mount[0]=mount
fstab.rttool_storage=mount'
check "$(printf '%s\n' "$fake" | sed -n "s/^fstab\.\(@swap\[[0-9]*\]\|[^.=]*\)=swap$/\1/p" | tr '\n' ' ')" "@swap[0] rttool_swap " "swap sections"
check "$(printf '%s\n' "$fake" | sed -n "s/^fstab\.\(@mount\[[0-9]*\]\|[^.=]*\)=mount$/\1/p" | tr '\n' ' ')" "@mount[0] rttool_storage " "mount sections"

echo
if [ "$fail" -gt 0 ]; then
	printf '%d check(s) FAILED\n' "$fail"
	exit 1
fi
printf 'all checks passed\n'
