# Merge the tracker cache with current observations. DHCP is metadata, never
# evidence that a device is present. Keep this compatible with BusyBox awk.
function mac_key(value, octets, count, j) {
	value = tolower(value)
	gsub(/-/, ":", value)
	count = split(value, octets, ":")
	if (count != 6) return ""
	for (j = 1; j <= count; j++)
		if (octets[j] !~ /^[0-9a-f][0-9a-f]$/) return ""
	return value
}
function text_field(record, key, pattern) {
	pattern = "\"" key "\":\"[^\"]*\""
	if (match(record, pattern)) return substr(record, RSTART + length(key) + 4, RLENGTH - length(key) - 5)
	return ""
}
function number_field(record, key, pattern) {
	pattern = "\"" key "\":[0-9]+"
	if (match(record, pattern)) return substr(record, RSTART + length(key) + 3) + 0
	return 0
}
function ipv4(value) {
	return value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/
}
BEGIN {
	if (state_file != "") {
		while ((getline line < state_file) > 0) existing = existing line
		close(state_file)
	}
	legacy_updated = number_field(existing, "updated")
	n = split(existing, records, /\{"mac":"/)
	for (i = 2; i <= n; i++) {
		s = records[i]
		mac = ""
		if (match(s, /^[^"]+/)) mac = mac_key(substr(s, RSTART, RLENGTH))
		if (!mac) continue
		last = number_field(s, "last_seen")
		# Migrate old caches once, using their saved observation time.
		if (!last) last = number_field(s, "offline_at")
		if (!last) last = legacy_updated
		if (!last || last > now) last = now
		# Duplicate MAC rows can be left by older versions; newest wins.
		if ((mac in e_last) && e_last[mac] > last) continue
		e_first[mac] = number_field(s, "first_seen")
		e_last[mac] = last
		e_off[mac] = number_field(s, "offline_at")
		e_host[mac] = text_field(s, "host")
		e_ip[mac] = text_field(s, "ip")
		e_via[mac] = text_field(s, "via")
		e_port[mac] = text_field(s, "port")
		e_os[mac] = text_field(s, "os")
		all_macs[mac] = 1
	}

	n = split(dhcp, lines, "\n")
	for (i = 1; i <= n; i++) {
		split(lines[i], a, "|")
		mac = mac_key(a[1])
		if (!mac) continue
		d_ip[mac] = a[2]
		if (a[3] != "*" && a[3] != "") d_host[mac] = a[3]
	}

	n = split(active, lines, "\n")
	for (i = 1; i <= n; i++) {
		split(lines[i], a, "|")
		mac = mac_key(a[1])
		if (!mac) continue
		active_mac[mac] = all_macs[mac] = 1
		if (a[2] != "-" && a[2] != "") {
			# Prefer IPv4 over IPv6, and a currently observed DHCP address
			# over another address belonging to the same MAC.
			if (!(mac in a_ip) || (ipv4(a[2]) && (!ipv4(a_ip[mac]) || a[2] == d_ip[mac])))
				a_ip[mac] = a[2]
			if (!(a[2] in observed_owner)) observed_owner[a[2]] = mac
			else if (observed_owner[a[2]] != mac) observed_owner[a[2]] = "conflict"
		}
		if (!(mac in a_via) || a[3] ~ /^wifi/) a_via[mac] = a[3]
		if (a[4] != "") a_sig[mac] = a[4]
	}
	for (mac in active_mac) {
		ip = (mac in a_ip) ? a_ip[mac] : ((mac in d_ip) ? d_ip[mac] : e_ip[mac])
		# A WiFi association proves the MAC is online, but its old DHCP
		# address may now belong to someone else. Keep both online MACs.
		if (!(mac in a_ip) && (ip in observed_owner) && observed_owner[ip] != mac && observed_owner[ip] != "conflict") ip = ""
		current_ip[mac] = ip
		if (ip != "") online_ip[ip] = 1
	}

	n = split(port_data, lines, "\n")
	for (i = 1; i <= n; i++) {
		split(lines[i], a, "|")
		mac = mac_key(a[1])
		if (mac) port_of[mac] = a[2]
	}
	n = split(fp, lines, "\n")
	for (i = 1; i <= n; i++) {
		split(lines[i], a, "|")
		mac = mac_key(a[1])
		if (mac && a[2] != "" && a[2] != "unknown") f_os[mac] = a[2]
	}

	printf("{\"updated\":%d,\"offline_retention\":%d,\"wan\":%s,\"clients\":[", now, retention, wan_json)
	first_entry = 1
	for (mac in all_macs) {
		online = (mac in active_mac)
		ip = online ? current_ip[mac] : ((mac in d_ip) ? d_ip[mac] : e_ip[mac])
		last = online ? now : e_last[mac]
		# Expire on every scan; leases and plugin history cannot refresh
		# last_seen or recreate a device after this deadline.
		if (!online && (now - last >= retention || (ip != "" && (ip in online_ip)))) continue
		first = e_first[mac]
		if (!first || first > now || (online && e_off[mac] > 0)) first = now
		off = online ? 0 : e_off[mac]
		if (!online && (!off || off > now)) off = last
		host = (mac in d_host) ? d_host[mac] : e_host[mac]
		gsub(/[\\"]/, "", host)
		gsub(/[[:cntrl:]]/, "", host)
		via = online ? a_via[mac] : e_via[mac]
		port = (mac in port_of) ? port_of[mac] : e_port[mac]
		os = (mac in f_os) ? f_os[mac] : e_os[mac]
		if (!first_entry) printf(",")
		first_entry = 0
		printf("{\"mac\":\"%s\",\"ip\":\"%s\",\"host\":\"%s\",\"via\":\"%s\",\"port\":\"%s\",\"online\":%s,\"first_seen\":%d,\"last_seen\":%d,\"offline_at\":%d,\"signal\":\"%s\",\"os\":\"%s\"}", mac, ip, host, via, port, (online ? "true" : "false"), first, last, off, a_sig[mac], os)
	}
	printf("]}\n")
}
