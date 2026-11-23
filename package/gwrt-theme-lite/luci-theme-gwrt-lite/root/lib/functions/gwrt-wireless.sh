#!/bin/sh
# Shared naming helpers for GWRT SSID defaults. Radio indices are not stable.
#
# 2026-09-20：频段策略层（channel/htmode/ieee80211ax/he_twt_responder/country 强制、
# HE 取向开关 gwrt.he.*、开放网络 psk2 兜底、gwrt_profile 标记、每轮幂等校正）
# 已按用户要求整体移除 —— 无线一律走 OpenWrt 默认，不再做任何策略改写。
# 本文件现在只保留 SSID 命名相关 helper，供 35_gwrt-ssid-mac 使用。
. /lib/functions/system.sh

gwrt_wifi_role() {
	# $3 = 可选信道（5G 用来区分 5.2G / 5.8G）
	case "$1:$2" in
		*/c000000.wifi+1:2g) echo 2.4G ;;
		*/c000000.wifi:5g) echo 5.8G ;;
		*pci*0000:01:00.0:5g) echo 5.2G ;;
		# MediaTek MT7981/MT7986/MT7988 (filogic)：platform/soc/18000000.wifi[+1]
		*18000000.wifi+1:2g|*18000000.wifi:2g) echo 2.4G ;;
		*18000000.wifi+1:5g|*18000000.wifi:5g)
			if [ -n "$3" ] && [ "$3" -ge 149 ] 2>/dev/null; then echo 5.8G; else echo 5.2G; fi ;;
		*) return 1 ;;
	esac
}

gwrt_wifi_is_default_ssid() {
	case "$1" in
		# 2026-09-21：加入 ImmortalWrt —— mac80211.uc 的兜底 SSID 已还原为上游原值
		# `defaults?.ssid || "ImmortalWrt"`，若不在本清单里，首启默认 SSID 就永远不会被
		# /etc/hotplug.d/ieee80211/30-gwrt-ssid-name 改成 GWRT_<频段>_<MAC后4>。
		""|GWRT|OpenWrt|LiBwrt|ImmortalWrt) return 0 ;;
		GWRT_2.4G_*|GWRT_5.2G_*|GWRT_5.8G_*|GWRT_5G+_*|GWRT_6G_*|GWRT_60G_*|GWRT_W_*)
			case "${1##*_}" in
				[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
					# 只有后缀等于本机 MAC 后 4 位才算“默认名”。
					# 别的后缀是主AP 通过 mesh 下发的同名 SSID，不能改回本机后缀。
					[ -n "$2" ] && [ "$(printf '%s' "${1##*_}" | tr 'a-f' 'A-F')" = "$(printf '%s' "$2" | tr 'a-f' 'A-F')" ] && return 0
					return 1 ;;
			esac ;;
	esac
	return 1
}
