# Physical port, DHCP and paired CAP observations. Carrier by itself is not a
# usable wired uplink. Evidence is stamped by wifiroamd using IP_PKTINFO.
SYS_NET=/sys/class/net
STA_NET=gwrt_mesh
BACKHAUL=wifiroam_bh

uptime_s() {
	local up
	read -r up _ </proc/uptime
	printf '%s\n' "${up%%.*}"
}

setting_seconds() {
	local n
	n="$(uci -q get "gwrt.mesh_apmode.$1")"
	case "$n" in ''|*[!0-9]*|0*) n="$2" ;; esac
	if [ "$n" -ge 15 ] 2>/dev/null && [ "$n" -le 3600 ]; then echo "$n"
	else echo "$2"; fi
}

mesh_wanted() {
	[ "$(uci -q get gwrt.mesh_apmode.enabled)" != 0 ] &&
	[ "$(uci -q get wifiroam.core.enabled)" != 0 ] &&
	[ -x /etc/init.d/wifiroam ] && /etc/init.d/wifiroam enabled >/dev/null 2>&1
}

wifi_present() { [ -f /etc/config/wireless ] && [ -x /sbin/wifi ]; }

ifname_ok() {
	case "$1" in ''|*[!a-zA-Z0-9_.:-]*) return 1 ;; esac
	[ "${#1}" -le 15 ] && [ "$1" != br-lan ] && [ "$1" != lo ]
}

wan_dev_name() {
	local d
	d="$(uci -q get network.wan.device || uci -q get network.wan.ifname)"
	ifname_ok "$d" && printf '%s\n' "$d"
}

brlan_dev_section() {
	local s
	for s in $(uci -q show network | sed -n 's/^network\.\([^.]*\)=device$/\1/p'); do
		[ "$(uci -q get "network.$s.name")" = br-lan ] && { echo "$s"; return; }
	done
	return 1
}

iface_status() { ubus -t 2 call "network.interface.$1" status 2>/dev/null; }
json_field() { printf '%s' "$1" | jsonfilter -e "$2" 2>/dev/null; }

subnet_has() {
	# The CAP must be on-link in the DHCP lease, using its actual prefix.
	awk -v addr="$1" -v mask="$2" -v cap="$3" '
		function ip(s,   a,n,i,v) {
			n=split(s,a,"."); if(n!=4) return -1
			for(i=1;i<=4;i++) {
				if(a[i]!~/^[0-9]+$/ || a[i]>255) return -1
				v=v*256+a[i]
			}
			return v
		}
		BEGIN {
			a=ip(addr); b=ip(cap)
			if(a<0 || b<0 || mask!~/^[0-9]+$/ || mask<1 || mask>32) exit 1
			size=2^(32-mask)
			exit !(int(a/size)==int(b/size))
		}'
}

lease_on() {
	local st ip mask
	st="$(iface_status "$1")"
	[ "$(json_field "$st" '@.up')" = true ] || return 1
	[ "$(json_field "$st" '@.proto')" = dhcp ] || return 1
	[ "$(json_field "$st" '@.l3_device')" = "$2" ] || return 1
	ip="$(json_field "$st" '@["ipv4-address"][0].address')"
	mask="$(json_field "$st" '@["ipv4-address"][0].mask')"
	[ "$ip" != "$cap_ip" ] || return 1
	subnet_has "$ip" "$mask" "$cap_ip" && printf '%s\n' "$ip"
}

cap_recent() {
	local idx seen source sig seq
	[ -n "$1" ] && [ -r "$SYS_NET/$1/ifindex" ] && read -r idx <"$SYS_NET/$1/ifindex" || return 1
	case "$idx" in ''|*[!0-9]*) return 1 ;; esac
	[ -f "$RUNDIR/cap.$idx" ] && read -r seen source sig seq <"$RUNDIR/cap.$idx" || return 1
	case "$seen" in ''|*[!0-9]*) return 1 ;; esac
	[ "$source" = "$cap_ip" ] && [ "$sig" = "$pair_hash" ] &&
	[ "$seen" -gt "${2:-0}" ] && [ "$now" -ge "$seen" ] &&
	[ "$((now - seen))" -le 16 ] && [ "${3:-$seq}" = "$seq" ]
}

refresh_cable() {
	cable=0; cable_seq=
	[ -n "$wandev" ] && [ -e "$SYS_NET/$wandev/carrier" ] || return 0
	[ "$(cat "$SYS_NET/$wandev/carrier" 2>/dev/null)" = 1 ] && cable=1
	cable_seq="$(cat "$SYS_NET/$wandev/carrier_down_count" 2>/dev/null)"
	return 0
}

wired_keepalive() {
	# Only an established bridge with a known, unchanged cable sequence may
	# use unicast in place of a missed broadcast.
	case "$cable_seq" in ''|*[!0-9]*) return 1 ;; esac
	if [ "$now" -ge "${wired_probe_next:-0}" ]; then
		wired_probe_next=$((now + 4))
		if ping -4 -q -I br-lan -c 1 -W 1 -w 1 "$cap_ip" >/dev/null 2>&1; then
			wired_probe_misses=0
		else
			wired_probe_misses=$((${wired_probe_misses:-0} + 1))
		fi
	fi
	[ "${wired_probe_misses:-0}" -lt 3 ]
}

observe_bridge() {
	wired_down_reason=cable_lost
	[ "$cable" = 1 ] && [ "$bridge_seq" = "$cable_seq" ] || return 0
	wired_down_reason=wired_unavailable
	wan_is_bridged || return 0
	lan_ip="$(lease_on lan br-lan)"
	[ -n "$lan_ip" ] || return 0
	if cap_recent br-lan "$bridge_epoch"; then
		wired_probe_misses=0
		wired_probe_next=0
	elif [ "$phase" = wired ]; then
		wired_down_reason=wired_unreachable
		wired_keepalive || return 0
	else
		return 0
	fi
	wired_ready=1
}

observe_links() {
	local st
	wired=0; wired_ready=0; wifi_ready=0; lan_ip=; wifi_ip=; wifi_dev=
	refresh_cable
	if [ "$cable" = 1 ] && [ "$cable_seq" != "${last_cable_seq-}" ]; then
		wired_retry=0
	fi
	last_cable_seq="$cable_seq"
	case "$phase" in
		wired|wired_pending) observe_bridge ;;
		*)
			if [ "$cable" = 1 ] && [ "$now" -ge "$wired_retry" ] &&
			   cap_recent "$wandev" "$wired_epoch" "${cable_seq:--}" &&
			   [ -n "$(lease_on wan "$wandev")" ]; then
				# Require both a beacon on this physical link and an
				# on-link lease before dropping a working STA.
				wired=1
			fi ;;
	esac
	case "$phase" in search|wireless)
		[ "$(uci -q get wifiroam.backhaul.enabled)" = 1 ] || return 0
		st="$(iface_status "$STA_NET")"
		wifi_dev="$(json_field "$st" '@.l3_device')"
		if ifname_ok "$wifi_dev" && [ "$wifi_dev" != "$wandev" ] &&
		   [ "$(cat "$SYS_NET/$wifi_dev/carrier" 2>/dev/null)" = 1 ] &&
		   cap_recent "$wifi_dev" "$wifi_epoch" "$(cat "$SYS_NET/$wifi_dev/carrier_down_count" 2>/dev/null || echo -)"; then
			wifi_ip="$(lease_on "$STA_NET" "$wifi_dev")"
			[ -z "$wifi_ip" ] || wifi_ready=1
		fi ;;
	esac
	return 0
}
