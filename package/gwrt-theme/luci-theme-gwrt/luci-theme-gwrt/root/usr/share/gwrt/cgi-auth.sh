#!/bin/sh
# CGI bypasses uhttpd's ubus ACL check, so check the caller's rpcd access group.
gwrt_cgi_authorize() {
	local sid="$1" group="$2" permission="$3" result access
	[ "${#sid}" -eq 32 ] || return 1
	case "$sid" in
		*[!0-9a-fA-F]*|00000000000000000000000000000000) return 1 ;;
	esac
	result=$(ubus call session access "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"access-group\",\"object\":\"$group\",\"function\":\"$permission\"}" 2>/dev/null) || return 1
	access=$(printf '%s' "$result" | jsonfilter -e '@.access' 2>/dev/null)
	case "$access" in true|1) return 0 ;; *) return 1 ;; esac
}
