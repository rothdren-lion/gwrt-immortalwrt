# Decide the next phase from observations. All deadlines use boot uptime.
# Globals: phase, elapsed, cable, wired, wifi_ready, wired_ready, wifi_lost_for,
#            wired_down_reason, search_seconds, router_seconds.
next_phase() {
	case "$phase" in
		idle) echo search ;;
		search)
			if [ "$wired" = 1 ]; then echo wired_pending
			elif [ "$wifi_ready" = 1 ]; then echo wireless
			elif [ "$elapsed" -ge "$search_seconds" ]; then echo router
			fi ;;
		wired_pending)
			if [ "$wired_down_reason" = cable_lost ]; then echo search
			elif [ "$wired_ready" = 1 ]; then echo wired
			elif [ "$elapsed" -ge 25 ]; then echo search
			fi ;;
		wired)
			[ "$cable" = 1 ] && [ "$wired_ready" = 1 ] || echo search ;;
		wireless)
			if [ "$wired" = 1 ]; then echo wired_pending
			elif [ "$wifi_ready" != 1 ] && [ "$wifi_lost_for" -ge 6 ]; then echo search
			fi ;;
		recover) echo router ;;
		router)
			# A verified cable can end the recovery window early. Wi-Fi stays
			# off here so the original router SSID can use its own channel.
			if [ "$wired" = 1 ] || [ "$elapsed" -ge "$router_seconds" ]; then echo search; fi ;;
	esac
}
