# Netifd and firewall read UCI's normal /tmp deltas. Keep phase changes
# volatile: a reboot starts with the saved router configuration intact.
AP_OFF="dnsmasq odhcpd turboacc eqos daed homeproxy shadowsocksr microsocks easytier bandix-plus appfilter ttyd"
RELAY_NAME=gwrt-mesh-relay
HNAT_KNOB=/sys/kernel/debug/hnat/hook_toggle
STATE=/etc/gwrt-apmode.state

active_hnat() {
	[ ! -w "$HNAT_KNOB" ] || printf '%s\n' "$1" >"$HNAT_KNOB" 2>/dev/null
}

service() {
	local name="$1" action="$2"
	[ ! -x "/etc/init.d/$name" ] || "/etc/init.d/$name" "$action" >/dev/null 2>&1
}

network_reload() {
	/etc/init.d/network reload >/dev/null 2>&1
}

suspend_router_services() {
	local s
	if [ ! -f "$RUNDIR/services" ]; then
		for s in $AP_OFF; do
			[ -x "/etc/init.d/$s" ] || continue
			if service "$s" running; then echo "$s"; fi
		done >"$RUNDIR/services.next"
		mv -f "$RUNDIR/services.next" "$RUNDIR/services" || return 1
		if [ -r "$HNAT_KNOB" ]; then cat "$HNAT_KNOB" >"$RUNDIR/hnat"; fi
	fi
	active_hnat 0 || return 1
	for s in $AP_OFF; do service "$s" stop; done
	for s in dnsmasq odhcpd; do
		[ ! -x "/etc/init.d/$s" ] || ! service "$s" running || return 1
	done
	return 0
}

resume_router_services() {
	local s hnat
	[ -f "$RUNDIR/services" ] || return 0
	hnat="$(cat "$RUNDIR/hnat" 2>/dev/null)"
	case "$hnat" in 0|1) active_hnat "$hnat" ;; esac
	while read -r s; do [ -z "$s" ] || service "$s" start; done <"$RUNDIR/services"
	rm -f "$RUNDIR/services" "$RUNDIR/hnat"
}

mesh_firewall() {
	local z
	if [ "$1" = off ]; then
		[ -f "$RUNDIR/firewall-zone" ] || return 0
		read -r z <"$RUNDIR/firewall-zone"
		uci -q revert "firewall.$z.network"
		service firewall reload || return 1
		rm -f "$RUNDIR/firewall-zone"
		return 0
	fi
	for z in $(uci -q show firewall | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
		[ "$(uci -q get "firewall.$z.name")" = lan ] || continue
		if ! uci -q get "firewall.$z.network" | tr ' ' '\n' | grep -Fxq "$STA_NET"; then
			echo "$z" >"$RUNDIR/firewall-zone" || return 1
			uci -q add_list "firewall.$z.network=$STA_NET" || return 1
		fi
		service firewall reload
		return $?
	done
	return 1
}

stop_relay() {
	local pid i
	[ -f "$RUNDIR/relay" ] || return 0
	pid="$(relay_status pid)"
	ubus -t 2 call service delete '{"name":"gwrt-mesh-relay"}' >/dev/null 2>&1 || {
		[ "$(relay_status)" != true ] || return 1
	}
	case "$pid" in
		''|0|*[!0-9]*) ;;
		*) for i in 1 2 3; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		! kill -0 "$pid" 2>/dev/null || return 1 ;;
	esac
	rm -f "$RUNDIR/relay"
	service odhcpd stop
	uci -q revert dhcp.gwrt_mesh_upstream
	return 0
}

relay_status() {
	ubus -t 2 call service list '{"name":"gwrt-mesh-relay"}' 2>/dev/null |
		jsonfilter -e "@[\"gwrt-mesh-relay\"].instances.ipv4.${1:-running}" 2>/dev/null
}

start_relay() {
	local dev="$1" addr="$2" info i
	[ -x /usr/sbin/relayd ] && ifname_ok "$dev" && [ -n "$addr" ] || return 1
	info="$dev $addr"
	if [ "$(cat "$RUNDIR/relay" 2>/dev/null)" = "$info" ] &&
	   [ "$(relay_status)" = true ]; then return 0; fi
	stop_relay || return 1
	# 3-address station stays separate from br-lan. relayd forwards DHCP and
	# ARP between them; -L makes the station's lease reachable from both sides.
	printf '%s\n' "$info" >"$RUNDIR/relay" || return 1
	ubus -t 2 call service set "{
		\"name\":\"$RELAY_NAME\",
		\"instances\":{\"ipv4\":{\"command\":[\"/usr/sbin/relayd\",\"-I\",\"br-lan\",
			\"-I\",\"$dev\",\"-L\",\"$addr\",\"-T\",\"16864\",\"-B\",\"-D\"],
			\"respawn\":[3600,2,4],\"netdev\":[\"br-lan\",\"$dev\"]}}}" >/dev/null 2>&1 || return 1
	for i in 1 2 3; do
		[ "$(relay_status)" = true ] && break
		sleep 1
	done
	[ "$(relay_status)" = true ] || { stop_relay; return 1; }
	mesh_firewall on || { stop_relay; return 1; }
	# odhcpd can relay RA/DHCPv6/NDP where the upstream provides IPv6.
	# odhcpd reads relay modes even with dhcp.lan.ignore set for dnsmasq.
	if [ -x /etc/init.d/odhcpd ]; then
		local opt
		uci -q set dhcp.gwrt_mesh_upstream=dhcp
		for opt in ra dhcpv6 ndp; do
			uci -q set "dhcp.gwrt_mesh_upstream.$opt=relay"
			uci -q set "dhcp.lan.$opt=relay"
		done
		uci -q set dhcp.lan.dhcpv4=disabled
		uci -q set dhcp.gwrt_mesh_upstream.ignore=1
		uci -q set dhcp.gwrt_mesh_upstream.interface="$STA_NET"
		uci -q set dhcp.gwrt_mesh_upstream.master=1
		service odhcpd restart
	fi
	# Bind to the DHCP address. An interface-bound listener on the
	# station would refuse packets from clients arriving on br-lan.
	if [ "$(uci -q get 'dropbear.@dropbear[0].DirectInterface')" = lan ]; then
		uci -q delete 'dropbear.@dropbear[0].DirectInterface'
		uci -q set "dropbear.@dropbear[0].Interface=$STA_NET"
	elif [ "$(uci -q get 'dropbear.@dropbear[0].Interface')" = lan ]; then
		uci -q set "dropbear.@dropbear[0].Interface=$STA_NET"
	fi
	service dropbear restart
	return 0
}

sta_dhcp() {
	uci -q set "network.$STA_NET=interface" &&
	uci -q set "network.$STA_NET.proto=dhcp" &&
	uci -q set "network.$STA_NET.metric=10"
}

disable_local_dhcp() {
	local opt
	uci -q set dhcp.lan.ignore=1 || return 1
	for opt in ra dhcpv6 ndp dhcpv4; do
		uci -q set "dhcp.lan.$opt=disabled" || return 1
	done
}

restore_management() {
	uci -q revert 'dropbear.@dropbear[0].DirectInterface'
	uci -q revert 'dropbear.@dropbear[0].Interface'
	return 0
}

wan_is_bridged() {
	[ -n "$wandev" ] && [ -e "$SYS_NET/br-lan/brif/$wandev" ]
}

wait_wan_detached() {
	local i
	for i in 1 2 3; do
		wan_is_bridged || return 0
		sleep 1
	done
	! wan_is_bridged
}

# Runtime marker consumed by gwrt-agent and mesh_status.sh.  It must not be
# mistaken for the legacy committed-router snapshot (legacy_migrate sources
# that file), hence the explicit key below.
mark_apmode() {
	mkdir -p /etc/gwrt || return 1
	printf 'gwrt_apmode_runtime=1\nphase=%s\n' "$1" >"$STATE.new" &&
		mv -f "$STATE.new" "$STATE"
}

clear_apmode() {
	rm -f "$STATE" "$STATE.new"
}

enter_search() {
	stop_relay && mesh_firewall off || return 1
	suspend_router_services || return 1
	if bridge_port_configured; then
		uci -q del_list "network.$brsec.ports=$wandev" || return 1
	fi
	uci -q set network.lan.proto=none || return 1
	disable_local_dhcp || return 1
	if [ -n "$wandev" ]; then
		uci -q set network.wan.proto=dhcp &&
		uci -q set network.wan.defaultroute=0 &&
		uci -q set network.wan.peerdns=0 &&
		uci -q set network.wan.metric=4096 || return 1
	fi
	if uci -q get network.wan6 >/dev/null; then uci -q set network.wan6.proto=none; fi
	# Netifd can finish removing a port after it accepts the reload. Wait
	# before starting the STA, even if the cable currently has no carrier.
	if wan_is_bridged; then
		sta_disable && network_reload && wait_wan_detached || return 1
	fi
	wifi_suspend_guests || return 1
	if configure_sta "$search_band"; then sta_dhcp || return 1
	else sta_disable; uci -q revert "network.$STA_NET"; fi
	restore_management
	mark_apmode search
	network_reload
}

enter_wired() {
	local i sta k
	[ -n "$brsec" ] && [ -n "$wandev" ] || return 1
	stop_relay && mesh_firewall off || return 1
	suspend_router_services || return 1
	# Tear down the relay and disconnect the STA before opening the WAN bridge.
	sta="$(json_field "$(iface_status "$STA_NET")" '@.l3_device')"
	sta_disable || return 1
	if ifname_ok "$sta"; then
		ubus -t 2 call "network.interface.$STA_NET" down >/dev/null 2>&1
		network_reload || return 1
		for i in 1 2 3 4 5; do
			[ "$(cat "$SYS_NET/$sta/carrier" 2>/dev/null)" != 1 ] && break
			sleep 1
		done
		[ "$(cat "$SYS_NET/$sta/carrier" 2>/dev/null)" != 1 ] || return 1
	fi
	uci -q revert "network.$STA_NET"
	[ "$(cat "$SYS_NET/$wandev/carrier" 2>/dev/null)" = 1 ] || return 1
	[ "$cable_seq" = "$(cat "$SYS_NET/$wandev/carrier_down_count" 2>/dev/null)" ] || return 1
	if ! uci -q get "network.$brsec.ports" | tr ' ' '\n' | grep -Fxq "$wandev"; then
		uci -q add_list "network.$brsec.ports=$wandev" || return 1
	fi
	uci -q set network.wan.proto=none &&
	uci -q set network.lan.proto=dhcp || return 1
	if uci -q get network.wan6 >/dev/null; then uci -q set network.wan6.proto=none; fi
	for k in ipaddr netmask gateway dns; do uci -q delete "network.lan.$k"; done
	disable_local_dhcp || return 1
	restore_management
	mark_apmode wired
	network_reload
}

restore_router() {
	local k
	stop_relay && mesh_firewall off || return 1
	clear_apmode
	[ -z "$brsec" ] || uci -q revert "network.$brsec.ports"
	for k in lan.proto lan.ipaddr lan.netmask lan.gateway lan.dns wan.proto \
		wan.defaultroute wan.peerdns wan.metric wan6.proto "$STA_NET"; do
		uci -q revert "network.$k"
	done
	for k in ignore ra dhcpv6 ndp dhcpv4; do uci -q revert "dhcp.lan.$k"; done
	restore_management
	wifi_unstage
	network_reload || return 1
	if ! bridge_port_configured; then wait_wan_detached || return 1; fi
	resume_router_services
	service dropbear restart
	return 0
}

bridge_port_configured() {
	[ -n "$brsec" ] && uci -q get "network.$brsec.ports" | tr ' ' '\n' | grep -Fxq "$wandev"
}

legacy_migrate() {
	if grep -qx 'gwrt_apmode_runtime=1' "$STATE" 2>/dev/null; then
		# Volatile marker from a live AP session: the network changes are
		# uncommitted, so there is no legacy snapshot to restore.
		clear_apmode
		return 0
	fi
	if [ ! -f "$STATE" ]; then
		# Old wireless discovery committed this section even before pairing.
		# Keep unrelated WAN/WWAN settings and CAP backhaul AP sections intact.
		[ "$(uci -q get "wireless.$BACKHAUL.mode")" = sta ] || return 0
		case "$(uci -q get "wireless.$BACKHAUL.network")" in
			lan|wwan) uci -q delete "wireless.$BACKHAUL" && uci -q commit wireless && network_reload ;;
			*) return 0 ;;
		esac
		return $?
	fi
	active_hnat 0 || return 1
	restore_legacy_network || return 1
	# Legacy builds committed AP settings and disabled services. Restore them
	# once, then discard the legacy state only after all writes succeeded.
	local z s
	for z in $(uci -q show firewall | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
		uci -q del_list "firewall.$z.network=wwan"
	done
	uci -q commit firewall || return 1
	ensure_legacy_wireless_restored || return 1
	for s in wifiroam_bh wifiroam_bh2; do uci -q delete "wireless.$s"; done
	wifi_present && { uci -q commit wireless || return 1; }
	network_reload || return 1
	service firewall reload
	active_hnat 1
	for s in $svc_enabled; do service "$s" enable; service "$s" start; done
	service dropbear restart
	rm -f "$STATE"
	log "migrated saved router configuration"
}

prepair_disjoint_lan() {
	local uplink lan ip mask lan_ip lan_mask alternate
	[ "$(uci -q get network.lan.proto)" = static ] || return 0
	uplink="$(iface_status "$1")"
	if [ "$(json_field "$uplink" '@.up')" != true ]; then
		[ -f "$RUNDIR/prepair-lan" ] || return 0
		uci -q revert network.lan.ipaddr
		uci -q revert network.lan.netmask
		network_reload || return 1
		[ ! -x /etc/init.d/dnsmasq ] || ! service dnsmasq running || service dnsmasq restart
		rm -f "$RUNDIR/prepair-lan"
		return 0
	fi
	ip="$(json_field "$uplink" '@["ipv4-address"][0].address')"
	mask="$(json_field "$uplink" '@["ipv4-address"][0].mask')"
	lan="$(iface_status lan)"
	lan_ip="$(json_field "$lan" '@["ipv4-address"][0].address')"
	lan_mask="$(json_field "$lan" '@["ipv4-address"][0].mask')"
	if ! subnet_has "$ip" "$mask" "$lan_ip" && ! subnet_has "$lan_ip" "$lan_mask" "$ip"; then
		return 0
	fi
	# Two factory routers can share 192.168.3.3. Give the unpaired
	# satellite a temporary local address so traffic can reach its uplink.
	for alternate in 192.168.4.1 172.31.254.1 10.254.254.1; do
		! subnet_has "$ip" "$mask" "$alternate" && ! subnet_has "$alternate" 24 "$ip" || continue
		[ "$(uci -q get network.lan.ipaddr)" != "$alternate" ] || return 0
		: >"$RUNDIR/prepair-lan" || return 1
		uci -q set "network.lan.ipaddr=$alternate" && \
			uci -q set network.lan.netmask=255.255.255.0 && network_reload || return 1
		[ ! -x /etc/init.d/dnsmasq ] || ! service dnsmasq running || service dnsmasq restart
		log "temporarily moved unpaired LAN to $alternate to avoid its uplink subnet"
		return 0
	done
}

prepair() {
	# Preserve automatic first-time Wi-Fi discovery for an unconfigured unit.
	# Connected WAN is still the default discovery path before a CAP is known.
	refresh_cable
	if [ "$cable" = 1 ] || ! configure_sta "$(preferred_band)"; then
		if [ -f "$RUNDIR/prepair" ]; then
			sta_disable
			uci -q revert "wireless.$BACKHAUL"
			uci -q revert "network.$STA_NET"
			rm -f "$RUNDIR/prepair"
			network_reload
		fi
		prepair_disjoint_lan wan
		return $?
	fi
	sta_dhcp || return 1
	if [ ! -f "$RUNDIR/prepair" ] || [ "$wifi_changed" = 1 ]; then
		: >"$RUNDIR/prepair"
		network_reload
	fi
	prepair_disjoint_lan "$STA_NET"
}
