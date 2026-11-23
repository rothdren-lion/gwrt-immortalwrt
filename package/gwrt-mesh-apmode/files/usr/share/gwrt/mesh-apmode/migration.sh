# Restore the persistent router snapshot produced by pre-handover releases.

restore_option() {
	local section="$1" option="$2" present="$3" value="$4" type="$5" item
	# Legacy files saved LAN address values without presence flags. Restore those
	# known values, but leave current options alone when the old file has no value.
	if [ -z "$present" ]; then
		[ -n "$value" ] || return 0
		present=1
	fi
	if [ "$present" = 1 ]; then
		if [ "$type" = list ]; then
			uci -q delete "$section.$option" 2>/dev/null
			for item in $value; do uci -q add_list "$section.$option=$item"; done
		else
			uci -q set "$section.$option=$value"
		fi
	else
		uci -q delete "$section.$option" 2>/dev/null
	fi
}

restore_wan_bridge_membership() {
	local brsec="$1" brged="$2" ports p newp="" wdev
	[ -n "$brsec" ] || return 0
	wdev="${wandev:-$(wan_dev_name)}"
	ports="$(uci -q get "network.$brsec.ports")"
	for p in $ports; do
		[ "$p" = "$wdev" ] || newp="$newp $p"
	done
	if [ "$brged" = 1 ]; then
		newp="$newp $wdev"
	fi
	uci -q delete "network.$brsec.ports"
	for p in $newp; do uci -q add_list "network.$brsec.ports=$p"; done
}

load_state() {
	# The daemon can restore several snapshots during one process lifetime.
	# Do not let fields absent from an older snapshot inherit earlier values.
	unset lan_proto lan_ipaddr lan_netmask lan_gateway lan_dns
	unset lan_ipaddr_present lan_netmask_present lan_gateway_present lan_dns_present lan_dns_type
	unset wan_proto wan6_proto wan_ipaddr wan_netmask wan_gateway wan_dns
	unset wan_ipaddr_present wan_netmask_present wan_gateway_present wan_dns_present wan_dns_type
	unset dhcp_ra dhcp_dhcpv6 dhcp_ndp dhcp_ra_present dhcp_dhcpv6_present dhcp_ndp_present
	unset dhcp_ignore db_iface brdev wandev bridged_wandev svc_enabled
	. "$STATE"
}

restore_legacy_network() {
	[ -f "$STATE" ] || return 0
	local brsec wandev
	load_state
	brsec="${brdev:-$(brlan_dev_section)}"
	if [ -n "${bridged_wandev+x}" ]; then
		restore_wan_bridge_membership "$brsec" "$bridged_wandev"
	else
		case "${wan_proto:-none}" in
			none|"") : ;;
			*) restore_wan_bridge_membership "$brsec" 0 ;;
		esac
	fi
	uci -q get network.relay >/dev/null 2>&1 && uci -q delete network.relay
	uci -q get network.wwan >/dev/null 2>&1 && uci -q delete network.wwan
	uci -q set dropbear.@dropbear[0].Interface="${db_iface:-lan}"
	uci -q set network.lan.proto="${lan_proto:-static}"
	restore_option network lan.ipaddr "${lan_ipaddr_present:-}" "${lan_ipaddr-}"
	restore_option network lan.netmask "${lan_netmask_present:-}" "${lan_netmask-}"
	restore_option network lan.gateway "${lan_gateway_present:-}" "${lan_gateway-}"
	restore_option network lan.dns "${lan_dns_present:-}" "${lan_dns-}" "${lan_dns_type:-}"
	if [ -n "$dhcp_ignore" ]; then
		uci -q set dhcp.lan.ignore="$dhcp_ignore"
	else
		uci -q delete dhcp.lan.ignore
	fi
	restore_option dhcp lan.ra "${dhcp_ra_present:-}" "${dhcp_ra-}"
	restore_option dhcp lan.dhcpv6 "${dhcp_dhcpv6_present:-}" "${dhcp_dhcpv6-}"
	restore_option dhcp lan.ndp "${dhcp_ndp_present:-}" "${dhcp_ndp-}"
	[ -n "$wan_proto" ] && uci -q set network.wan.proto="$wan_proto"
	[ -n "$wan6_proto" ] && uci -q set network.wan6.proto="$wan6_proto"
	restore_option network wan.ipaddr "${wan_ipaddr_present:-}" "${wan_ipaddr-}"
	restore_option network wan.netmask "${wan_netmask_present:-}" "${wan_netmask-}"
	restore_option network wan.gateway "${wan_gateway_present:-}" "${wan_gateway-}"
	restore_option network wan.dns "${wan_dns_present:-}" "${wan_dns-}" "${wan_dns_type:-}"
	uci -q commit network && uci -q commit dhcp && uci -q commit dropbear
}
