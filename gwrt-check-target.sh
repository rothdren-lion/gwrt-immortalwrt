#!/bin/sh
# gwrt-check-target.sh — 一个预设只允许一个 SoC 序列（board/subtarget/device）
# 用法: sh gwrt-check-target.sh [--pre] [.config] [preset] | --list
set -u

PRESETS='
# preset          series         board        subtarget  profile
ss01              ipq6000        qualcommax   ipq60xx    DEVICE_jdcloud_re-ss-01
cs02-gwrt2        ipq6000        qualcommax   ipq60xx    DEVICE_jdcloud_re-cs-02-gwrt2
cs07              ipq6000        qualcommax   ipq60xx    DEVICE_jdcloud_re-cs-07
cs06              ipq53xx        qualcommbe   ipq53xx    DEVICE_jdcloud_re-cs-06
cs08              ipq53xx        qualcommbe   ipq53xx    DEVICE_jdcloud_re-cs-08
pzl8              ipq5018        qualcommax   ipq50xx    DEVICE_cmcc_pz-l8
nezha             ipq5018        qualcommax   ipq50xx    DEVICE_jdcloud_ax3000
cp02              mt7621         ramips       mt7621    DEVICE_jdcloud_re-cp-02
mt7981            mt7981         mediatek     filogic    *
bdy-g98-direct    rk3588         rockchip     armv8      DEVICE_bdy_g98
bdy-g98-uefi      arm64-efi      armsr        armv8      DEVICE_generic
'

die() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

rows() { printf '%s\n' "$PRESETS" | awk '!/^[[:space:]]*#/ && NF >= 5'; }

PRE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--list)
		printf '%-16s %-12s %-12s %-10s %s\n' PRESET SERIES BOARD SUBTARGET PROFILE
		rows | awk '{ printf "%-16s %-12s %-12s %-10s %s\n", $1, $2, $3, $4, $5 }'
		exit 0
		;;
	--pre)
		PRE=1
		shift
		;;
	--help | -h)
		sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) break ;;
	esac
done

CFG=${1:-.config}
PRESET=${2:-}
[ -f "$CFG" ] || die "config not found: $CFG"

# --- 1. 唯一 board ---------------------------------------------------------
boards=$(grep -oE '^CONFIG_TARGET_[a-z0-9]+=y$' "$CFG" 2>/dev/null |
	sed 's/^CONFIG_TARGET_//; s/=y$//' | sort -u | tr '\n' ' ')
set -- $boards
nboards=$#
[ "$nboards" -gt 0 ] || die "$CFG 没有选中任何 board（.config 没被写入？defconfig 会回落到默认目标）"
[ "$nboards" -eq 1 ] || die "$CFG 同时选中 $nboards 个 board: $boards（一个预设只允许一个 SoC 序列）"
board=$1

# --- 2. 唯一 subtarget -----------------------------------------------------
subs=$(grep -oE "^CONFIG_TARGET_${board}_[a-z0-9]+=y\$" "$CFG" 2>/dev/null |
	sed "s/^CONFIG_TARGET_${board}_//; s/=y\$//" | sort -u | tr '\n' ' ')
set -- $subs
nsubs=$#
[ "$nsubs" -gt 0 ] || die "$CFG 选中了 board=$board 但没有 subtarget"
[ "$nsubs" -eq 1 ] || die "$CFG 同时选中 $nsubs 个 $board subtarget: $subs（一个预设只允许一个 SoC 序列）"
sub=$1

if [ "$PRE" -eq 0 ]; then
	cfg_board=$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"$/\1/p' "$CFG" | head -1)
	cfg_sub=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"$/\1/p' "$CFG" | head -1)
	[ -z "$cfg_board" ] || [ "$cfg_board" = "$board" ] ||
		die "CONFIG_TARGET_BOARD=\"$cfg_board\" 与实际选中的 board $board 不一致"
	[ -z "$cfg_sub" ] || [ "$cfg_sub" = "$sub" ] ||
		die "CONFIG_TARGET_SUBTARGET=\"$cfg_sub\" 与实际选中的 subtarget $sub 不一致"
fi

# --- 3. 设备归属 -----------------------------------------------------------
devs=$(grep -oE '^CONFIG_TARGET_(DEVICE_)?[a-z0-9]+_[a-z0-9]+_DEVICE_[A-Za-z0-9_.+-]+=y$' "$CFG" 2>/dev/null |
	sed -E 's/^CONFIG_TARGET_(DEVICE_)?//; s/=y$//' | sort -u)
ndevs=$(printf '%s\n' "$devs" | grep -c . || true)
[ "$ndevs" -gt 0 ] ||
	die "board=$board subtarget=$sub 一个 device 都没选中（multi-profile 列表过期？会落到默认设备）"
for d in $devs; do
	case "$d" in
	"${board}_${sub}_DEVICE_"*) ;;
	*) die "设备 '$d' 不属于 $board/$sub（跨 SoC 串台）" ;;
	esac
done

# --- 4. 设备符号真实存在 ---------------------------------------------------
if [ -f tmp/.config-target.in ]; then
	for d in $devs; do
		grep -qx "config TARGET_$d" tmp/.config-target.in ||
			grep -qx "menuconfig TARGET_$d" tmp/.config-target.in ||
			die "设备 '$d' 在 target metadata 里不存在（目录同步损坏 / 设备名过期）"
	done
fi

# --- 5. 预设 ↔ 序列 匹配 ---------------------------------------------------
series=$board
prof=$(sed -n 's/^CONFIG_TARGET_PROFILE="\(.*\)"$/\1/p' "$CFG" | head -1)
if [ -n "$PRESET" ]; then
	info=$(rows | awk -v p="$PRESET" '$1 == p { print $2, $3, $4, $5 }') ||
		die "未知预设 '$PRESET'（sh gwrt-check-target.sh --list）"
	[ -n "$info" ] || die "未知预设 '$PRESET'（sh gwrt-check-target.sh --list）"
	set -- $info
	series=$1
	[ "$board" = "$2" ] ||
		die "预设 $PRESET 属 $series 序列，应编 $2，实际编 $board（配置串台）"
	[ "$sub" = "$3" ] ||
		die "预设 $PRESET 应编 $2/$3，实际 $board/$sub"
	if [ "$4" != "*" ] && [ "$PRE" -eq 0 ]; then
		[ "$prof" = "$4" ] ||
			die "预设 $PRESET 应编 profile $4，实际 '${prof:-<空>}'"
	fi
fi

printf 'ok: preset=%s series=%s board=%s subtarget=%s profile=%s devices=%s\n' \
	"${PRESET:-<none>}" "$series" "$board" "$sub" "${prof:-<multi>}" "$ndevs"
