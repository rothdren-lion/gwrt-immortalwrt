#!/bin/sh
# gwrt-ipv6-auto.sh — 自动判断本机是网关还是二级路由，并设置 IPv6 模式
#
# 用法:
#   gwrt-ipv6-auto.sh            # check（默认）：只检测并打印结果，不修改配置
#   gwrt-ipv6-auto.sh apply      # 按检测结果应用 IPv6 模式
#                               #   网关（直连 ISP / PPPoE）→ Prefix Delegation（PD）
#                               #   二级（WAN 接上级路由器）→ Relay（中继）
#
# 判断依据:
#   1. WAN 协议为 pppoe           → 网关（拨号直连运营商）
#   2. WAN IPv4 为公网地址        → 网关（直接接入互联网）
#   3. 默认网关为私网地址         → 二级（上级是路由器）
#   4. 其余情况                   → 无法判断，保持现状
#
# 注意: 不调用 luci-ipv6-mode（其内部 ifup lan 会让绑定 lan 的 dropbear 掉线），
#       改为直接写 uci + 后台重启 wan6/odhcpd。

ACTION="${1:-check}"
FORCE="${2:-}"  # 可选：apply gateway / apply secondary（强制指定，跳过自动判断）

wan_proto="$(uci -q get network.wan.proto)"
wan_dev="$(uci -q get network.wan.device)"

# 实际承载 WAN 的接口（PPPoE 拨号后是 pppoe-wan）
case "$wan_proto" in
	pppoe) real_if="pppoe-wan" ;;
	*) real_if="$wan_dev" ;;
esac

wan_ip="$(ip -4 addr show dev "$real_if" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
gw_ip="$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')"

is_private() {
	case "$1" in
		10.*|192.168.*) return 0 ;;
		172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
		*) return 1 ;;
	esac
}

MODE=""
REASON=""
if [ "$wan_proto" = "pppoe" ]; then
	MODE="gateway"
	REASON="WAN 为 PPPoE 拨号（直连运营商）"
elif [ -n "$wan_ip" ] && ! is_private "$wan_ip"; then
	MODE="gateway"
	REASON="WAN IPv4 为公网地址（$wan_ip）"
elif [ -n "$gw_ip" ] && is_private "$gw_ip"; then
	MODE="secondary"
	REASON="默认网关为私网地址 $gw_ip（上级是路由器）"
else
	MODE="unknown"
	REASON="无法判断（wan_proto=$wan_proto wan_ip=${wan_ip:-无} gw=${gw_ip:-无}）"
fi

case "$MODE" in
	gateway)   V6MODE="网关（Prefix Delegation）" ;;
	secondary) V6MODE="中继（Relay）" ;;
	*)         V6MODE="保持现状" ;;
esac

echo "=== GWRT IPv6 模式自动检测 ==="
echo "WAN 协议 : $wan_proto"
echo "WAN 接口 : $real_if"
echo "WAN IPv4 : ${wan_ip:-无}"
echo "默认网关 : ${gw_ip:-无}"
echo "判断结果 : $MODE（$REASON）"
echo "IPv6 模式: $V6MODE"

# ─── apply：直接写 uci（等效 luci-ipv6-mode），跳过 ifup lan ───
# 确保 dhcp 段存在且带 interface（全新设备首次运行时缺 interface 会导致 odhcpd 不识别）
ensure_dhcp_section() {
	local name="$1"
	local iface="$2"
	uci -q get "dhcp.${name}" >/dev/null || uci set "dhcp.${name}=dhcp"
	uci set "dhcp.${name}.interface=${iface}"
}

apply_mode() {
	local mode="$1"

	ensure_dhcp_section lan lan
	ensure_dhcp_section wan6 wan6
	uci set dhcp.lan.force=1
	uci set dhcp.lan.ra_default=1
	uci -q delete dhcp.lan.ra_flags
	uci add_list dhcp.lan.ra_flags=none
	uci -q delete dhcp.lan.ra_slaac
	uci -q delete dhcp.lan.ignore

	if [ "$mode" = "gateway" ]; then
		# ── 网关（PD）模式 ──
		# PPPoE 下 wan6 必须跑在拨号接口上，否则 DHCPv6-PD 拿不到
		if [ "$wan_proto" = "pppoe" ] && [ "$(uci -q get network.wan6.device)" != "pppoe-wan" ]; then
			uci set network.wan6.device="pppoe-wan"
		fi
		uci set dhcp.lan.ra=server
		uci set dhcp.lan.dhcpv6=server
		uci -q delete dhcp.lan.ndp
		uci set dhcp.wan6.ignore=1
		uci -q delete dhcp.wan6.ra
		uci -q delete dhcp.wan6.dhcpv6
		uci -q delete dhcp.wan6.ndp
		uci -q delete dhcp.wan6.master
		uci set network.wan6.reqaddress=none  # PPPoE 下只请求 PD，请求地址会触发 netifd Invalid argument 死循环
		uci set network.wan6.reqprefix=auto
		uci set network.lan.ip6assign=64
		uci set network.lan.ip6ifaceid=eui64
	else
		# ── 二级（Relay 中继）模式 ──
		uci set dhcp.lan.ra=relay
		uci set dhcp.lan.dhcpv6=relay
		uci set dhcp.lan.ndp=relay
		uci set dhcp.wan6.ra=relay
		uci set dhcp.wan6.dhcpv6=relay
		uci set dhcp.wan6.ndp=relay
		uci set dhcp.wan6.master=1
		uci -q delete dhcp.wan6.ignore
	fi

	uci commit dhcp
	uci commit network

	# 只重启 wan6 与 odhcpd（不重启 lan，避免 dropbear 掉线）
	/sbin/ifdown wan6 >/dev/null 2>&1
	/sbin/ifup wan6 >/dev/null 2>&1 &
	/etc/init.d/odhcpd restart >/dev/null 2>&1
	/etc/init.d/firewall reload >/dev/null 2>&1
}

if [ "$ACTION" = "apply" ]; then
	if [ -n "$FORCE" ]; then
		# 强制指定模式（跳过自动判断）
		case "$FORCE" in
			gateway)   apply_mode gateway;  echo "已强制应用 IPv6 模式: 网关（PD）" ;;
			secondary) apply_mode secondary; echo "已强制应用 IPv6 模式: 中继（Relay）" ;;
			*)         echo "用法: gwrt-ipv6-auto.sh apply [gateway|secondary]" ;;
		esac
	elif [ "$MODE" != "unknown" ]; then
		apply_mode "$MODE"
		echo "已应用 IPv6 模式: $V6MODE（lan 未重启，避免 dropbear 掉线）"
	else
		echo "自动判断: unknown（无法判断），未应用。可强制指定: gwrt-ipv6-auto.sh apply gateway|secondary"
	fi
fi

exit 0
