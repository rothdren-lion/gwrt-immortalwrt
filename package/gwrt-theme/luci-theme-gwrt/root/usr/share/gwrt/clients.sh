#!/bin/sh
umask 077
# GWRT clients tracker — 持久化接入设备状态
#
# 用法:
#   clients.sh scan        # 扫一次 ARP+assoclist, 更新内存状态 + 必要时 flush JSON
#   clients.sh daemon      # 后台循环扫描 (init.d 用)
#   clients.sh cleanup-daily  # 兼容午夜 cron, 仅保存快照（离线每轮自动回收）
#   clients.sh dump        # 输出当前 JSON (供前端 ubus 调用 / 调试)
#
# 数据存档: /etc/gwrt/clients.json
# 内存运行档: /tmp/gwrt-theme/clients.json (高频更新避免伤 flash)
#
# JSON 格式:
# {
#   "updated": 1782480000,
#   "clients": [
#     {"mac":"aa:bb..","ip":"192.168.10.5","host":"phone","via":"wifi5g",
#      "online":true,"first_seen":1782470000,"last_seen":1782480000,"signal":-42}
#   ]
# }

. /lib/functions.sh 2>/dev/null

PERSIST=/etc/gwrt/clients.json
WWWLINK=/www/gwrt-clients.json
if [ -L "$WWWLINK" ] || { [ -e "$WWWLINK" ] && [ ! -d "$WWWLINK" ]; }; then
	rm -f "$WWWLINK"
fi
RUNTIME_DIR=$(/usr/libexec/gwrt-runtime-dir) || exit 1
RUNTIME=$RUNTIME_DIR/clients.json
PERSIST_DIR=/etc/gwrt
FLUSH_INTERVAL=300   # 5min flush to flash
OFFLINE_RETENTION=86400 # 24h since last actual observation
MERGER=/usr/share/gwrt/clients-merge.awk
SCAN_INTERVAL=10     # 10s scan tick for current client status

mkdir -p "$PERSIST_DIR"

resolve_lan_device() {
	local dev
	dev=$(ubus call network.interface status '{"interface":"lan"}' 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null | head -n 1)
	[ -n "$dev" ] || dev=$(uci -q get network.lan.device 2>/dev/null)
	case "$dev" in
		''|*[!A-Za-z0-9_.:-]*) dev=br-lan ;;
	esac
	printf '%s\n' "$dev"
}

# 把 RUNTIME 不存在/损坏时从 PERSIST 恢复 (重启场景)
ensure_runtime() {
	if [ ! -s "$RUNTIME" ] || ! jsonfilter -i "$RUNTIME" -e '@.updated' >/dev/null 2>&1; then
		if [ -s "$PERSIST" ] && jsonfilter -i "$PERSIST" -e '@.updated' >/dev/null 2>&1; then
			cp "$PERSIST" "$RUNTIME"
		else
			echo '{"updated":0,"clients":[]}' > "$RUNTIME"
		fi
	fi
}

# 先探测 LAN 桥上的 STALE 邻居，再用邻居状态与 WiFi assoclist 判断在线。
# STALE 只表示近期未确认，不能直接当作在线；探测让仍在线的设备回到活跃状态。
probe_stale_neighbors() {
	local addr pid pids="" lan_dev
	lan_dev=$(resolve_lan_device)
	for addr in $(ip -4 neigh show dev "$lan_dev" nud stale 2>/dev/null | awk '{print $1}' | head -n 32); do
		ping -4 -q -c 1 -W 1 "$addr" >/dev/null 2>&1 &
		pids="$pids $!"
	done
	for addr in $(ip -6 neigh show dev "$lan_dev" nud stale 2>/dev/null | awk '{print $1}' | head -n 32); do
		ping -6 -q -c 1 -W 1 "$addr" >/dev/null 2>&1 &
		pids="$pids $!"
	done
	for pid in $pids; do wait "$pid" 2>/dev/null; done
}

# 当前活跃 MAC 集合 = LAN 邻居 REACHABLE/DELAY/PROBE + WiFi assoclist
#
# ⚠️ 本固件没有 iwinfo CLI（只装了 libiwinfo + rpcd-mod-iwinfo），
# 所以 WiFi 必须走 ubus：
#   ubus call iwinfo info      '{"device":"phy0-ap0"}'   → frequency / mode
#   ubus call iwinfo assoclist '{"device":"phy0-ap0"}'   → results[].mac / signal
# 旧实现用 `iwinfo "$phy" info|assoclist`，命令不存在导致 WiFi 段静默全失败，
# 无线客户端只能被 ARP 分支兜底标成 wired —— 这就是 via 列看不到 WiFi 的根因。
collect_active() {
	local lan_dev
	lan_dev=$(resolve_lan_device)
	probe_stale_neighbors
	# 只检查 LAN 桥；STALE 已主动探测，等设备回应或进入 FAILED。
	ip neigh show dev "$lan_dev" 2>/dev/null | awk '
		/lladdr/ && /(REACHABLE|DELAY|PROBE)/ && !/FAILED/ {
			ip=$1; mac=""; for(i=1;i<=NF;i++) if($i=="lladdr") mac=$(i+1)
			if (mac && ip !~ /^(fe80|ff)/) print tolower(mac)"|"ip"|wired"
		}'

	# WiFi: 遍历 hostapd interface（经 ubus，不依赖 iwinfo CLI）
	for phy in $(ubus list 'hostapd.*' 2>/dev/null | cut -d. -f2); do
		[ -z "$phy" ] && continue

		# 频段判定：用 frequency(MHz) 换算，比解析 iwinfo 文案更可靠
		# 5G 再细分：5150-5350=5.2G(5gl)，5470-5895=5.8G(5gh)
		info=$(ubus call iwinfo info "{\"device\":\"$phy\"}" 2>/dev/null)
		freq=$(printf '%s' "$info" | jsonfilter -e '@.frequency' 2>/dev/null)
		case "$freq" in ''|*[!0-9]*) freq=0 ;; esac
		if   [ "$freq" -ge 5925 ] 2>/dev/null; then tag="wifi6g"
		elif [ "$freq" -ge 5470 ] 2>/dev/null; then tag="wifi5gh"
		elif [ "$freq" -ge 4900 ] 2>/dev/null; then tag="wifi5gl"
		elif [ "$freq" -ge 2400 ] 2>/dev/null; then tag="wifi24g"
		else
			tag="wifi"
			# 频率取不到时退回接口名约定 (双 5G 设备 re-cs-02: phy0=5.2G, phy2/3=5.8G)
			case "$phy" in *phy2*|*phy3*) tag="wifi5gh" ;; esac
		fi

		ubus call iwinfo assoclist "{\"device\":\"$phy\"}" 2>/dev/null | awk -v t="$tag" -v iface="$phy" '
			# 注意：ubus JSON 里 "mac" 与 "signal" 分处两行，不能在同一行内取值，
			# 否则 signal 永远为空。用下标数组按条目配对，END 再输出。
			$1 == "\"mac\":"    { v=$2; gsub(/[",]/, "", v); n++; mac[n]=tolower(v) }
			$1 == "\"signal\":" { v=$2; gsub(/[",]/, "", v); sig[n]=v }
			END {
				for (i = 1; i <= n; i++)
					if (length(mac[i]) == 17 && mac[i] ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])+$/)
						# ip 用 - 占位，最后一段保留当前关联接口，优先于旧 FDB。
						print mac[i]"|-|"t"|"sig[i]"|"iface
			}'
	done
}

# === WAN 信息采集 (ISP 检测 / 光猫 / 上级路由) ===
collect_wan_info() {
	local def_route gateway iface wan_ip wan_type is_private gw_reachable
	local isp="未知" is_combo="false" lan_dev
	lan_dev=$(resolve_lan_device)
	def_route=$(ip route show default 2>/dev/null)
	# `ip route` emits both "default via GW dev IF" and
	# "default dev IF" (common for PPPoE).  Fixed field positions make the
	# latter report `scope` as the interface and lose WAN type/IP metadata.
	local route_parts
	route_parts=$(printf '%s\n' "$def_route" | awk '
		$1 == "default" {
			gw=""; dev=""
			for (i = 1; i <= NF; i++) {
				if ($i == "via" && i < NF) gw=$(i + 1)
				if ($i == "dev" && i < NF) dev=$(i + 1)
			}
			print gw "|" dev
			exit
		}')
	gateway=${route_parts%%|*}
	iface=${route_parts#*|}
	wan_ip=""; wan_type="none"; is_private="false"; gw_reachable="false"

	if [ -n "$iface" ]; then
		case "$iface" in
			pppoe-*) wan_type="pppoe" ;;
			*)       wan_type="dhcp"  ;;
		esac
		wan_ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

		case "$wan_ip" in
			10.*|172.1[6-9]*|172.2[0-9]*|172.3[0-1]*|192.168.*)
				is_private="true"
				wan_type="dhcp"
				;;
		esac

		ping -c 1 -W 1 "$gateway" >/dev/null 2>&1 && gw_reachable="true"

		# ── ISP 检测 ──
		# 1) PPPoE AC name (AC 名常含 ISP 标识)
		if [ "$wan_type" = "pppoe" ]; then
			local ac_name
			ac_name=$(cat /proc/net/pppoe 2>/dev/null | head -1 | awk '{print $1}')
			case "$ac_name" in
				*CT*|*CHINANET*|*CHINATELECOM*) isp="电信" ;;
				*CU*|*UNICOM*|*CNC*)            isp="联通" ;;
				*CM*|*CMCC*|*CHINAMOBILE*)      isp="移动" ;;
			esac
		fi

		# 2) DNS 服务器 IP 匹配
		if [ "$isp" = "未知" ]; then
			local dns_servers
			dns_servers=$(awk '/^nameserver/{print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | tr '\n' ' ')
			for dns in $dns_servers; do
				case "$dns" in
					114.114.*|180.76.*|1.2.4.*|210.22.*|218.*) isp="电信"; break ;;
					123.123.*|124.124.*|210.21.*)               isp="联通"; break ;;
					211.136.*|221.130.*|120.196.*|211.137.*)    isp="移动"; break ;;
				esac
			done
		fi

		# 3) 网关 IP 范围兜底
		if [ "$isp" = "未知" ] && [ -n "$gateway" ]; then
			local gw_octet
			gw_octet=$(echo "$gateway" | cut -d. -f1)
			case "$gw_octet" in
				61|116|180|183|218|219|222) isp="电信" ;;
				60|124|210)                 isp="联通" ;;
				111|112|117|211|223)        isp="移动" ;;
			esac
		fi

		# 猫路由一体: 私有 IP 或 PPPoE 猫路由合一场景
		[ "$is_private" = "true" ] && is_combo="true"
	fi

	# ── 桥接成员 (物理 LAN 口 + WiFi radio) ──
	local bridge_members="[]"
	local br_json
	br_json=$(ubus call network.device status "{\"name\":\"$lan_dev\"}" 2>/dev/null)
	if [ -n "$br_json" ]; then
		bridge_members=$(echo "$br_json" | jsonfilter -e '@["bridge-members"]' 2>/dev/null)
		[ -z "$bridge_members" ] && bridge_members="[]"
	fi

	printf '{"type":"%s","ip":"%s","gateway":"%s","gateway_reachable":%s,"is_private":%s,"isp":"%s","is_combo":%s,"bridge_members":%s}' \
		"$wan_type" "${wan_ip:-}" "${gateway:-}" "$gw_reachable" "$is_private" "$isp" "$is_combo" "$bridge_members"
}

# === 端口指纹（后台异步探测，结果缓存在私有运行目录: mac|os） ===
# 用途：DHCP option 指纹拿不到时，用设备开放端口推断系统（如 fnOS 的 5666/5667）。
# 设计：探测在后台跑（每个 MAC 只探一次并缓存），不阻塞 30s 扫描节拍。
probe_ports_async() {
	local active="$1"
	local cache="$RUNTIME_DIR/portfp.list" out="$RUNTIME_DIR/portfp.lock"
	[ -f "$cache" ] || : > "$cache"
	if [ -f "$out" ]; then
		# A killed probe must not disable fingerprinting forever.  Normal
		# probes finish in under a minute; reclaim an orphaned lock after 90s.
		local started now age
		started=$(cat "$out" 2>/dev/null)
		now=$(date +%s)
		case "$started" in *[!0-9]*|"") age=999999 ;; *) age=$((now - started)) ;; esac
		[ "$age" -lt 90 ] && return 0
		rm -f "$out"
	fi
	printf '%s\n' "$(date +%s)" > "$out"
	(
		n=0
		printf '%s\n' "$active" | while IFS='|' read -r mac ip via sig; do
			[ -n "$mac" ] || continue
			[ -n "$ip" ] && [ "$ip" != "-" ] || continue
			grep -q "^$mac|" "$cache" 2>/dev/null && continue
			n=$((n+1)); [ "$n" -gt 6 ] && break
			os=""
			if nc -z -w 1 "$ip" 5666 2>/dev/null || nc -z -w 1 "$ip" 5667 2>/dev/null; then
				os=fnos                       # fnOS Web UI
			else
				# SSH banner 在认证前明文返回，无需密码，可直接读出发行版
				banner=$(nc -w 2 "$ip" 22 </dev/null 2>/dev/null | head -c 160)
				lb=$(printf '%s' "$banner" | tr 'A-Z' 'a-z')
				case "$lb" in
					*ubuntu*) os=ubuntu ;;
					*ssh-*)   os=linux  ;;
				esac
			fi
			printf '%s|%s\n' "$mac" "$os" >> "$cache"
		done
		rm -f "$out"
	) >/dev/null 2>&1 &
}

# === scan 模式: 扫描一次,更新 RUNTIME ===
do_scan() {
	ensure_runtime

	local now=$(date +%s)
	local active_list wan_info
	active_list=$(collect_active)
	wan_info=$(collect_wan_info)

	# DHCP is metadata only; an unexpired lease does not prove presence.
	local dhcp_data=""
	[ -r /tmp/dhcp.leases ] && dhcp_data=$(awk -v now="$now" '$1 == 0 || $1 > now {print tolower($2)"|"$3"|"$4}' /tmp/dhcp.leases)

	# DHCP 指纹 (option 60/55, dnsmasq dhcp-script 写入): mac|os|vendor|options
	local fp_data=""
	[ -r "$RUNTIME_DIR/dhcp-fp.list" ] && fp_data=$(cat "$RUNTIME_DIR/dhcp-fp.list")

	# 端口指纹（fnOS 5666/5667）：异步探测 + 缓存，只补 DHCP 未识别的
	probe_ports_async "$active_list"
	local portfp_data=""
	[ -r "$RUNTIME_DIR/portfp.list" ] && portfp_data=$(cat "$RUNTIME_DIR/portfp.list")
	local fp_clean fp_combined
	fp_clean=$(printf '%s\n' "$fp_data" | grep -v '|unknown|')
	# 端口在前、DHCP 在后：同 MAC 时 DHCP 覆盖端口推断
	fp_combined=$(printf '%s\n%s\n' "$portfp_data" "$fp_clean")

	# ── 桥端口映射 (mac → 物理端口名) ──
	local bridge_port_data="" lan_dev
	lan_dev=$(resolve_lan_device)
	if command -v brctl >/dev/null 2>&1 && [ -d "/sys/class/net/$lan_dev/brif" ]; then
		# 端口编号(hex)→ decimal → 接口名 (用 shell 转换)
		local pmap_dec=""
		for f in "/sys/class/net/$lan_dev/brif/"*; do
			local iface=$(basename "$f")
			local pn=$(cat "$f/port_no" 2>/dev/null)
			[ -n "$pn" ] && pn_dec=$((pn)) 2>/dev/null && pmap_dec="${pmap_dec}${pn_dec}|${iface}\n"
		done
		bridge_port_data=$(brctl showmacs "$lan_dev" 2>/dev/null | awk -v pm="$pmap_dec" '
			BEGIN {
				n = split(pm, plines, /\n/)
				for (i = 1; i <= n; i++) {
					split(plines[i], a, "|")
					if (a[1]) pmap[a[1]] = a[2]
				}
			}
			/^[[:space:]]*[0-9]+[[:space:]]/ && !/yes/ {
				mac = tolower($2); port_no = $1 + 0  # 强转 numeric
				if (pmap[port_no]) print mac"|"pmap[port_no]
			}')
	fi

	# MAC identity, IP ownership and the 24h offline deadline are resolved
	# together. The same policy also migrates old caches on the first scan.
	local merged
	merged=$(awk -v now="$now" -v retention="$OFFLINE_RETENTION" \
		-v state_file="$RUNTIME" -v active="$active_list" -v dhcp="$dhcp_data" \
		-v fp="$fp_combined" -v wan_json="$wan_info" -v port_data="$bridge_port_data" \
		-f "$MERGER") || return 1
	[ -n "$merged" ] || return 1

		# 写 RUNTIME
	echo "$merged" > "$RUNTIME.$$"
	mv "$RUNTIME.$$" "$RUNTIME"
}

# === flush 模式: 把 RUNTIME 写到 PERSIST (5分钟一次,有 diff 才写) ===
do_flush() {
	[ ! -s "$RUNTIME" ] && return
	# 用 mtime 判断: 上次 flush 时间记录在私有运行目录
	local last_flush=0
	[ -r "$RUNTIME_DIR/clients.flushed" ] && last_flush=$(cat "$RUNTIME_DIR/clients.flushed")
	local now=$(date +%s)
	local gap=$((now - last_flush))
	[ "$gap" -lt "$FLUSH_INTERVAL" ] && return

	# diff 检测: updated 每 10 秒变化，不能把它纳入 hash；否则即使
	# 客户端和 WAN 数据没有变化，也会每 5 分钟写一次 flash。
	local rsum psum
	rsum=$(sed 's/"updated":[0-9]*,//' "$RUNTIME" 2>/dev/null | sha256sum | awk '{print $1}')
	psum=$(sed 's/"updated":[0-9]*,//' "$PERSIST" 2>/dev/null | sha256sum | awk '{print $1}')
	if [ "$rsum" != "$psum" ]; then
		cp "$RUNTIME" "$PERSIST"
		echo "$now" > "$RUNTIME_DIR/clients.flushed"
	fi
}

# === cleanup-daily: legacy cron entry; scans already expire offline clients ===
do_cleanup_daily() {
	# Preserve connection start times and WAN metadata. The daemon performs
	# expiry every scan; cron only persists its latest complete snapshot.
	do_flush
}

# === dump: 输出当前 JSON ===
do_dump() {
	ensure_runtime
	cat "$RUNTIME"
}

# === daemon: 后台循环 ===
do_daemon() {
	# 启动时从 PERSIST 恢复
	ensure_runtime
	while :; do
		do_scan
		do_flush
		sleep "$SCAN_INTERVAL"
	done
}

case "$1" in
	scan)           do_scan ;;
	flush)          do_flush ;;
	cleanup-daily)  do_cleanup_daily ;;
	dump)           do_dump ;;
	daemon)         do_daemon ;;
	*)
		echo "Usage: $0 {scan|flush|cleanup-daily|dump|daemon}" >&2
		exit 1
		;;
esac
