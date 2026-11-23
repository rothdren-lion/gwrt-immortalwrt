#!/bin/sh
# Mesh 组网状态 CGI —— 为 /mesh.html 提供 JSON
# 数据来源: mesh11sd + ubus + iw（mesh 接口 mpath/station dump）
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

HOSTNAME="$(uci get system.@system[0].hostname 2>/dev/null)"
JSON_HELPER=/usr/share/gwrt-agent/json.uc

# Modern GWRT uses wifiroam, not the older mesh11sd station table.
STATUS="$(ubus -t 3 call wifiroam status 2>/dev/null)"
ROLE="$(printf '%s' "$STATUS" | jsonfilter -e '@.role' 2>/dev/null)"
case "$ROLE" in
cap|sap|unconfigured)
	LAN="$(ubus -t 3 call network.interface.lan status 2>/dev/null)"
	IP4="$(printf '%s' "$LAN" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
	IP6="$(printf '%s' "$LAN" | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null)"
	APMODE=0; [ -f /etc/gwrt-apmode.state ] && APMODE=1
	TMP="$(mktemp -d /tmp/gwrt-mesh-status.XXXXXX)" || { echo '{"available":false}'; exit 1; }
	trap 'rm -rf "$TMP"' EXIT
	ubus -t 3 call wifiroam discover >"$TMP/discover" 2>/dev/null
	ubus -t 3 call wifiroam topology >"$TMP/topology" 2>/dev/null
	ucode "$JSON_HELPER" mesh-status "$STATUS" "@$TMP/discover" "@$TMP/topology" "$APMODE" \
		"$IP4" "$IP6" "$(date '+%Y-%m-%d %H:%M:%S')"
	exit $?
	;;
esac

# 节点角色：Portal(主) / Peer(从)。mesh11sd 运行期写入 /tmp/mesh11sd/is_portal
PORTAL="false"
if [ -f /tmp/mesh11sd/is_portal ]; then
	value="$(tr -d '\042\047 \011\015' < /tmp/mesh11sd/is_portal | sed -n 's/^is_portal=//p')"
	case "$value" in 1|true|yes) PORTAL=true;; esac
fi

# IPv4 / IPv6（LAN 主地址；LAN 无 IPv6 时退回 wan6）
LAN="$(ubus call network.interface.lan status 2>/dev/null)"
IP4="$(echo "$LAN" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
IP6="$(echo "$LAN" | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null)"
[ -z "$IP6" ] && IP6="$(ubus call network.interface.wan6 status 2>/dev/null | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null)"

NOW="$(date +%s)"
STIME="$(date '+%Y-%m-%d %H:%M:%S')"

# mesh11sd 版本
RAW="$(mesh11sd status mesh 2>/dev/null)"
VERSION="$(echo "$RAW" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"

# mesh 类型接口列表
MESHIFS="$(iw dev 2>/dev/null | awk '/Interface/{i=$2} /type mesh/{print i}')"

# station 信息: mac|signal|plink|connected_seconds
STAMAP="$(for IF in $MESHIFS; do iw dev "$IF" station dump 2>/dev/null; done | awk '
/^Station / { mac=$2; sig=""; plink=""; ct=""; next }
/signal:/ { if (mac != "") sig=$2 }
/plink:/ { if (mac != "") plink=$3 }
/connected time:/ { if (mac != "") ct=$3 }
/^$/ { if (mac != "") { print mac"|"sig"|"plink"|"ct; mac="" } }
END { if (mac != "") print mac"|"sig"|"plink"|"ct }')"

# 对端 MAC（mpath dump 去重）
PEER_MACS="$(for IF in $MESHIFS; do iw dev "$IF" mpath dump 2>/dev/null; done | awk '$1 ~ /^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$/ {print $1}' | sort -u)"

count=0
PEERS_JSON=""
for MAC in $PEER_MACS; do
	sig=""; plink=""; ct=""
	LINE="$(echo "$STAMAP" | grep "^$MAC|")"
	if [ -n "$LINE" ]; then
		sig="$(echo "$LINE" | cut -d'|' -f2)"
		plink="$(echo "$LINE" | cut -d'|' -f3)"
		ct="$(echo "$LINE" | cut -d'|' -f4)"
	fi
	# 只保留合法数值，避免 JSON 注入
	case "$sig" in ''|*[!0-9-]*) sig="";; esac
	case "$ct" in ''|*[!0-9]*) ct="";; esac
	LAST=0
	[ -n "$sig" ] && LAST="$NOW"
	[ -n "$sig" ] && SIG=",\"rssi\":$sig" || SIG=",\"rssi\":null"
	[ -z "$plink" ] && plink="-"
	[ -n "$sig" ] && count=$((count+1))
	PEERS_JSON="${PEERS_JSON}{\"mac\":\"$MAC\",\"last_seen\":$LAST$SIG,\"plink_state\":\"$(ucode "$JSON_HELPER" quote "$plink")\"},"
done
PEERS_JSON="${PEERS_JSON%,}"

printf '{"version":"%s","hostname":"%s","portal":%s,"host_ipv4":"%s","host_ipv6":"%s","active_node_count":%d,"system_time":"%s","peers":[%s]}\n' \
	"$(ucode "$JSON_HELPER" quote "$VERSION")" "$(ucode "$JSON_HELPER" quote "$HOSTNAME")" "$PORTAL" "$IP4" "$IP6" "$count" "$STIME" "$PEERS_JSON"
