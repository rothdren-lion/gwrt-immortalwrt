# Repair FT over DS sockets when netifd recreates br-lan.

ft_bridge_socket_stale() {
	awk '($4 == "890d" || $4 == "88b7") && $5 == "-1" { stale = 1 } END { exit !stale }' /proc/net/packet 2>/dev/null
}

repair_ft_bridge_sockets() {
	local status radio radios="" ifnames ifname conf needed sig waited=0
	# FT(BSS 间漫游) 修复要停/起 wifi-device，纯有线机型没有可修的对象
	wifi_present || return 0
	ft_bridge_socket_stale || return 0
	# 对同一旧 socket 只尝试一次，失败不能变成周期性踢客。
	sig="$(cat /sys/class/net/br-lan/ifindex 2>/dev/null):$(awk '($4 == "890d" || $4 == "88b7") && $5 == "-1" { printf "%s:%s;", $4, $9 }' /proc/net/packet 2>/dev/null)"
	[ "$sig" = "$(cat /tmp/gwrt-ft-bridge-repair.sig 2>/dev/null)" ] && return 0
	status="$(ubus call network.wireless status 2>/dev/null)"
	for radio in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		ifnames="$(printf '%s' "$status" | jsonfilter -e "@.$radio.interfaces[*].ifname" 2>/dev/null)"
		needed=0
		for ifname in $ifnames; do
			conf="/var/run/hostapd-${ifname%%-*}.conf"
			[ -r "$conf" ] || continue
			grep -qx 'bridge=br-lan' "$conf" &&
				grep -qx 'ft_iface=br-lan' "$conf" &&
				grep -q '^mobility_domain=' "$conf" && needed=1
		done
		[ "$needed" = 1 ] || continue
		radios="$radios $radio"
	done
	[ -n "$radios" ] || return 0
	echo "$sig" >/tmp/gwrt-ft-bridge-repair.sig
	log "stale FT bridge socket, rebuilding BSS:$radios"
	# ETH_P_OUI 在同一个 bridge 的 BSS 之间共享，必须先停完再启动，
	# 逐个 down/up 会让其他 BSS 一直引用旧 ifindex。
	for radio in $radios; do
		ubus call network.wireless down "{\"device\":\"$radio\"}" >/dev/null 2>&1
	done
	# netifd 的 down 是异步操作；等共享 socket 释放后才能重新注册。
	while ft_bridge_socket_stale && [ "$waited" -lt 10 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	for radio in $radios; do
		ubus call network.wireless up "{\"device\":\"$radio\"}" >/dev/null 2>&1
	done
	ft_bridge_socket_stale && log "FT bridge socket still stale, automatic retry suppressed for this socket"
}
