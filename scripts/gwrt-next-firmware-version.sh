#!/bin/sh
# GWRT 固件版本号生成器（与 IPQ/qualcommax 侧命名统一）
#
# 版本格式：GWRT YYMMDD-NN
#   YYMMDD = 编译日期
#   NN     = 当天第几次编译（01、02 ...，跨天自动回到 01）
#
# 版本号同时写入两处：
#   1. .config 的 CONFIG_VERSION_NUMBER，让 /etc/openwrt_release、
#      /etc/os-release、SSH banner 和镜像文件名都变成 GWRT 版本；
#   2. 主题包里的 /usr/share/gwrt/firmware-version，供仪表盘/页脚读取。
#
# 用法：
#   scripts/gwrt-next-firmware-version.sh              # 递增一次
#   scripts/gwrt-next-firmware-version.sh --show       # 只显示当前版本
#   scripts/gwrt-next-firmware-version.sh --set 261025-01
#   scripts/gwrt-next-firmware-version.sh --tree DIR   # 指定编译树
#
# 正常编译不需要手动调用：gwrt-theme-V3/scripts/build-with-theme.sh
# 会在 make 之前自动调用一次。
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tree="$root"
mode="bump"
explicit=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tree)
			[ "$#" -ge 2 ] || { echo "--tree requires a directory" >&2; exit 2; }
			tree=$(CDPATH= cd -- "$2" && pwd)
			shift 2
			;;
		--show)
			mode="show"
			shift
			;;
		--set)
			[ "$#" -ge 2 ] || { echo "--set requires a version like 261025-01" >&2; exit 2; }
			explicit="$2"
			mode="set"
			shift 2
			;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "unknown argument: $1" >&2
			exit 2
			;;
	esac
done

config="$tree/.config"
[ -f "$config" ] || { echo "missing $config; select a hardware profile first" >&2; exit 1; }

current=$(sed -n 's/^CONFIG_VERSION_NUMBER="\([^"]*\)"$/\1/p' "$config" | sed -n '1p')

case "$mode" in
	show)
		[ -n "$current" ] || current="(unset)"
		printf 'GWRT %s\n' "${current#GWRT }"
		exit 0
		;;
	set)
		ver="${explicit#GWRT }"
		case "$ver" in
			[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9]) ;;
			*) echo "invalid version: $explicit (want YYMMDD-NN)" >&2; exit 2 ;;
		esac
		;;
	bump)
		today=$(date +%y%m%d)
		old_date=""
		old_seq=0
		if [ -n "$current" ]; then
			old_date=${current%%-*}
			old_seq=${current##*-}
			case "$old_seq" in ''|*[!0-9]*) old_seq=0 ;; esac
		fi
		if [ "$old_date" = "$today" ]; then
			seq=$((old_seq + 1))
		else
			seq=1
		fi
		[ "$seq" -lt 1 ] && seq=1
		[ "$seq" -gt 99 ] && seq=99
		ver=$(printf '%s-%02d' "$today" "$seq")
		;;
esac

# --- 1. 编译配置 -----------------------------------------------------------
set_opt()
{
	key="$1"
	line="$2"
	if grep -q "^${key}=" "$config"; then
		sed -i "s|^${key}=.*$|${line}|" "$config"
	elif grep -q "^# ${key} is not set$" "$config"; then
		sed -i "s|^# ${key} is not set$|${line}|" "$config"
	else
		printf '%s\n' "$line" >> "$config"
	fi
}

set_opt CONFIG_VERSIONOPT "CONFIG_VERSIONOPT=y"
set_opt CONFIG_VERSION_DIST 'CONFIG_VERSION_DIST="GWRT"'
set_opt CONFIG_VERSION_NUMBER "CONFIG_VERSION_NUMBER=\"$ver\""

# --- 2. 主题包里的版本文件 --------------------------------------------------
canonical="$root/gwrt-theme-V3/theme/luci-theme-gwrt"
rel="$root/package/gwrt-theme/luci-theme-gwrt"
files="$canonical/root/usr/share/gwrt/firmware-version \
	$rel/root/usr/share/gwrt/firmware-version \
	$rel/luci-theme-gwrt/root/usr/share/gwrt/firmware-version"

for f in $files; do
	mkdir -p "$(dirname "$f")"
	printf 'GWRT %s\n' "$ver" > "$f"
done

printf 'GWRT %s\n' "$ver"
