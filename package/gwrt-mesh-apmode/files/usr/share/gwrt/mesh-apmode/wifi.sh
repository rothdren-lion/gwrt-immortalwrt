# Only this controller configures the satellite STA. wifiroamd stores the
# controller's credentials and applies the front-haul after a link is ready.
wifi_set() {
	local key="$1" value="$2"
	[ "$(uci -q get "$key")" = "$value" ] && return 0
	uci -q set "$key=$value" || return 1
	wifi_changed=1
}

wifi_unstage() {
	local sec opt
	wifi_present || return 0
	for sec in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
		[ "$(uci -q get "wireless.$sec.mode")" = ap ] || continue
		if [ "$(uci -q get "wireless.$sec.wifiroam_guest")" = 1 ]; then
			uci -q revert "wireless.$sec.disabled"
			continue
		fi
		case "$sec" in wifiroam_bh*) continue ;; esac
		for opt in ssid key encryption isolate ieee80211r mobility_domain ft_over_ds \
			ft_psk_generate_local nas_identifier pmk_r1_push r0kh r1kh \
			reassociation_deadline ieee80211k rrm_neighbor_report \
			rrm_beacon_report ieee80211v bss_transition; do
			uci -q revert "wireless.$sec.$opt"
		done
	done
	# Restore channels the STA used, and remove its runtime section. A legacy
	# STA is removed during migration, not resurrected on fallback.
	for sec in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		uci -q revert "wireless.$sec.channel"
	done
	uci -q revert "wireless.$BACKHAUL"
}

wifi_suspend_guests() {
	local sec
	wifi_present || return 0
	for sec in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
		[ "$(uci -q get "wireless.$sec.wifiroam_guest")" != 1 ] || \
			wifi_set "wireless.$sec.disabled" 1 || return 1
	done
}

choose_radio() {
	local want="$1" dir s
	for s in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		[ "$(uci -q get "wireless.$s.disabled")" != 1 ] || continue
		dir="$(uci -q get "wireless.$s.band")"
		[ "$dir" = "$want" ] && { echo "$s"; return; }
	done
	return 1
}

configure_sta() {
	local ssid key radio band ch value
	wifi_changed=0
	wifi_present || return 1
	[ "$(uci -q get wifiroam.backhaul.enabled)" = 1 ] || return 1
	ssid="$(uci -q get wifiroam.backhaul.ssid)"
	key="$(uci -q get wifiroam.backhaul.key)"
	[ -n "$ssid" ] && [ -n "$key" ] || return 1
	band="$1"
	radio="$(choose_radio "$band")"
	if [ -z "$radio" ]; then
		case "$band" in 2g) band=5g ;; *) band=2g ;; esac
		radio="$(choose_radio "$band")" || return 1
	fi
	if [ "$band" = 2g ]; then ch="$(uci -q get wifiroam.backhaul.channel2g)"
	else ch="$(uci -q get wifiroam.backhaul.channel)"; fi
	case "$ch" in ''|0|*[!0-9]*) ch= ;; esac
	# AP and STA share one radio. Align only when the CAP sent a channel for
	# this band. Undo our change to the other radio when switching bands.
	value="$(uci -q get "wireless.$BACKHAUL.device")"
	if [ -n "$value" ] && [ "$value" != "$radio" ]; then uci -q revert "wireless.$value.channel"; fi
	if [ -n "$ch" ]; then
		wifi_set "wireless.$radio.channel" "$ch" || return 1
	elif [ "$value" = "$radio" ]; then
		uci -q changes wireless | grep -Fq "wireless.$radio.channel=" && {
			uci -q revert "wireless.$radio.channel"
			wifi_changed=1
		}
	fi
	wifi_set "wireless.$BACKHAUL" wifi-iface &&
	wifi_set "wireless.$BACKHAUL.device" "$radio" &&
	wifi_set "wireless.$BACKHAUL.mode" sta &&
	wifi_set "wireless.$BACKHAUL.ssid" "$ssid" &&
	wifi_set "wireless.$BACKHAUL.key" "$key" &&
	wifi_set "wireless.$BACKHAUL.encryption" psk2+ccmp &&
	wifi_set "wireless.$BACKHAUL.network" "$STA_NET" &&
	wifi_set "wireless.$BACKHAUL.wds" 0 &&
	wifi_set "wireless.$BACKHAUL.disabled" 0
}

sta_disable() {
	local radio
	[ "$(uci -q get "wireless.$BACKHAUL.mode")" = sta ] || return 0
	uci -q set "wireless.$BACKHAUL.disabled=1" || return 1
	radio="$(uci -q get "wireless.$BACKHAUL.device")"
	[ -z "$radio" ] || uci -q revert "wireless.$radio.channel"
	return 0
}

preferred_band() {
	local addr sig band
	if [ -r "$RUNDIR/last-band" ] && read -r addr sig band <"$RUNDIR/last-band" &&
	   [ "$addr" = "$cap_ip" ] && [ "$sig" = "$pair_hash" ]; then
		case "$band" in
			2g|5g) if choose_radio "$band" >/dev/null; then echo "$band"; return; fi ;;
		esac
	fi
	case "$(uci -q get wifiroam.backhaul.band)" in 5g) echo 5g ;; *) echo 2g ;; esac
}

sta_band() {
	local st radio dev
	st="$(ubus -t 2 call network.wireless status 2>/dev/null)" || return 1
	for radio in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		case "$radio" in ''|*[!a-zA-Z0-9_]*) continue ;; esac
		dev="$(json_field "$st" "@[\"$radio\"].interfaces[@.section=\"$BACKHAUL\"].ifname")"
		[ "$dev" = "$1" ] || continue
		case "$(uci -q get "wireless.$radio.band")" in
			2g) echo 2g; return ;;
			5g) echo 5g; return ;;
		esac
	done
	return 1
}

remember_band() {
	case "$1" in 2g|5g) ;; *) return 0 ;; esac
	printf '%s %s %s\n' "$cap_ip" "$pair_hash" "$1" >"$RUNDIR/last-band.next" &&
		mv -f "$RUNDIR/last-band.next" "$RUNDIR/last-band"
}

ensure_legacy_wireless_restored() {
	local orig=/etc/gwrt-wireless-orig
	[ -s "$orig" ] && grep -Eq "^config[[:space:]]+wifi-device" "$orig" || return 0
	cp -p "$orig" /etc/config/.gwrt-wireless-next && \
		chmod 600 /etc/config/.gwrt-wireless-next && \
		mv -f /etc/config/.gwrt-wireless-next /etc/config/wireless
}
