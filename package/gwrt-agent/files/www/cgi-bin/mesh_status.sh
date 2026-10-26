#!/bin/sh
# Mesh 组网状态 CGI —— 为 /mesh.html 提供 JSON
# 数据来源: mesh11sd + ubus + iw（mesh 接口 mpath/station dump）
echo "Content-Type: application/json"
echo ""

HOSTNAME="$(uci get system.@system[0].hostname 2>/dev/null)"

# 节点角色：Portal(主) / Peer(从)。mesh11sd 运行期写入 /tmp/mesh11sd/is_portal
PORTAL="false"
if [ -f /tmp/mesh11sd/is_portal ]; then
	. /tmp/mesh11sd/is_portal 2>/dev/null
	[ -n "$is_portal" ] && PORTAL="true"
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
PEER_MACS="$(for IF in $MESHIFS; do iw dev "$IF" mpath dump 2>/dev/null; done | awk 'NR>1 {print $1}' | sort -u)"

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
	LAST="$NOW"
	if [ -n "$ct" ]; then LAST=$((NOW - ct)); fi
	[ -n "$sig" ] && SIG=",\"rssi\":$sig" || SIG=",\"rssi\":null"
	[ -z "$plink" ] && plink="-"
	count=$((count+1))
	PEERS_JSON="${PEERS_JSON}{\"mac\":\"$MAC\",\"last_seen\":$LAST$SIG,\"plink_state\":\"$plink\"},"
done
PEERS_JSON="${PEERS_JSON%,}"

printf '{"version":"%s","hostname":"%s","portal":%s,"host_ipv4":"%s","host_ipv6":"%s","active_node_count":%d,"system_time":"%s","peers":[%s]}\n' \
	"$VERSION" "$HOSTNAME" "$PORTAL" "$IP4" "$IP6" "$count" "$STIME" "$PEERS_JSON"
