# Coordinate observable phase changes with network and Wi-Fi actions.
log() { logger -t gwrt-mesh-apmode "$@"; }

publish_phase() {
	phase="$1"
	phase_epoch="${3:-$(uptime_s)}"
	phase_ip="$2"
	phase_reason="$4"
	phase_band="$5"
	printf '%s %s %s %s %s\n' "$phase" "$phase_epoch" "${phase_ip:--}" "${phase_reason:--}" \
		"${phase_band:--}" >"$RUNDIR/phase.next" &&
		mv -f "$RUNDIR/phase.next" "$RUNDIR/phase"
	log "phase=$phase${phase_ip:+ address=$phase_ip}${phase_reason:+ reason=$phase_reason}${phase_band:+ band=$phase_band}"
}

pairing() {
	local token
	[ "$(uci -q get wifiroam.core.role)" = sap ] || return 1
	cap_ip="$(uci -q get wifiroam.core.cap_ip)"
	case "$cap_ip" in ''|*[!0-9.]*) return 1 ;; esac
	token="$(uci -q get wifiroam.core.token)"
	[ -n "$token" ] || return 1
	pair_hash="$(printf 'wifiroam:%s' "$token" | sha256sum | cut -c1-16)"
}

begin_search() {
	local started
	started="$(uptime_s)"
	case "$phase" in
		wired_pending) started="${search_since:-$started}" ;;
	esac
	publish_phase search "" "$started" "$1"
	search_since="$phase_epoch"
	: >"$RUNDIR/managed"
	search_band="$(preferred_band)"
	band_at="$(uptime_s)"
	wifi_epoch="$band_at"
	wifi_lost_at=
	case "$1" in cable_lost|wired_unavailable|wired_unreachable) wired_epoch="$band_at" ;; esac
	rm -f "$RUNDIR/prepair" "$RUNDIR/prepair-lan"
	if ! enter_search; then
		log "could not configure AP search; restoring router mode"
		begin_router reconfigure_failed
	fi
}

begin_router() {
	[ "$phase" = recover ] || publish_phase recover "" "" "$1"
	restore_router || return 1
	publish_phase router "" "" "$phase_reason"
}

end_session() {
	# Publish before changing UCI so in-flight CAP pushes cannot overwrite
	# the original SSIDs as we restore them.
	publish_phase idle
	if [ -f "$RUNDIR/managed" ] || [ -f "$RUNDIR/prepair" ] || [ -f "$RUNDIR/prepair-lan" ]; then
		restore_router || { publish_phase recover; return 1; }
		rm -f "$RUNDIR/managed" "$RUNDIR/prepair" "$RUNDIR/prepair-lan"
	fi
	last_pair=; search_since=
}

step() {
	local next reason band band_seconds
	if ! mesh_wanted || ! pairing; then
		[ "$phase" = idle ] || end_session || return 1
		if mesh_wanted && [ "$(uci -q get wifiroam.core.role)" = unconfigured ]; then
			prepair
		elif [ -f "$RUNDIR/prepair" ] || [ -f "$RUNDIR/prepair-lan" ]; then
			end_session || return 1
		fi
		return 0
	fi
	if [ -n "$last_pair" ] && [ "$last_pair" != "$cap_ip/$pair_hash" ]; then end_session || return 1; fi
	last_pair="$cap_ip/$pair_hash"

	now="$(uptime_s)"
	elapsed=$((now - phase_epoch))
	search_seconds="$(setting_seconds search_seconds 120)"
	router_seconds="$(setting_seconds router_seconds 60)"
	observe_links
	wifi_lost_for=0
	if [ "$phase" = wireless ] && [ "$wifi_ready" != 1 ]; then
		wifi_lost_at="${wifi_lost_at:-$now}"
		wifi_lost_for=$((now - wifi_lost_at))
	else
		wifi_lost_at=
	fi
	next="$(next_phase)"
	case "$next" in
		search)
			case "$phase" in
				wired_pending) wired_retry=$((now + 60)); begin_search "$wired_down_reason" ;;
				wired) wired_retry=$((now + 6)); begin_search "$wired_down_reason" ;;
				wireless) begin_search wireless_lost ;;
				router) begin_search "$phase_reason" ;;
				*) begin_search ;;
			esac ;;
		wired_pending)
			if [ "$phase" != search ]; then search_since="$now"; fi
			reason=wired_verified
			[ "$phase" != wireless ] || reason=wired_priority
			publish_phase wired_pending "" "" "$reason"
			bridge_epoch="$phase_epoch"
			bridge_seq="$cable_seq"
			if ! enter_wired; then
				wired_retry=$((now + 60))
				begin_search wired_unavailable
			fi ;;
		wired)
			publish_phase wired "$lan_ip" "" "$phase_reason"
			service dropbear restart
			repair_ft_bridge_sockets ;;
		wireless)
			if start_relay "$wifi_dev" "$wifi_ip"; then
				band="$(sta_band "$wifi_dev")"
				remember_band "$band" || log "could not remember wireless band"
				publish_phase wireless "$wifi_ip" "" "${phase_reason:-wireless_verified}" "$band"
			elif [ "$elapsed" -ge "$search_seconds" ]; then
				begin_router reconfigure_failed
			fi ;;
		router) begin_router search_timeout ;;
		'')
			case "$phase" in
				search)
					# Older CAPs may advertise the hidden backhaul only on 5 GHz.
					# Try the other configured radio within the same search window.
					band_seconds=30
					[ "$search_seconds" -ge 60 ] || band_seconds=$((search_seconds / 2))
					if [ "$((now - band_at))" -ge "$band_seconds" ]; then
						case "$search_band" in 2g) search_band=5g ;; *) search_band=2g ;; esac
						band_at="$now"
					fi
					if configure_sta "$search_band" && [ "$wifi_changed" = 1 ]; then
						wifi_epoch="$now"
						sta_dhcp && network_reload
					fi ;;
				wireless)
					[ "$wifi_ready" = 1 ] || return 0
					if start_relay "$wifi_dev" "$wifi_ip"; then
						[ "$phase_ip" = "$wifi_ip" ] || publish_phase wireless "$wifi_ip" "" "$phase_reason" "$phase_band"
					else
						begin_search reconfigure_failed
					fi ;;
				wired)
					if [ "$phase_ip" != "$lan_ip" ]; then
						publish_phase wired "$lan_ip" "" "$phase_reason"
						service dropbear restart
					fi
					repair_ft_bridge_sockets ;;
			esac ;;
	esac
	return 0
}

