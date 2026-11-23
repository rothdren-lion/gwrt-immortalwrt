#!/bin/sh
# gwrt-verify.sh — GWRT / jdcloud_re-ss-01 交付自检
#
# 起因（2026-10-15 真机 261011-08）：
#   编译机上验镜像一切正常（kmod-ath11k-ahb 在、modules.d/ath11k-ahb 在、DTB 正确），
#   但刷进机器后 /rom 里唯独少了 ath11k_ahb.ko → ath11k_ahb 永远不加载 →
#   没有 phy → /sbin/wifi config 生成不出配置 → /etc/config/wireless 为空 → 无线全灭。
#   之前的"三重验证"只验到镜像就收工，正好漏掉了这一环。
#
# 所以这里提供两种模式：
#   image  <sysupgrade.bin>   验刚编出来的镜像
#   device [host]             验真机（默认 root@192.168.3.3）
#
# 任何 FAIL 都返回非 0。
#
# 用法：
#   GWRT_WORKDIR=/大空间目录 ./gwrt-verify.sh image <sysupgrade.bin>
#   ./gwrt-verify.sh device 192.168.3.3
#   ./gwrt-verify.sh device                 # 默认 192.168.3.3
#
# 注意：解包一个 sysupgrade 需要 ~1G 临时空间。默认写 /tmp，而 /tmp 常常是
# 容量很小的 tmpfs（2026-10-15 实测 7.8G 里已用 5.2G，只剩 2.7G，
# unsquashfs 会直接 "Disk quota exceeded" FATAL）。
# 请用 GWRT_WORKDIR 指到空间充足的地方。

set -u

BOARD=jdcloud_re-ss-01
DEFAULT_LAN_IP=192.168.3.3
EXPECT_CH5G=149
NEED_MB=1200

FAIL=0
WARN=0

ok()   { printf '[ OK ] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '[WARN] %s\n' "$1"; WARN=$((WARN + 1)); }
info() { printf '[INFO] %s\n' "$1"; }

hdr() {
	printf '\n===== %s =====\n' "$1"
}

# ---------------------------------------------------------------- image 模式

verify_image() {
	bin="$1"
	[ -f "$bin" ] || { fail "镜像不存在: $bin"; return 1; }

	tmp=$(mktemp -d "${GWRT_WORKDIR:-/tmp}/gwrt-verify.XXXXXX") \
		|| { fail "建临时目录失败（试试 GWRT_WORKDIR=/大空间目录）"; return 1; }
	trap 'rm -rf "$tmp"' EXIT

	avail_mb=$(df -Pm "$tmp" 2>/dev/null | awk 'NR==2 {print $4}')
	if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$NEED_MB" ]; then
		fail "$tmp 只剩 ${avail_mb}MB，解包需要约 ${NEED_MB}MB"
		info "用 GWRT_WORKDIR=/空间大的目录 重跑，例如 GWRT_WORKDIR=$PWD"
		return 1
	fi
	ok "临时目录 $tmp（可用 ${avail_mb:-?}MB）"

	hdr "解包"
	tar xf "$bin" -C "$tmp" 2>/dev/null || { fail "tar 解包失败"; return 1; }
	root=$(find "$tmp" -name root -type f | head -1)
	[ -n "$root" ] || { fail "sysupgrade tar 里没有 root（squashfs）"; return 1; }
	ok "sysupgrade 结构正常"

	sf="$tmp/squashfs"
	# 不要拿 unsquashfs 的退出码当成功与否：本项目的镜像解包会返回 2（有 warning），
	# 但内容其实是完整的。改成"解完后按内容判定"。
	if ! unsquashfs -d "$sf" "$root" >"$tmp/un.log" 2>&1; then
		if [ ! -d "$sf/etc" ]; then
			fail "squashfs 解包失败: $(tail -2 "$tmp/un.log" | tr '\n' ' ')"
			return 1
		fi
		wmsg=$(grep -iE 'fail|error|quota' "$tmp/un.log" | head -1)
		warn "unsquashfs 返回非 0 但内容已解出${wmsg:+（$wmsg）}"
	fi
	[ -d "$sf/etc" ] || { fail "解包后连 etc 都没有，rootfs 是坏的"; return 1; }
	ok "rootfs 解包完成（$(find "$sf" -type f | wc -l) 个文件）"

	# ---- 固件本体 ----
	hdr "固件 / rootfs 内容"
	for f in \
		"lib/modules/6.18.55/ath11k.ko" \
		"lib/modules/6.18.55/ath11k_ahb.ko" \
		"lib/modules/6.18.55/cfg80211.ko" \
		"lib/modules/6.18.55/mac80211.ko"
	do
		if [ -f "$sf/$f" ]; then
			ok "$f ($(wc -c < "$sf/$f") B)"
		else
			fail "$f 缺失 —— 无线必灭（kmod-ath11k-ahb 没打进去？）"
		fi
	done

	# ath11k_ahb 是 -08 上 WiFi 全灭的直接原因，单独再确认一次模块登记
	if [ -f "$sf/etc/modules.d/ath11k-ahb" ]; then
		ok "/etc/modules.d/ath11k-ahb 存在 ($(cat "$sf/etc/modules.d/ath11k-ahb"))"
	else
		fail "/etc/modules.d/ath11k-ahb 缺失 —— kmodloader 不会加载 ath11k_ahb"
	fi

	# ---- 模块索引 ----
	# 本项目所有镜像都缺 modules.dep/alias/order/symbols（见 2026-10-15 审计）。
	# procd kmodloader 不依赖它们，但独立调用 modprobe/modinfo 会失败。
	if [ -f "$sf/lib/modules/6.18.55/modules.dep" ]; then
		ok "modules.dep 存在"
	else
		warn "modules.dep 不存在（历史遗留；kmodloader 可用，但 modprobe/modinfo 直接调用会失败）"
	fi

	# ---- 固件文件 ----
	hdr "ath11k 固件"
	for f in \
		"lib/firmware/ath11k/IPQ6018/hw1.0/board-2.bin" \
		"lib/firmware/IPQ6018/board-2.bin" \
		"lib/firmware/IPQ6018/q6_fw.b03"
	do
		[ -f "$sf/$f" ] && ok "$f" || fail "$f 缺失"
	done
	if [ -f "$sf/lib/firmware/ath11k/IPQ6018/hw1.0/cal-ahb-c000000.wifi.bin" ]; then
		ok "cal-ahb 已预置"
	else
		info "cal-ahb-*.wifi.bin 不在镜像内（正常：首启由 hotplug 从 0:ART 提取到 overlay）"
	fi

	# ---- uci-defaults ----
	hdr "首启脚本"
	for f in 34_gwrt-autostart-policy 38_gwrt-wifi-channel 39_gwrt-wifi-firstboot; do
		[ -f "$sf/etc/uci-defaults/$f" ] && ok "/etc/uci-defaults/$f" || fail "/etc/uci-defaults/$f 缺失"
	done
	# 38 被 39 用 -f 引用；若仍是 0644 则旧的 -x 判断就是死代码
	if [ -f "$sf/etc/uci-defaults/39_gwrt-wifi-firstboot" ]; then
		if grep -q '\[ -x /etc/uci-defaults/38_gwrt-wifi-channel \]' \
			"$sf/etc/uci-defaults/39_gwrt-wifi-firstboot"; then
			fail "39 仍用 -x 判 38 存在 —— 38 是 0644，这段兜底恒不生效"
		else
			ok "39 对 38 的存在性判断没有 -x 死代码"
		fi
		if grep -q 'no phy can appear' "$sf/etc/uci-defaults/39_gwrt-wifi-firstboot"; then
			ok "39 含缺模块的显式诊断"
		else
			warn "39 没有 kmod-ath11k-ahb 缺失的显式诊断（排查无线问题会很痛苦）"
		fi
	fi
	[ -f "$sf/etc/board.d/99-lan-ip" ] && ok "/etc/board.d/99-lan-ip" || fail "99-lan-ip 缺失"

	# ---- gwrt-agent ----
	hdr "gwrt-agent"
	ag="$sf/usr/sbin/gwrt-agent"
	[ -f "$ag" ] || { fail "gwrt-agent 缺失"; }
	if [ -f "$ag" ]; then
		# 行为测试（261021-01 教训：字面量 grep 会随实现升级误报/漏报）。
		# 从脚本里抽出 sed 表达式，对 hardware_id 在 中间/末尾/开头 三种位置各跑一遍，
		# 期望都产出合法 JSON（逗号既不缺也不多）。
		ag_sed=$(sed -n "s/.*| sed '\(.*\)'.*/\1/p" "$ag" | head -1)
		if [ -n "$ag_sed" ]; then
			t1=$(printf '%s' '{"a":1,"hardware_id":"HW-x","b":2}' | sed "$ag_sed")
			t2=$(printf '%s' '{"a":1,"hardware_id":"HW-x"}' | sed "$ag_sed")
			t3=$(printf '%s' '{"hardware_id":"HW-x","a":1}' | sed "$ag_sed")
			if [ "$t1" = '{"a":1,"b":2}' ] && [ "$t2" = '{"a":1}' ] && [ "$t3" = '{"a":1}' ]; then
				ok "hardware_id 剥离行为正确（中间/末尾/开头 都产出合法 JSON）"
			else
				fail "hardware_id 剥离有问题：中间=[$t1] 末尾=[$t2] 开头=[$t3]"
			fi
		else
			warn "gwrt-agent 的 hardware_id 处理无法识别（未找到 sed 表达式）"
		fi
	fi

	# ---- initramfs 体积 ----
	# 【更正 2026-10-15】之前的笔记把"initramfs 变大"当成 INITRAMFS_SOURCE 污染事故，
	# 是误判。机制在 include/kernel-defaults.mk 的 Kernel/SetInitramfs：
	# 本线 CONFIG_TARGET_ROOTFS_INITRAMFS=y，本意就是"把整个 rootfs 嵌进内核"，
	# 做 boot-to-RAM 救援镜像，所以它本来就该是 100MB 量级。
	# 实测 usr/initramfs_data.cpio ≈ 385MB，zstd 压完 109MB；本机内存 928MB，装得下。
	# 反倒是 -08 那个 6.6MB 的 initramfs 才是异常 —— kernel 变体构建时 staging rootfs
	# 还没填满就嵌进去了，等于一个空救援镜像。
	# 所以判据是"太小才有问题"，不是"太大才有问题"。
	hdr "initramfs 体积"
	itb=$(find "$(dirname "$bin")" -maxdepth 1 -name '*initramfs*.itb' 2>/dev/null | head -1)
	if [ -n "$itb" ] && [ -f "$itb" ]; then
		sz=$(wc -c < "$itb")
		mb=$((sz / 1048576))
		if [ "$sz" -lt $((10 * 1024 * 1024)) ]; then
			fail "initramfs.itb 只有 ${mb}MB —— 明显偏小，多半是 kernel 变体构建时 staging rootfs 还没填满，嵌进去的是空救援镜像"
			info "本线 CONFIG_TARGET_ROOTFS_INITRAMFS=y，正常应在 100MB 量级"
		elif [ "$sz" -gt $((200 * 1024 * 1024)) ]; then
			warn "initramfs.itb = ${mb}MB 偏大，确认本机内存装得下再用"
		else
			ok "initramfs.itb = ${mb}MB（boot-to-RAM 全量 rootfs 救援镜像，正常）"
		fi
	else
		info "未找到配套 initramfs.itb，跳过体积检查"
	fi

	# ---- CONTROL / 版本 ----
	hdr "镜像元数据"
	ctrl=$(find "$tmp" -name CONTROL | head -1)
	if [ -n "$ctrl" ]; then
		cat "$ctrl" | while read -r l; do info "CONTROL: $l"; done
		grep -q "^BOARD=$BOARD$" "$ctrl" && ok "BOARD=$BOARD" || fail "BOARD 不是 $BOARD"
	fi

	# ---- DTB ----
	hdr "DTB（有线口）"
	kernel=$(find "$tmp" -name kernel -type f | head -1)
	if [ -n "$kernel" ]; then
		# 注意：DTB 是二进制，不能塞进 $(...) —— shell 变量会丢掉 NUL 字节。
		# 让 python 直接把抽出来的 blob 写到文件。
		dtb="$tmp/board.dtb"
		python3 - "$kernel" "$dtb" <<'PY' 2>/dev/null
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
i = d.find(b'JDCloud RE-SS-01')
if i < 0:
    sys.exit(1)
for off in range(i, max(0, i - 0x40000), -4):
    if d[off:off+4] == b'\xd0\x0d\xfe\xed':
        tot = struct.unpack('>I', d[off+4:off+8])[0]
        if 0x1000 < tot < 0x100000:
            open(dst, 'wb').write(d[off:off+tot])
            sys.exit(0)
sys.exit(1)
PY
		if [ -s "$dtb" ]; then
			dts="$tmp/board.dts"
			dtc -I dtb -O dts "$dtb" > "$dts" 2>/dev/null
			# mainline PPA 模型标志
			grep -q 'qualcomm,ipq6018-ppe' "$dts" && ok "PPE DSA 节点存在" || fail "PPE 节点缺失（PPA 模型不对）"
			grep -q 'qualcomm,ipq6018-edma' "$dts" && ok "EDMA 节点存在" || fail "EDMA 节点缺失"
			n_uniphy=$(grep -c 'compatible = "qualcomm,ipq6018-uniphy"' "$dts")
			[ "$n_uniphy" -eq 2 ] && ok "uniphy x2" || fail "uniphy 数量=$n_uniphy（期望 2）"
			grep -q 'qcom,ipq6018-cmn-pll' "$dts" \
				&& ok "cmn_pll 存在" \
				|| fail "cmn_pll 缺失 —— CONFIG_IPQ_CMN_PLL 没开，四个有线口全死（261011-03 的根因）"
			# ess-nss 是 NSS/SSDK 模型，与本线驱动不绑定，出现即错
			grep -qE 'ess-uniphy|qcom,nss-dp|ess-switch-ipq60xx' "$dts" \
				&& fail "DTB 出现 NSS/SSDK 节点（ess-uniphy/nss-dp/ess-switch）—— 驱动绑不上，无线口全死" \
				|| ok "无 NSS/SSDK 残留节点"
			for p in lan1 lan2 lan3 wan; do
				grep -q "label = \"$p\"" "$dts" && ok "端口 $p" || fail "端口 $p 缺失"
			done
			rm -f "$dts"
		else
			fail "无法从 kernel 里抽出 DTB（FIT 结构可能变了）"
		fi
	else
		fail "sysupgrade tar 里没有 kernel"
	fi
}

# --------------------------------------------------------------- device 模式

verify_device() {
	host="${1:-192.168.3.3}"
	RO="ssh -o BatchMode=yes -o ConnectTimeout=10 root@$host"

	$RO true 2>/dev/null || { fail "SSH 连不上 root@$host"; return 1; }
	ok "已连上 root@$host"

	# 把检查下沉到设备上一次性取回，避免几十次 ssh 往返。
	# 统一用 "V<TAB>key<TAB>value" 输出，awk 按 key 取值，避免 shell 字符串匹配踩坑。
	out=$($RO 'sh -s' <<'REMOTE' 2>&1
KVER=$(uname -r)
v() { printf 'V\t%s\t%s\n' "$1" "$2"; }

v kver "$KVER"
v release "$(sed -n "s/^DISTRIB_RELEASE=//p" /etc/openwrt_release 2>/dev/null | tr -d "'")"
v uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)"

for m in ath11k_ahb ath11k cfg80211 mac80211 qrtr_smd; do
	if grep -q "^$m " /proc/modules 2>/dev/null; then v "mod_$m" yes; else v "mod_$m" no; fi
done

for f in "/lib/modules/$KVER/ath11k_ahb.ko" \
         "/rom/lib/modules/$KVER/ath11k_ahb.ko" \
         "/rom/lib/modules/$KVER/ath11k.ko" \
         "/etc/modules.d/ath11k-ahb" \
         "/rom/etc/modules.d/ath11k-ahb" \
         "/lib/firmware/ath11k/IPQ6018/hw1.0/board-2.bin" \
         "/lib/functions/gwrt-wireless.sh"; do
	if [ -e "$f" ]; then v "f$(printf '%s' "$f" | tr '/' '_')" yes; else v "f$(printf '%s' "$f" | tr '/' '_')" no; fi
done

v phy "$(ls /sys/class/net/ 2>/dev/null | grep -c '^phy')"
v phydev "$(ls /sys/class/net/ 2>/dev/null | grep '^phy' | tr '\n' ' ')"
v radios "$(uci -q show wireless 2>/dev/null | grep -c '^wireless\.radio[0-9]*=')"
v ch5g "$(uci -q get wireless.radio0.channel 2>/dev/null)"
v lanip "$(uci -q get network.lan.ipaddr 2>/dev/null)"
v offload "$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)/$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)"
v agent "$([ -x /usr/sbin/gwrt-agent.bin ] && /usr/sbin/gwrt-agent dump 2>/dev/null | jsonfilter -e '@' >/dev/null 2>&1 && echo yes || echo no)"
v defaults "$(ls /etc/uci-defaults/ 2>/dev/null | tr '\n' ' ')"
v ports "$(for p in lan1 lan2 lan3 wan; do printf '%s=%s ' "$p" "$(cat /sys/class/net/$p/operstate 2>/dev/null)"; done)"
v clk "$(dmesg 2>/dev/null | grep -c 'nss_crypto_clk_src: rcg')"
v disk "$(df -h /overlay 2>/dev/null | tail -1 | awk '{print $5}')"
v modfail "$(logread 2>/dev/null | grep -c 'failed to find a module named ath11k_ahb')"
REMOTE
	)

	kv()  { printf '%s\n' "$out" | awk -F'\t' -v k="$1" '$1=="V" && $2==k {print $3; exit}'; }
	kf()  { [ "$(kv "f$(printf '%s' "$1" | tr '/' '_')")" = yes ]; }

	hdr "版本"
	info "release = $(kv release)   uptime = $(kv uptime)s   kernel = $(kv kver)"

	hdr "ath11k 模块 —— -08 无线的真凶"
	for m in ath11k_ahb ath11k cfg80211 mac80211; do
		if [ "$(kv "mod_$m")" = yes ]; then ok "$m 已加载"; else fail "$m 未加载"; fi
	done
	if kf "/lib/modules/$(kv kver)/ath11k_ahb.ko"; then
		ok "/lib/modules 有 ath11k_ahb.ko"
	else
		fail "/lib/modules 没有 ath11k_ahb.ko —— kmod-ath11k-ahb 没打进去"
	fi
	if kf "/rom/lib/modules/$(kv kver)/ath11k_ahb.ko"; then
		ok "/rom 里 ath11k_ahb.ko 存在（刷机写进去了）"
	else
		fail "/rom 里没有 ath11k_ahb.ko —— 刷机没写进去或镜像漏打包，必须重刷"
	fi
	if kf "/etc/modules.d/ath11k-ahb"; then
		ok "/etc/modules.d/ath11k-ahb 存在"
	else
		fail "/etc/modules.d/ath11k-ahb 缺失 —— kmodloader 不会加载它"
	fi
	kf "/lib/functions/gwrt-wireless.sh" && ok "gwrt-wireless.sh 在位" || fail "gwrt-wireless.sh 缺失 —— 38 脚本会直接报错退出"

	hdr "无线运行态"
	n=$(kv phy)
	if [ "${n:-0}" -ge 1 ]; then
		ok "phy 数 = $n  ($(kv phydev))"
	else
		fail "没有 phy —— 无线未起来"
	fi
	r=$(kv radios)
	if [ "${r:-0}" -ge 1 ]; then
		ok "wireless 配置有 $r 个 radio 段"
	else
		fail "/etc/config/wireless 是空的 —— 首启没生成"
	fi
	ch=$(kv ch5g)
	if [ "$ch" = "$EXPECT_CH5G" ]; then
		ok "5G 信道 = $ch"
	elif [ -n "$ch" ]; then
		warn "5G 信道 = $ch（期望 $EXPECT_CH5G；38_gwrt-wifi-channel 没生效？）"
	fi

	hdr "有线口 / 加速"
	info "ports: $(kv ports)"
	info "flow_offloading(hw) = $(kv offload)"
	# network.lan.ipaddr 可能带 /24 前缀，比较前剥掉
	ip=$(kv lanip); ip=${ip%%/*}
	if [ "$ip" = "$DEFAULT_LAN_IP" ]; then
		ok "LAN IP = $(kv lanip)"
	elif [ -z "$ip" ]; then
		warn "读不到 network.lan.ipaddr"
	else
		warn "LAN IP = $(kv lanip)（期望 $DEFAULT_LAN_IP）"
	fi

	hdr "已知历史问题"
	if [ "$(kv modfail)" -gt 0 ]; then
		warn "logread 里有 $(kv modfail) 条 'failed to find a module named ath11k_ahb'（历史失败记录）"
	fi
	if [ "$(kv clk)" -gt 0 ]; then
		warn "dmesg 有 $(kv clk) 条 'nss_crypto_clk_src: rcg didn't update' —— PPE 取 gcc_nss_crypto_clk 时命中 IPQ6018 的 RCG2 固有行为，与 IPQ_CMN_PLL 无关；WARN(1) 非致命，已知不处理"
	fi
	[ "$(kv agent)" = "yes" ] \
		&& ok "gwrt-agent payload 合法 JSON（dump 行为测试通过）" \
		|| fail "gwrt-agent payload 非法 JSON —— report 会刷屏 invalid JSON"
	info "uci-defaults 残留: $(kv defaults)"
}

# --------------------------------------------------------------------- main

case "${1:-}" in
image)  verify_image "${2:-}" ;;
device) verify_device "${2:-}" ;;
*)
	cat <<EOF
用法: $0 image  <sysupgrade.bin>
      $0 device [host]        # 默认 192.168.3.3
EOF
	exit 2
	;;
esac

hdr "汇总"
printf 'FAIL=%d  WARN=%d\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
exit 0