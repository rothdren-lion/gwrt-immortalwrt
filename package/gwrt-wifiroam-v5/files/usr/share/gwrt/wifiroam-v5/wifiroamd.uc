// SPDX-License-Identifier: GPL-2.0-or-later
// wifiroamd - multi-AP topology & 802.11k/v/r roaming orchestration daemon
// Roles: cap (controller AP) / sap (satellite AP) / unconfigured
//
// ucode notes:
//  - for (v in array) iterates VALUES; for (k, v in obj) iterates key+value
//  - libubus.open_channel(sock, rx_cb, disconnect_cb); rx_cb(req) single arg
//  - channel.request({method, data, return:"ignore"}) fire & forget
//  - channel.defer({method, data, data_cb, cb}) request/response
'use strict';

import * as libubus from "ubus";
import * as uloop from "uloop";
import * as socket from "socket";
import * as fs from "fs";
import * as uci from "uci";
import { sha256 } from "digest";
import * as mesh from "/usr/share/gwrt/wifiroam/mesh-state.uc";
import * as meshRadio from "/usr/share/gwrt/wifiroam/mesh-radio.uc";
import * as front from "/usr/share/gwrt/wifiroam/mesh-fronthaul.uc";

// ---------------------------------------------------------------- constants
const UDP_PORT = 50607;
const TCP_PORT = 50608;
const MAGIC = "WIFIROAM1";
const ALIAS_DIR = "/etc/wifiroam";
const ALIAS_PATH = ALIAS_DIR + "/aliases.json";
const PEER_TTL = 30;        // s without hello -> offline
const DISCOVER_TTL = 180;   // s unconfigured device stays in discover list
const HELLO_INTERVAL = 5000;
const TICK_INTERVAL = 10000;
const MAX_EVENTS = 100;
const WIRED_TTL = 300;    // s wired client stays listed after last FDB sighting
const STEER_COOLDOWN = 60;  // s 同一终端两次 BSS Transition 引导的最小间隔
const MIN_STEER_ASSOC = 20; // s 终端入网后至少稳定这么久才允许被引导
const STEER_KICK_AFTER = 3; // 连续 BTM 引导无果的次数，达到后强制断开让终端重新选 AP
const STEER_KICK_COOLDOWN = 1800; // s 同一终端两次强制断开的最小间隔
const PIN_BAN_MS = 120000;        // 固定终端连错 AP 时 hostapd 禁入时长（毫秒）
const PIN_KICK_COOLDOWN = 30;     // s 同一终端两次踢回目标 AP 的最小间隔
const BACKHAUL_SECTION = "wifiroam_bh";
const BACKHAUL_DEFAULT_SSID = "wifiroam-bh";

// 访客网络：每台 AP 各自建一个独立子网 + DHCP + 防火墙隔离区，
// 访客口统一挂到 br-guest（接口名 netifd 限制为 15 字符以内）。
const GUEST_SECTION = "guest";
const GUEST_IFACE = "wifiroam_guest";
const GUEST_DEV = "wifiroam_guest_dev";
const GUEST_BRIDGE = "br-guest";
const GUEST_ZONE = "wifiroam_guest_zone";
const GUEST_FWD_WAN = "wifiroam_guest_fwd_wan";
const GUEST_FWD_LAN = "wifiroam_guest_fwd_lan";
const GUEST_SNAT = "wifiroam_guest_snat";
const GUEST_IP = "172.16.10.1";
const GUEST_NET = "172.16.10.0/24";
const GUEST_DEFAULT_SSID = "Guest";
const GUEST_SEC_PREFIX = "wifiroam_guest_";
const GUEST_NFT_TABLE = "wifiroam_guest";
// 协议/行为版本：LuCI 侧要求一致，不一致时「重启」会自动 stop+start 修复
const DAEMON_VERSION = 5;

const ROAM_KEYS = [
	"ieee80211r", "mobility_domain", "ft_over_ds", "ft_psk_generate_local",
	"nas_identifier", "pmk_r1_push", "r0kh", "r1kh", "reassociation_deadline",
	"ieee80211k", "rrm_neighbor_report", "rrm_beacon_report",
	"ieee80211v", "bss_transition",
];

// ------------------------------------------------------ app access control
// 内置应用清单。统计准确性优先于域名数量，只收录可归属于对应产品的域名：
// 1) 排除 alicdn.com / byteimg.com 等跨产品、跨厂商共享基础设施；
// 2) 排除 bdstatic / zhimg / pddpic 等会被第三方页面大量嵌入的静态资源域；
// 3) 同一公司的不同产品分开统计，避免把 TikTok、Kwai 等计入国内产品。
// QQ 暂无可覆盖核心聊天流量且不与其他腾讯产品混用的域名，保留空条目仅为
// 兼容和解除旧策略；dnsmasq 不为空条目生成配置，也不会产生新的 QQ 统计。
// dnsmasq 将解析结果写入每应用 IPv4/IPv6 nft set，再按
// (原始终端 MAC, 目标 IP 集合) 统计或封禁，TLS/QUIC SNI DPI 作为封禁兜底。
// cat 用于前端分类展示（对齐 TP-Link 的应用分类）。
const APP_DEFS = [
	{ id: "wechat", name: "微信", cat: "social", domains: [
		"weixin.qq.com", "wx.qq.com", "wechat.com" ] },
	{ id: "qq", name: "QQ", cat: "social", domains: [] },
	{ id: "douyin", name: "抖音", cat: "video", domains: [
		"douyin.com", "douyinvod.com", "idouyinvod.com", "douyincdn.com",
		"douyinpic.com", "douyinstatic.com", "amemv.com", "iesdouyin.com" ],
	  // apex 域名多数不可解析，预热时解析具体视频主机补充 CDN 地址池。
	  probes: [ "www.douyin.com", "v3-web.douyinvod.com",
	            "v26-web.douyinvod.com", "p3-pc-sign.douyinpic.com" ] },
	{ id: "tiktok", name: "TikTok", cat: "video", domains: [
		"tiktok.com", "tiktokv.com", "tiktokcdn.com", "tiktok-row.net" ] },
	{ id: "kuaishou", name: "快手", cat: "video", domains: [
		"kuaishou.com", "gifshow.com" ] },
	// kwaicdn.com 同时服务国内快手与海外 Kwai，不作为任一产品的独占依据。
	{ id: "kwai", name: "Kwai", cat: "video", domains: [
		"kwai.com" ] },
	{ id: "bilibili", name: "哔哩哔哩", cat: "video", domains: [
		"bilibili.com", "hdslb.com", "bilivideo.com", "biliapi.net" ] },
	{ id: "xiaohongshu", name: "小红书", cat: "social", domains: [
		"xiaohongshu.com", "xhscdn.com" ] },
	{ id: "weibo", name: "微博", cat: "social", domains: [
		"weibo.com", "weibo.cn" ] },
	{ id: "taobao", name: "淘宝/天猫", cat: "shop", domains: [
		"taobao.com", "tmall.com" ] },
	{ id: "iqiyi", name: "爱奇艺", cat: "video", domains: [
		"iqiyi.com", "iqiyipic.com", "qiyi.com" ] },
	{ id: "netease_music", name: "网易云音乐", cat: "music", domains: [
		"music.163.com", "music.126.net" ] },
	{ id: "youku", name: "优酷", cat: "video", domains: [
		"youku.com" ] },
	{ id: "mgtv", name: "芒果TV", cat: "video", domains: [
		"mgtv.com", "hitv.com" ] },
	{ id: "zhihu", name: "知乎", cat: "news", domains: [
		"zhihu.com" ] },
	{ id: "toutiao", name: "今日头条", cat: "news", domains: [
		"toutiao.com", "toutiaoapi.com" ] },
	{ id: "xigua", name: "西瓜视频", cat: "video", domains: [
		"ixigua.com" ] },
	{ id: "jd", name: "京东", cat: "shop", domains: [
		"jd.com" ] },
	{ id: "pinduoduo", name: "拼多多", cat: "shop", domains: [
		"pinduoduo.com", "yangkeduo.com" ] },
	{ id: "meituan", name: "美团/大众点评", cat: "shop", domains: [
		"meituan.com", "dianping.com" ] },
	{ id: "eleme", name: "饿了么", cat: "shop", domains: [
		"ele.me" ] },
	{ id: "dingtalk", name: "钉钉", cat: "office", domains: [
		"dingtalk.com" ] },
	{ id: "feishu", name: "飞书", cat: "office", domains: [
		"feishu.cn", "feishu.net" ] },
	{ id: "wps", name: "WPS", cat: "office", domains: [
		"wps.cn", "wps.com" ] },
	{ id: "baidu", name: "百度", cat: "web", domains: [
		"baidu.com" ] },
	{ id: "ximalaya", name: "喜马拉雅", cat: "music", domains: [
		"ximalaya.com" ] },
	{ id: "huya", name: "虎牙直播", cat: "live", domains: [
		"huya.com" ] },
	{ id: "douyu", name: "斗鱼直播", cat: "live", domains: [
		"douyu.com", "douyu.tv" ] },
	// 只保留国服原神高置信度服务域名。官网、米游社、HoYoLAB、补丁 CDN
	// 及国际服 CloudFront/Cloudflare 都会与其他服务共用 IP；预热会持续
	// 写入这些共享地址，不能再用于按 IP 的使用统计。
	{ id: "mihoyo", name: "原神/米哈游", cat: "game", domains: [
		"dispatchcnglobal.yuanshen.com", "hk4e-sdk.mihoyo.com",
		"hk4e-api.mihoyo.com" ] },
	{ id: "kugou", name: "酷狗音乐", cat: "music", domains: [
		"kugou.com", "kugou.net" ] },
	{ id: "ctrip", name: "携程", cat: "web", domains: [
		"ctrip.com", "ctrip.cn" ] },
	{ id: "rail12306", name: "铁路12306", cat: "web", domains: [
		"12306.cn" ] },
	{ id: "zuoyebang", name: "作业帮", cat: "office", domains: [
		"zuoyebang.com", "zuoyebang.cc", "zybang.com" ] },
	{ id: "steam", name: "Steam", cat: "game", domains: [
		"steampowered.com", "steamcommunity.com", "steamcontent.com" ] },
	{ id: "netflix", name: "Netflix", cat: "video", domains: [
		"netflix.com" ] },
	{ id: "spotify", name: "Spotify", cat: "music", domains: [
		"spotify.com" ] },
	{ id: "bosszhipin", name: "BOSS直聘", cat: "office", domains: [
		"zhipin.com" ] },
	// 以下来自商业 IOTD 指纹库，仅保留已核实可解析、能独立归属于
	// 对应 IoT 云服务的域名；共享 CDN、公共云入口和宽泛官网不收录。
	{ id: "mijia", name: "米家", cat: "iot", domains: [
		"api.io.mi.com", "ot.io.mi.com" ] },
	{ id: "aqara", name: "Aqara", cat: "iot", domains: [
		"aiot-coap.aqara.cn", "aiot-coap-usa.aqara.com", "usa.aqara.com" ] },
	{ id: "arlo", name: "Arlo", cat: "iot", domains: [
		"deviceapi.messaging.arlo.com" ] },
	{ id: "philips_hue", name: "Philips Hue", cat: "iot", domains: [
		"diagnostics.meethue.com" ] },
	{ id: "eufy", name: "eufy", cat: "iot", domains: [
		"security-app.eufylife.com" ] },
	{ id: "dlink", name: "D-Link", cat: "iot", domains: [
		"api.fota.dlink.com", "auto.mydlink.com" ] },
	{ id: "xiaoyi", name: "小蚁", cat: "iot", domains: [
		"api.us.xiaoyi.com", "log.xiaoyi.com" ] },
	{ id: "netatmo", name: "Netatmo", cat: "iot", domains: [
		"netatmo.net" ] },
	{ id: "withings", name: "Withings", cat: "iot", domains: [
		"ws.withings.net" ] },
	{ id: "roku", name: "Roku", cat: "iot", domains: [
		"ravm.tv", "rokutime.com" ] },
];

// 活跃判定阈值：一个采样窗口内只有零星心跳包（推送、SDK 保活）不算「在使用」。
// 之前只要包数有增长就累计整个窗口，导致「装了没开」的 App 也显示大量时长。
const APP_ACT_MIN_PK = 3;        // 窗口内包数下限
const APP_ACT_MIN_BYTES = 2048;  // 窗口内字节下限
const APP_SET_TIMEOUT = "12h";   // DNS 集合元素有效期，防止旧 IP 被复用时误计

/* 精准识别模式（高级设置里的开关，关闭时保持上面这套宽松口径）：
   - 活跃判定更严：包数与字节必须同时达标（且关系），锁屏心跳不再计时长；
   - 集合超时缩短到 30m：CDN 回收/复用 IP 后更快退出归属。命中刷新不受
     内核支持（实测 Not supported），靠 dnsmasq 重复解析自然续期；
   - DNS 出口锁定：53 重定向到本机 dnsmasq、拦 DoT(853) 与知名公共 DoH，
     防止 App 用内置 HTTPDNS/私有 DNS 绕过识别。
   DoH 清单只收纯 DNS 服务商地址（Cloudflare 1.1.1.1 同时承载网页服务，
   为避免误伤不收录）。 */
const APP_ACT_ENH_PK = 5;
const APP_ACT_ENH_BYTES = 4096;
const APP_SET_TIMEOUT_ENH = "30m";
const APP_DOH_V4 = [ "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
	"223.5.5.5", "223.6.6.6", "119.29.29.29", "180.76.76.76",
	"114.114.114.114", "114.114.115.115" ];
const APP_DOH_V6 = [ "2001:4860:4860::8888", "2001:4860:4860::8844",
	"2620:fe::fe", "2620:fe::9", "2400:3200::1", "2400:3200:baba::1",
	"2402:4e00::" ];

// 终端历史：记录每个终端（按设备组去重）的首次发现、最后在线、最后离线时间。
// 用途：1) 终端设备页展示在线状态与上下线时间；2) 网络唤醒白名单——只允许
// 唤醒曾经在线过的设备，避免把任意 MAC 当作放大器发广播。
const DEVICES_PATH = ALIAS_DIR + "/devices.json";
const DEVICES_MAX = 512;      // 保存的历史设备上限（超出的最久未上线记录被淘汰）
const DEVICES_FLUSH = 60;     // s：历史落盘最小间隔，避免每次 tick 都写 flash

const APPCTL_TABLE = "wifiroam";
const APPCTL_NFT_FILE = "/tmp/wifiroam-appctl.nft";
const APPSTATS_PATH = ALIAS_DIR + "/appstats.json";
const APPCTL_SCHEMA_PATH = ALIAS_DIR + "/nft_schema";
const APPSTATS_FLUSH = 15;   // s：统计落盘的最小间隔（重启最多丢这一轮）

// DPI（深度包检测）：把每个新建连接的首包送到 wifiroam-dpi 守护进程，
// 解析 TLS SNI / QUIC SNI，命中被禁应用域名即 drop。兜底 DNS/IP 集合方案
// 无法覆盖的 HTTPDNS 直连与 P2P 流量。blocklist 由本进程写，dpi 读。
const DPI_QUEUE = 0;
const DPI_BLOCKLIST = "/tmp/wifiroam/dpi_blocklist";
const DPI_DAEMON = "/usr/sbin/wifiroam-dpi";
const DPI_PIDFILE = "/tmp/wifiroam-dpi.pid";

// 定时断网（上网时间）：按终端 MAC + 时间段 + 星期，在 CAP 的 forward 链
// 丢弃该终端的转发流量。用独立 nft 表，避免与应用管控的规则重建互相干扰；
// 是否生效由守护进程每个 tick 计算，不依赖内核 time 模块（跨午夜/星期判定
// 更直观，也不受内核时区与模块裁剪影响）。
const BAN_TABLE = "wifiroam_ban";
const BAN_NFT_FILE = "/tmp/wifiroam-ban.nft";
const BAN_DEFAULT_ON = "22:00";
const BAN_DEFAULT_OFF = "07:00";

// ------------------------------------------------------------------ globals
let daemon_started = time();  // 进程启动时刻，用于识别「重启后仍是旧进程」
let ubusc;              // ubus connection
let udp_sock;           // discovery socket
let tcp_srv;            // sync listen socket

// 前向声明：ucode 单遍编译不提升函数声明，使用点必须晚于绑定点
let sap_report, push_aliases_to, push_roam_to, push_backhaul_to, push_offload_to, push_wifi_to, push_guest_to, apply_result_update, apply_backhaul_result_update, apply_wifi_result_update, apply_guest_result_update, ensure_token, reconfigure, conn_close, bss_public;
// 访客网络：前向声明后置赋值函数（ucode 不提升函数声明）
let guest_port_sync, guest_after_reload, apply_guest_local, guest_save_local, guest_tick;
// 需要 local_clients()，只能在它之后绑定；下列函数存在跨前后定义调用
let appctl_track_macs, online_sample, device_group_refresh, ban_apply, appctl_dpi_daemon;
// 同名函数定义在本文件更后面，必须先声明再赋值，否则运行时报 undeclared variable
let local_clients, sap_disconnect, find_client, roam_default_init;

let state = {
	cfg: {},            // uci wifiroam
	self: {},           // self system info
	brdev: "br-lan",
	peers: {},          // macnorm -> AP peer (hello + report merged)
	discovered: {},     // macnorm -> unconfigured device seen
	aliases: { ver: 0, map: {}, groups: {}, redirect: {}, isolated: {}, pin: {} },
	pin_last: {},       // macnorm -> 上一次因固定 AP 被踢回的时刻
	devices: {},        // 设备组 ID -> 终端历史 { mac, ip, hostname, first_seen,
	                    //   last_online, last_offline, online, ap, conn }
	dev_dirty: false,   // 历史是否有未落盘的变更
	dev_saved: 0,       // 上次落盘时刻
	device_index: {},     // 原始 MAC -> 稳定设备组 ID
	device_obs: {},       // 本轮运行期观察到的主机名、租约与在线证据
	link: null,         // SAP: outgoing channel to CAP {sock,chan,authed}
	cap_learned: null,  // CAP ip learned from hello
	events: [],         // ring buffer
	last_apply: null,   // last roam push result summary
	last_backhaul: null, // last wireless-backhaul push result summary
	last_wifi: null,    // last Wi-Fi rename push result summary
	last_guest: null,   // last guest-network push result summary
	guest_open: null,   // 访客网络当前是否在开放时段内（null = 未知）
	guest_tc_sig: "",   // 访客限速 tc 规则的签名，避免每次 tick 重建
	guest_tc_devs: [],  // 已挂了 qdisc 的访客 netdev（桥不参与桥转发路径，必须挂到 vif）
	_guest_nft_sig: "",  // 访客 nft 表（隔离 + 子AP SNAT）的签名，避免每轮重建
	_guest_zone_migrated: false, // 访客区是否已从 option network 迁移到 device+subnet
	client_seen: {},    // macnorm -> first seen ts
	client_bytes: {},   // macnorm -> 站点字节计数采样 { ts, rx, tx }（算实时速率）
	bytes_cache: {},    // ifname -> { ts, map }：1s 内复用，避免同一轮重复调用 iw
	prev_clients: null, // for join/leave event diffing; null = 首轮扫描不产事件
	wired_seen: {},     // macnorm -> 最后一次出现在 FDB 的时间（有线存活依据+防抖）
	wifi_seen: {},      // macnorm -> 最后一次作为无线站点出现的时间（防止被 FDB 误判为有线）
	prev_owner: null,   // CAP 视角 macnorm -> 归属 AP（跨 AP 迁移事件；null = 首轮抑制）
	roam_ver_applied: 0,
	backhaul_ver_applied: 0,
	steer_last: {},     // macnorm -> 上次 BSS Transition 引导时间
	steer_tries: {},    // macnorm -> 连续引导仍未换 AP 的次数
	kick_last: {},      // macnorm -> 上次强制断开的时间
	steer_mute: {},     // macnorm -> 该时间前不再强制断开（被踢后仍回到原 AP 说明附近没有更好的 AP）
	nr_sig: "",         // 本机已下发的 11k 邻居表签名
	cap_nr: [],         // SAP: CAP 下发的 11k 邻居元素
	net_names: {},      // SAP: CAP 下发的 macnorm -> { hostname, ip }（SAP 无 DHCP，名称需由 CAP 提供）
	roster: null,       // SAP: CAP 下发的全网络 AP/SSID 概览（用于开启前检查一致展示）
	appctl: { enabled: false, enhanced: false, strict: false, devices: {}, stats: {}, day: "", online: {}, ndata: {} },
	ban: { enabled: false, list: [], sig: "", active: {} },   // 独立全局开关、定时规则与当前生效集合
	_nft_snap: null,    // CAP: 上次 nft 计数快照 { "<mac>|<app>": { pk, by } }
	_dnslock_on: null,  // CAP: DNS 出口锁定链当前状态（null = 未同步，首轮强制对齐）
	_appstat_ts: 0,     // CAP: 上次采样时刻
	_appstat_dirty: false,
	_appstat_saved: 0,
	_track_key: "",     // CAP: 上次建规则时的终端集合签名
	_warm_list: null,   // CAP: 预热用的域名/主机名清单（扁平化）
	_warm_i: 0,         // CAP: 下次预热哪个
};

// ------------------------------------------------------------------ helpers
function log(msg) { printf("wifiroam: %s\n", msg); }

function macnorm(m) { return lc(replace(m ?? "", /[^0-9a-fA-F]/g, "")); }

function maccolon(mn) {
	if (length(mn) != 12) return mn;
	return uc(substr(mn,0,2)+":"+substr(mn,2,2)+":"+substr(mn,4,2)+":"+
	          substr(mn,6,2)+":"+substr(mn,8,2)+":"+substr(mn,10,2));
}

// 设备组 ID 以 g 开头，不与 12 位原始 MAC 混淆。UCI 的 mac 字段继续沿用，
// 但其中可以保存设备组 ID；真正下发 hostapd/nft 时再展开成成员 MAC。
function devnorm(v) {
	let s = lc(trim(v ?? ""));
	if (match(s, /^g[0-9a-f]{12}$/)) return s;
	return macnorm(s);
}

function mac_is_random(mn) {
	// IEEE 802 本地管理位（首字节第二十六进制位为 2/6/a/e）。
	return length(mn) == 12 && index([ "2", "6", "a", "e" ], substr(mn, 1, 1)) >= 0;
}

function device_key(v) {
	let key = devnorm(v);
	if (substr(key, 0, 1) == "g") {
		let guard = 0;
		while (state.aliases.redirect?.[key] && guard++ < 16)
			key = state.aliases.redirect[key];
		return key;
	}
	return state.device_index[key] ?? key;
}

function device_reindex() {
	state.aliases.groups ??= {};
	state.aliases.redirect ??= {};
	state.aliases.isolated ??= {};
	state.aliases.map ??= {};
	state.device_index = {};
	for (let gid, g in state.aliases.groups) {
		let target = gid;
		let guard = 0;
		while (state.aliases.redirect[target] && guard++ < 16)
			target = state.aliases.redirect[target];
		for (let mn in keys(g.members ?? {}))
			state.device_index[mn] = target;
	}
	// 固定 AP 记录跟随设备组迁移，避免分组变化后设置丢失
	state.aliases.pin ??= {};
	for (let k in keys(state.aliases.pin)) {
		let nk = device_key(k);
		if (nk == k) continue;
		if (state.aliases.pin[nk] == null) state.aliases.pin[nk] = state.aliases.pin[k];
		delete state.aliases.pin[k];
	}
}

function device_members_of(v) {
	let key = device_key(v);
	let g = state.aliases.groups?.[key];
	if (g) return sort(keys(g.members ?? {}));
	let mn = macnorm(key);
	return length(mn) == 12 ? [ mn ] : [];
}

function device_alias_of(v) {
	let key = device_key(v);
	let al = state.aliases.map?.[key];
	if (al) return al;
	let mn = macnorm(v);
	al = state.aliases.map?.[mn];
	if (al) return al;
	for (let member in device_members_of(key)) {
		al = state.aliases.map?.[member];
		if (al) return al;
	}
	return null;
}

// xorshift32 伪随机（避免依赖 ucode-mod-math 的 rand/srand）
let rng_state = 0;
function srand(seed) {
	rng_state = int(seed) & 0x7fffffff;
	if (rng_state == 0) rng_state = 0x9e3779b9;
}
function rand() {
	rng_state ^= (rng_state << 13) & 0x7fffffff;
	rng_state ^= rng_state >> 17;
	rng_state ^= (rng_state << 5) & 0x7fffffff;
	return rng_state & 0x7fffffff;
}

function randhex(n) {
	let s = "";
	for (let i = 0; i < n; i++)
		s += sprintf("%x", rand() % 16);
	return s;
}

function cmd_output(cmd) {
	let f = fs.popen(cmd, "r");
	if (!f) return "";
	let out = f.read("all");
	f.close();
	return out ?? "";
}

function push_event(type, mac, info, name) {
	push(state.events, { ts: time(), type, mac: mac ?? "", name: name ?? "", info: info ?? "" });
	if (length(state.events) > MAX_EVENTS)
		state.events = slice(state.events, length(state.events) - MAX_EVENTS);
	log(sprintf("event %s %s %s %s", type, mac ?? "-", name ?? "-", info ?? ""));
}

// 终端展示名：自定义别名 > 本机/对端主机名 > 本网络名称表 > MAC
// local 传入本次已有客户端表（local_clients / peer clients），避免重复扫描
function client_name_of(mn, local) {
	let al = device_alias_of(mn);
	if (al?.name != null && al.name != "") return al.name;

	let c = local?.[mn];
	if (c?.hostname != null && c.hostname != "") return c.hostname;

	for (let pmn, p in state.peers) {
		let pc = p.clients?.[mn];
		if (pc?.hostname != null && pc.hostname != "") return pc.hostname;
	}

	let n = state.net_names?.[mn];
	if (n?.hostname != null && n.hostname != "") return n.hostname;

	return maccolon(mn);
}

function field_after(words, key) {
	let i = index(words, key);
	return i >= 0 ? words[i + 1] : null;
}

// ------------------------------------------------------------- uci handling
function load_config() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	state.cfg = {
		enabled: cur.get("wifiroam", "core", "enabled") != "0",
		role: cur.get("wifiroam", "core", "role") ?? "unconfigured",
		token: cur.get("wifiroam", "core", "token") ?? "",
		cap_ip: cur.get("wifiroam", "core", "cap_ip") ?? "",
		name: cur.get("wifiroam", "core", "name") ?? "",
	};
	state.roam_ver_applied = int(cur.get("wifiroam", "roam", "config_ver") ?? "0");
	state.backhaul_ver_applied = int(cur.get("wifiroam", "backhaul", "config_ver") ?? "0");
	let aver = int(cur.get("wifiroam", "alias_sync", "ver") ?? "0");
	if (aver > state.aliases.ver) state.aliases.ver = aver;
}

function save_config() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	cur.set("wifiroam", "core", "role", state.cfg.role);
	cur.set("wifiroam", "core", "token", state.cfg.token);
	cur.set("wifiroam", "core", "cap_ip", state.cfg.cap_ip);
	cur.set("wifiroam", "core", "name", state.cfg.name);
	cur.commit("wifiroam");
}

function rssi_preset(profile) {
	return { aggressive: -62, balanced: -70, conservative: -78 }[profile] ?? -70;
}

function current_roam_cfg() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let ssids = [];
	let raw = cur.get("wifiroam", "roam", "ssids");
	if (type(raw) == "array") ssids = raw;
	else if (type(raw) == "string" && raw != "") ssids = [ raw ];
	let profile = cur.get("wifiroam", "roam", "rssi_profile") ?? "balanced";
	if (index([ "aggressive", "balanced", "conservative", "custom" ], profile) < 0)
		profile = "balanced";
	let threshold = int(cur.get("wifiroam", "roam", "rssi_threshold") ?? rssi_preset(profile));
	if (profile != "custom") threshold = rssi_preset(profile);
	if (threshold > -30) threshold = -30;
	if (threshold < -95) threshold = -95;
	return {
		enabled: cur.get("wifiroam", "roam", "enabled") == "1",
		ssids,
		r_fast: cur.get("wifiroam", "roam", "r_fast") != "0",
		ft_mode: cur.get("wifiroam", "roam", "ft_mode") ?? "simple",
		ft_over_ds: cur.get("wifiroam", "roam", "ft_over_ds") != "0",
		k_neighbor: cur.get("wifiroam", "roam", "k_neighbor") != "0",
		k_beacon: cur.get("wifiroam", "roam", "k_beacon") != "0",
		v_bss_transition: cur.get("wifiroam", "roam", "v_bss_transition") != "0",
		rssi_profile: profile,
		rssi_threshold: threshold,
		config_ver: int(cur.get("wifiroam", "roam", "config_ver") ?? "0"),
	};
}

// 漫游配置内容签名：SAP 上报本地已落盘配置的签名，CAP 据此判断是否与主 AP 一致。
// 只比 ver 无法发现历史遗留的不一致（旧版 SAP 只落盘 ver/enabled，其他字段仍是默认值）。
function roam_sig(r) {
	return sha256(sprintf("%d|%s|%d|%s|%d|%d|%d|%d|%s|%d",
		r.enabled ? 1 : 0, join(",", r.ssids ?? []), r.r_fast ? 1 : 0,
		r.ft_mode ?? "simple",
		r.ft_over_ds ? 1 : 0, r.k_neighbor ? 1 : 0, r.k_beacon ? 1 : 0,
		r.v_bss_transition ? 1 : 0, r.rssi_profile ?? "balanced",
		r.rssi_threshold ?? rssi_preset(r.rssi_profile)));
}

function current_backhaul_cfg() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	return {
		enabled: cur.get("wifiroam", "backhaul", "enabled") == "1",
		ssid: cur.get("wifiroam", "backhaul", "ssid") ?? BACKHAUL_DEFAULT_SSID,
		key: cur.get("wifiroam", "backhaul", "key") ?? "",
		device: cur.get("wifiroam", "backhaul", "device") ?? "",
		band: cur.get("wifiroam", "backhaul", "band") ?? "auto",
		channel: int(cur.get("wifiroam", "backhaul", "channel") ?? 0),
		channel2g: int(cur.get("wifiroam", "backhaul", "channel2g") ?? 0),
		config_ver: int(cur.get("wifiroam", "backhaul", "config_ver") ?? "0"),
	};
}

// ------------------------------------------------------------ alias storage
function alias_load() {
	try {
		let data = json(fs.readfile(ALIAS_PATH));
		if (type(data) == "object") {
			state.aliases.map = data.map ?? {};
			state.aliases.groups = data.groups ?? {};
			state.aliases.redirect = data.redirect ?? {};
			state.aliases.isolated = data.isolated ?? {};
			state.aliases.pin = data.pin ?? {};
			if ((data.ver ?? 0) > state.aliases.ver)
				state.aliases.ver = data.ver;
		}
	} catch (e) { /* first boot */ }
	device_reindex();
}

function alias_save() {
	fs.mkdir(ALIAS_DIR);
	fs.writefile(ALIAS_PATH, sprintf("%.J", state.aliases));
	let cur = uci.cursor();
	cur.load("wifiroam");
	cur.set("wifiroam", "alias_sync", "ver", "" + state.aliases.ver);
	cur.commit("wifiroam");
}

// ------------------------------------------------------------ AP pinning
// 固定 AP：把终端钉在某台 AP 上。固定后的终端退出所有自动引导；若它连到了
// 别的 AP，由所在 AP 主动断开并短时禁入，迫使它回到目标 AP（信号差也不放开）。
// 注意：ucode 单遍编译要求绑定先于使用，这两个函数必须放在 state/device_key/
// alias_save 之后、client_node 与 ubus 注册之前。
function pin_of(mn) {
	let pin = state.aliases.pin;
	if (!pin) return null;
	return pin[device_key(mn)] ?? pin[mn] ?? null;
}

function pin_apply(mac, ap) {
	let key = device_key(mac);
	if (length(key) != 12 && !match(key, /^g[0-9a-f]{12}$/))
		return { ok: false, error: "invalid_mac" };
	let self_mn = macnorm(state.self.mac);
	ap = trim(ap ?? "");
	// 非空但不是合法 MAC 的输入不能当成「清除」（macnorm 会把非十六进制字符滤空）
	if (ap != "" && length(macnorm(ap)) != 12)
		return { ok: false, error: "invalid_ap" };
	ap = ap == "" ? "" : macnorm(ap);
	if (ap != "" && ap != self_mn && !state.peers[ap])
		return { ok: false, error: "unknown_ap" };
	state.aliases.pin ??= {};
	if (ap == "")
		delete state.aliases.pin[key];
	else
		state.aliases.pin[key] = ap;
	state.aliases.ver = time();
	alias_save();
	return { ok: true, mac: key, ap: ap };
}

function alias_apply(mac, name, icon, note) {
	let raw = devnorm(mac);
	let mn = device_key(raw);
	if (length(mn) != 12 && !match(mn, /^g[0-9a-f]{12}$/)) return false;
	if ((name ?? "") == "" && !icon && !note)
		delete state.aliases.map[mn];
	else
		state.aliases.map[mn] = {
			name: name ?? "", icon: icon ?? null, note: note ?? null,
		};
	// 清理同一组旧 MAC 别名，避免轮询时新旧名称互相覆盖。
	if (substr(mn, 0, 1) == "g")
		for (let member in device_members_of(mn))
			if (member != raw) delete state.aliases.map[member];
	state.aliases.ver = time();
	alias_save();
	return true;
}

function alias_broadcast() {
	if (state.cfg.role != "cap") return;
	for (let mn, p in state.peers) {
		if (!p.authed || !p.chan) continue;
		try {
			p.chan.defer({
				method: "push_aliases",
				data: { aliases: state.aliases },
				data_cb: function() {}, cb: function() {},
			});
		} catch (e) {
			p.authed = false;
			p.chan = null;
			if (p.conn) { let c = p.conn; p.conn = null; conn_close(c); }
		}
	}
}

// ------------------------------------------------------ app access control
function appctl_app(id) {
	for (let a in APP_DEFS)
		if (a.id == id) return a;
	return null;
}

function appctl_read_devices() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let devs = {};
	cur.foreach("wifiroam", "appdev", function(s) {
		let raw = devnorm(s.mac ?? "");
		let mn = device_key(raw);
		if (length(mn) != 12 && !match(mn, /^g[0-9a-f]{12}$/)) return;
		let b = s.block, blocks = devs[mn]?.block ?? [];
		let incoming = [];
		if (type(b) == "array") incoming = b;
		else if (type(b) == "string" && b != "") incoming = [ b ];
		for (let id in incoming)
			if (index(blocks, id) < 0) push(blocks, id);
		devs[mn] = { name: (s.name ?? "") != "" ? s.name : (devs[mn]?.name ?? ""), block: blocks };
	});
	state.appctl.devices = devs;
	return devs;
}

// 写回某终端的禁止应用列表；列表空时删除 section（等价于不再关注该设备）
function appctl_write_device(mn, blocks, name) {
	mn = device_key(mn);
	let cur = uci.cursor();
	cur.load("wifiroam");
	let sid = null, old = [];
	cur.foreach("wifiroam", "appdev", function(s) {
		if (device_key(s.mac ?? "") == mn) {
			push(old, s[".name"]);
			if (!sid) sid = s[".name"];
		}
	});
	if (!length(blocks)) {
		for (let id in old) cur.delete("wifiroam", id);
		if (length(old)) cur.commit("wifiroam");
		return;
	}
	if (!sid) sid = cur.add("wifiroam", "appdev");
	cur.set("wifiroam", sid, "mac", mn);
	if (name != null && name != "") cur.set("wifiroam", sid, "name", name);
	cur.set("wifiroam", sid, "block", blocks);
	for (let id in old)
		if (id != sid) cur.delete("wifiroam", id);
	cur.commit("wifiroam");
}

// 把应用域名同步到 dhcp 配置，让 dnsmasq 把解析结果写入 nft 集合。
// 本固件 dnsmasq 的 init 脚本只认独立的 `config ipset` section
// （dnsmasq_ipset_add 读 table/table_family/family/name/domain），
// 不识别 dhcp.@dnsmasq[0].nftset；因此每个应用建一个 section。
// 返回 true 表示配置有变化、需要重启 dnsmasq 才生效。
function appctl_dnsmasq_sync(on) {
	let cur = uci.cursor();
	cur.load("dhcp");
	let changed = false;

	let as_list = function(v) {
		if (type(v) == "array") return v;
		if (type(v) == "string" && v != "") return [ v ];
		return [];
	};

	// 清掉早期版本写入 @dnsmasq[0].nftset 的残留（该选项在此固件无效）
	let legacy = as_list(cur.get("dhcp", "@dnsmasq[0]", "nftset"));
	let keep = [];
	for (let v in legacy)
		if (index(v, "#" + APPCTL_TABLE + "#") < 0)
			push(keep, v);
	if (length(keep) != length(legacy)) {
		if (length(keep)) cur.set("dhcp", "@dnsmasq[0]", "nftset", keep);
		else cur.delete("dhcp", "@dnsmasq[0]", "nftset");
		changed = true;
	}

	for (let a in APP_DEFS) {
		let sid = "wifiroam_" + a.id;

		// 过渡清理：曾把 v6 单独建段，但 dnsmasq 的 domain_find_sets() 对同一域名
		// 只返回一条匹配项（等长时后者覆盖前者），拆成两段会导致只有一个 family
		// 生效。正确做法是同一段里放两个集合名。
		if (cur.get("dhcp", sid + "_v6") != null) {
			cur.delete("dhcp", sid + "_v6");
			changed = true;
		}

		if (!on || !length(a.domains)) {
			if (cur.get("dhcp", sid) != null) {
				cur.delete("dhcp", sid);
				changed = true;
			}
			continue;
		}

		// family 必须留空：init 脚本的 add_nftset 会按集合名后缀 _v4/_v6 逐个
		// 推断地址族；若写死 family=4，会把 v6 集合也标成 4#。
		if (cur.get("dhcp", sid, "family") != null) {
			cur.delete("dhcp", sid, "family");
			changed = true;
		}

		let want = {
			table: APPCTL_TABLE,
			table_family: "inet",
			name: [ a.id + "_v4", a.id + "_v6" ],
			domain: a.domains,
		};

		// 已有配置完全一致时跳过，避免每次开关都无谓重启 dnsmasq
		let same = true;
		for (let k, v in want) {
			let have = as_list(cur.get("dhcp", sid, k));
			let need = as_list(v);
			if (length(have) != length(need)) { same = false; break; }
			for (let i = 0; i < length(need); i++)
				if (have[i] != need[i]) { same = false; break; }
			if (!same) break;
		}
		if (same) continue;

		// uci 不会为不存在的 section 隐式建段，先按类型创建
		if (cur.get("dhcp", sid) == null)
			cur.set("dhcp", sid, "ipset");
		for (let k, v in want)
			cur.set("dhcp", sid, k, v);
		changed = true;
	}

	if (!changed) return false;
	mesh.writeConfig(cur, "dhcp", state.cfg.role);
	return true;
}

// 精准模式（高级设置开关）：活跃判定更严、集合超时更短、锁定 DNS 出口。
// 关闭时保持宽松口径，行为与旧版一致。
function appctl_enhanced() {
	return state.appctl.enhanced == true;
}

/* 严格模式：对存在被禁应用的终端额外封锁绕过通道（QUIC / 外部 DNS / 静态
   DoH），配合 DPI 提高命中率。与应用统计的总开关相互独立。 */
function appctl_strict() {
	return state.appctl.strict == true;
}

function appctl_timeout() {
	return appctl_enhanced() ? APP_SET_TIMEOUT_ENH : APP_SET_TIMEOUT;
}

// 集合结构/特征签名：包含默认超时与全部应用域名。早期版本没有默认超时，
// 旧 IP 会永久驻留；仅缩短超时也不够，域名从特征库删除后，其共享地址仍可能
// 在剩余有效期内误计。签名变化时重建集合并由预热/真实解析重新填充。
// nft 表跨进程重启保留，旧规则仍引用集合会导致 delete 失败，所以先清规则链。
function appctl_nft_schema_id() {
	let parts = [ appctl_timeout() ];
	for (let a in APP_DEFS)
		push(parts, a.id + ":" + join(",", a.domains));
	return sha256(join("|", parts));
}

function appctl_nft_schema() {
	let schema = appctl_nft_schema_id();
	if (fs.readfile(APPCTL_SCHEMA_PATH) == schema) return false;
	cmd_output(sprintf("nft flush chain inet %s forward 2>/dev/null", APPCTL_TABLE));
	for (let a in APP_DEFS)
		for (let fam in [ "v4", "v6" ])
			cmd_output(sprintf("nft delete set inet %s %s_%s 2>/dev/null",
			                   APPCTL_TABLE, a.id, fam));
	fs.mkdir(ALIAS_DIR);
	fs.writefile(APPCTL_SCHEMA_PATH, schema);
	// 集合被重建，dnsmasq 缓存的句柄可能失效，需要重启后重新绑定
	return true;
}

// 幂等创建表 / 集合 / 转发链。已存在时 nft 报错被丢弃，不影响后续。
// 集合带默认 timeout：dnsmasq 写元素时不带显式超时，内核会按集合默认值计时，
// 超时内无新解析即自动过期，避免旧 IP 被复用后长期误归属。
// 精准模式 30m / 宽松模式 12h（appctl_timeout）。
function appctl_nft_base() {
	cmd_output(sprintf("nft add table inet %s 2>/dev/null", APPCTL_TABLE));
	for (let a in APP_DEFS) {
		cmd_output(sprintf(
			"nft add set inet %s %s_v4 '{ type ipv4_addr; flags interval; timeout %s; }' 2>/dev/null",
			APPCTL_TABLE, a.id, appctl_timeout()));
		// IPv6 必须单独建集合：iptables 时代的 ip daddr 规则完全匹配不到 v6 流量，
		// 实测手机 8 秒内 211 个 v6 包 vs 6 个 v4 包，缺 v6 等于完全不生效
		cmd_output(sprintf(
			"nft add set inet %s %s_v6 '{ type ipv6_addr; flags interval; timeout %s; }' 2>/dev/null",
			APPCTL_TABLE, a.id, appctl_timeout()));
	}
	cmd_output(sprintf(
		"nft add chain inet %s forward '{ type filter hook forward priority -10; policy accept; }' 2>/dev/null",
		APPCTL_TABLE));
	// NFQUEUE 返回 accept 会终止当前链，queue 之后的规则不再执行。
	// 因此把 packet mark -> ct mark 的复制放到 -5（晚于 -10、早于防火墙 filter）
	// 的独立链，队列放行的包重入后才会走到这里。
	cmd_output(sprintf(
		"nft add chain inet %s fwpost '{ type filter hook forward priority -5; policy accept; }' 2>/dev/null",
		APPCTL_TABLE));
}

// 重建规则：集合与元素保留（dnsmasq 填好的 IP 不会被清空），仅刷新 chain。
// 每条 (终端, 应用) 规则都带 counter 用于时长统计；禁止的额外 drop。
// IPv4 与 IPv6 各一条，comment 相同，采样时按 key 累加。
function appctl_apply_rules() {
	appctl_nft_base();
	let devs = appctl_read_devices();
	let set = appctl_track_macs();
	let script = sprintf("flush chain inet %s forward\nflush chain inet %s fwpost\n",
	                     APPCTL_TABLE, APPCTL_TABLE);
	for (let mn in set) {
		let d = devs[device_key(mn)];
		let has_block = d != null && length(d.block) > 0;
		// 统计规则必须排在 DPI 之前：队列放行的包会终止本链，
		// 后面的规则不再执行，否则被管控终端的应用时长会几乎归零。
		for (let a in APP_DEFS) {
			let blocked = d != null && index(d.block, a.id) >= 0;
			for (let fam in [ "v4", "v6" ]) {
				script += sprintf(
					"add rule inet %s forward ether saddr %s %s daddr @%s_%s counter%s comment \"wr:%s:%s:%s\"\n",
					APPCTL_TABLE, maccolon(mn), (fam == "v4") ? "ip" : "ip6",
					a.id, fam, blocked ? " drop" : "",
					mn, a.id, blocked ? "block" : "allow");
			}
		}
		// 本终端总流量（不受 daddr 限制），用于反推「未识别应用」的用量：
		// 允许类规则没有 verdict，包会继续走到这条，所以 total 含已识别部分。
		// 被 drop 的禁止流量不会到这里，符合「禁止不计入使用」的预期。
		script += sprintf(
			"add rule inet %s forward ether saddr %s counter comment \"wr:%s:*:total\"\n",
			APPCTL_TABLE, maccolon(mn), mn);
		// 严格模式：在 DPI 队列之前丢弃可绕过识别的通道。必须排在
		// ct mark accept 快速路径之前，否则已被 DPI 放行的流会跳过这些规则。
		if (has_block && appctl_strict()) {
			let gw = state.self.ip ?? "";
			// QUIC：阻断 UDP 443，迫使应用回落 TCP/TLS，便于按 SNI 识别
			script += sprintf(
				"add rule inet %s forward ether saddr %s udp dport 443 counter drop\n",
				APPCTL_TABLE, maccolon(mn));
			// 外部 DNS：只允许发往本机 dnsmasq（v6 地址不固定，直接全禁）
			if (match(gw, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
				script += sprintf(
					"add rule inet %s forward ether saddr %s udp dport 53 ip daddr != %s counter drop\n" +
					"add rule inet %s forward ether saddr %s tcp dport 53 ip daddr != %s counter drop\n",
					APPCTL_TABLE, maccolon(mn), gw,
					APPCTL_TABLE, maccolon(mn), gw);
			}
			script += sprintf(
				"add rule inet %s forward ether saddr %s meta nfproto ipv6 udp dport 53 counter drop\n" +
				"add rule inet %s forward ether saddr %s meta nfproto ipv6 tcp dport 53 counter drop\n",
				APPCTL_TABLE, maccolon(mn), APPCTL_TABLE, maccolon(mn));
			// 静态 DoH 地址（Cloudflare 1.1.1.1 同时承载网页服务，清单里未收录）
			script += sprintf(
				"add rule inet %s forward ether saddr %s ip daddr { %s } tcp dport 443 counter drop\n" +
				"add rule inet %s forward ether saddr %s ip6 daddr { %s } tcp dport 443 counter drop\n",
				APPCTL_TABLE, maccolon(mn), join(", ", APP_DOH_V4),
				APPCTL_TABLE, maccolon(mn), join(", ", APP_DOH_V6));
		}
		// 对有被禁应用的终端，把新建连接首包送 DPI 解析 SNI：
		//   - ct mark 0x1 = 已放行 (dpi 返回 accept 时携带)，命中即走快速路径
		//   - 被拦截的包 dpi 直接 drop，不设 mark，靠其流缓存丢弃后续重传
		//   - tcp 只送首个带载荷的数据包 (ACK & payload)；udp 送首包
		//   - 队列返回后由 fwpost 链把 packet mark 复制到 ct mark
		//     （meta mark 为 0 的普通包不复制，避免把已标记的流冲掉）
		if (has_block) {
			script += sprintf(
				"add rule inet %s forward ether saddr %s ct mark & 0x3 == 0x1 accept\n" +
				"add rule inet %s forward ether saddr %s ct state established " +
					"tcp flags & (fin|syn|rst|ack) == ack queue num %d\n" +
				"add rule inet %s forward ether saddr %s ct state new meta l4proto udp queue num %d\n" +
				"add rule inet %s fwpost ether saddr %s meta mark != 0 ct mark set meta mark\n",
				APPCTL_TABLE, maccolon(mn),
				APPCTL_TABLE, maccolon(mn), DPI_QUEUE,
				APPCTL_TABLE, maccolon(mn), DPI_QUEUE,
				APPCTL_TABLE, maccolon(mn));
		}
	}
	fs.writefile(APPCTL_NFT_FILE, script);
	cmd_output(sprintf("nft -f %s 2>/dev/null", APPCTL_NFT_FILE));
	fs.unlink(APPCTL_NFT_FILE);
	// chain 重建会把 counter 归零，重置快照避免把归零误判成「无流量」
	state._nft_snap = null;
	state._appstat_ts = 0;
	state._track_key = join(",", sort(keys(set)));
}

/* 硬件 flow offload 与统计不可兼得：MTK hnat 卸载后流量不再经过 netfilter
   forward 链，应用统计只能看到流建立时的首包（软件 flowtable 在 priority 0，
   晚于本插件的 -10，不受影响，可保留）。精准模式开启时自动挂起 hw offload，
   退出时恢复。只操作本机：统计发生在 CAP 的 forward 链，SAP 不做三层转发，
   其 hw 状态与统计无关。hw_suspended 标记记录「是我们关的」，避免覆盖
   用户手动关闭的设置。 */
function appctl_hw_suspend(on) {
	let cur = uci.cursor();
	cur.load("firewall");
	if (cur.get("firewall", "@defaults[0]") == null) return;
	let hw_on = cur.get("firewall", "@defaults[0]", "flow_offloading_hw") == "1";
	let cur2 = uci.cursor();
	cur2.load("wifiroam");
	let marked = cur2.get("wifiroam", "appctl", "hw_suspended") == "1";
	if (on) {
		if (!hw_on || marked) return;   // 本来就关着/已挂起：不动
		cur.set("firewall", "@defaults[0]", "flow_offloading_hw", "0");
		mesh.writeConfig(cur, "firewall", state.cfg.role);
		if (cur2.get("wifiroam", "appctl") == null)
			cur2.set("wifiroam", "appctl", "appctl");
		cur2.set("wifiroam", "appctl", "hw_suspended", "1");
		cur2.commit("wifiroam");
		cmd_output("/etc/init.d/firewall reload >/dev/null 2>&1");
	} else {
		if (!marked) return;            // 不是我们挂起的：别动用户设置
		cur.set("firewall", "@defaults[0]", "flow_offloading_hw", "1");
		mesh.writeConfig(cur, "firewall", state.cfg.role);
		cur2.delete("wifiroam", "appctl", "hw_suspended");
		cur2.commit("wifiroam");
		cmd_output("/etc/init.d/firewall reload >/dev/null 2>&1");
	}
}

function appctl_table_remove() {
	appctl_dpi_daemon("stop");
	cmd_output(sprintf("nft delete table inet %s 2>/dev/null", APPCTL_TABLE));
	state._nft_snap = null;
	state._appstat_ts = 0;
	state._track_key = "";
	state._dnslock_on = false;
}

/* ---------- DPI ---------- */
/* 把「有被禁应用的终端 → 该终端所有被禁应用的域名」写到 blocklist，
   wifiroam-dpi 读取后对匹配 SNI 的连接 drop。
   格式：每行 <mac> <dom1>,<dom2>,...
   域名来自 APP_DEFS[*].domains（只取被禁应用的）。 */
function appctl_dpi_write_blocklist() {
	let devs = appctl_read_devices();
	let lines = [];
	for (let key in devs) {
		let d = devs[key];
		if (!d || !length(d.block)) continue;
		let doms = {};
		for (let bid in d.block) {
			let a = appctl_app(bid);
			if (!a) continue;
			for (let dmn in a.domains) doms[dmn] = true;
		}
		if (!length(keys(doms))) continue;
		for (let mn in device_members_of(key))
			push(lines, sprintf("%s %s", maccolon(mn), join(",", keys(doms))));
	}
	fs.mkdir("/tmp/wifiroam");
	fs.writefile(DPI_BLOCKLIST, join("\n", lines) + "\n");
}

/* Resolve the actual running wifiroam-dpi PID.  The PID file may be
 * stale (e.g. daemon restarted by a different path), so fall back to
 * pidof which scans /proc.  Returns "" if not running. */
function appctl_dpi_pid() {
	let live = trim(cmd_output("pidof wifiroam-dpi 2>/dev/null"));
	if (live != "") return split(live, " ")[0];   /* first match */
	let pid = fs.readfile(DPI_PIDFILE);
	if (pid && cmd_output(sprintf("kill -0 %s 2>/dev/null && echo 1", trim(pid))) == "1")
		return trim(pid);
	return "";
}

/* 管理 wifiroam-dpi 守护进程。action: start|stop|reload */
appctl_dpi_daemon = function(action) {
	if (action == "stop") {
		let pid = appctl_dpi_pid();
		if (pid != "") cmd_output(sprintf("kill %s 2>/dev/null", pid));
		fs.unlink(DPI_PIDFILE);
		return;
	}
	let pid = appctl_dpi_pid();
	let running = pid != "";
	if (action == "reload") {
		if (running) {
			appctl_dpi_write_blocklist();
			cmd_output(sprintf("kill -HUP %s 2>/dev/null", pid));
		}
		return;
	}
	/* start */
	appctl_dpi_write_blocklist();
	if (running) {
		/* Already running: blocklist was just rewritten, notify the
		 * daemon so it picks up the new domain set.  (Without this,
		 * a wifiroamd restart leaves the daemon serving the stale
		 * in-memory blocklist.) */
		cmd_output(sprintf("kill -HUP %s 2>/dev/null", pid));
		return;
	}
	cmd_output(sprintf("%s & echo $! > %s", DPI_DAEMON, DPI_PIDFILE));
};

/* DNS 出口锁定（精准模式）：把客户端侧的 53 重定向到本机 dnsmasq，
   拦截 DoT(853) 与知名公共 DoH 的 443，防止 App 用内置 HTTPDNS/私有 DNS
   绕过路由器解析（域名识别最大的漏网来源）。
   只匹配 br-lan / br-guest 入方向，路由器自身出向不受影响；
   redirect 的回包由 conntrack 自动改回原始源地址，客户端无感知。
   实测内核不支持规则内带 timeout 的集合元素刷新，故只锁 DNS 不做刷新。 */
function appctl_dnslock_apply(on) {
	if (on == state._dnslock_on) return;
	state._dnslock_on = on;
	// 先单独清旧链：链不存在/非空的报错由 shell 吞掉（nft -f 遇错会中止
	// 整个文件，不能把幂等清理和创建放进同一脚本）
	cmd_output(sprintf("nft flush chain inet %s dnsnat 2>/dev/null; nft delete chain inet %s dnsnat 2>/dev/null",
		APPCTL_TABLE, APPCTL_TABLE));
	cmd_output(sprintf("nft flush chain inet %s dnslock 2>/dev/null; nft delete chain inet %s dnslock 2>/dev/null",
		APPCTL_TABLE, APPCTL_TABLE));
	if (!on) return;
	let iifs = sprintf('{ "%s", "%s" }', state.brdev, GUEST_BRIDGE);
	// 注意：这是 nft -f 脚本（无 shell），块定义不能带单引号
	let script = sprintf(
		"add chain inet %s dnsnat { type nat hook prerouting priority dstnat; policy accept; }\n" +
		"add chain inet %s dnslock { type filter hook prerouting priority -5; policy accept; }\n" +
		"add rule inet %s dnsnat iifname %s udp dport 53 counter redirect\n" +
		"add rule inet %s dnsnat iifname %s tcp dport 53 counter redirect\n" +
		"add rule inet %s dnsnat iifname %s meta nfproto ipv6 udp dport 53 counter redirect\n" +
		"add rule inet %s dnsnat iifname %s meta nfproto ipv6 tcp dport 53 counter redirect\n" +
		"add rule inet %s dnslock iifname %s meta l4proto { tcp, udp } th dport 853 counter drop\n" +
		"add rule inet %s dnslock iifname %s ip daddr { %s } tcp dport 443 counter drop\n" +
		"add rule inet %s dnslock iifname %s ip6 daddr { %s } tcp dport 443 counter drop\n",
		APPCTL_TABLE, APPCTL_TABLE,
		APPCTL_TABLE, iifs, APPCTL_TABLE, iifs,
		APPCTL_TABLE, iifs, APPCTL_TABLE, iifs,
		APPCTL_TABLE, iifs,
		APPCTL_TABLE, iifs, join(", ", APP_DOH_V4),
		APPCTL_TABLE, iifs, join(", ", APP_DOH_V6));
	fs.writefile(APPCTL_NFT_FILE, script);
	cmd_output(sprintf("nft -f %s 2>/dev/null", APPCTL_NFT_FILE));
	fs.unlink(APPCTL_NFT_FILE);
}

// 按天分桶只保留最近 7 天：日期字符串字典序即时间序，删最旧的
function prune_days(map, keep) {
	let ks = sort(keys(map));
	while (length(ks) > (keep ?? 7)) {
		delete map[ks[0]];
		shift(ks);
	}
}

function appctl_roll_day() {
	let lt = localtime(time());
	let day = sprintf("%04d-%02d-%02d", lt.year, lt.mon, lt.mday);
	if (state.appctl.day == day) return;
	state.appctl.day = day;
	for (let mn, apps in state.appctl.stats)
		for (let app, v in apps) {
			v.today = 0;
			v.btoday = 0;
			if (v.days) prune_days(v.days);
			if (v.bdays) prune_days(v.bdays);
		}
	for (let mn, d in state.appctl.online)
		prune_days(d);
	for (let mn, d in state.appctl.ndata)
		prune_days(d);
	state._appstat_dirty = true;
}

function appctl_add_time(mn, app, dt, now) {
	if (!state.appctl.stats[mn]) state.appctl.stats[mn] = {};
	if (!state.appctl.stats[mn][app])
		state.appctl.stats[mn][app] = { today: 0, total: 0, last: 0 };
	let v = state.appctl.stats[mn][app];
	v.today += dt;
	v.total += dt;
	v.last = now;
	if (!v.days) v.days = {};
	v.days[state.appctl.day] = (v.days[state.appctl.day] ?? 0) + dt;
	state._appstat_dirty = true;
}

// 应用流量（字节）：按天分桶，与时长分开存放，老数据没有这些字段时按 0 处理
function appctl_add_bytes(mn, app, by, now) {
	if (by <= 0) return;
	if (!state.appctl.stats[mn]) state.appctl.stats[mn] = {};
	if (!state.appctl.stats[mn][app])
		state.appctl.stats[mn][app] = { today: 0, total: 0, last: 0 };
	let v = state.appctl.stats[mn][app];
	v.btoday = (v.btoday ?? 0) + by;
	v.btotal = (v.btotal ?? 0) + by;
	if (!v.bdays) v.bdays = {};
	v.bdays[state.appctl.day] = (v.bdays[state.appctl.day] ?? 0) + by;
	state._appstat_dirty = true;
}

// 终端总流量（含未识别应用），用于在界面上展示「其他」的用量
function appctl_add_traffic(mn, by) {
	if (by <= 0) return;
	if (!state.appctl.ndata[mn]) state.appctl.ndata[mn] = {};
	let d = state.appctl.ndata[mn];
	d[state.appctl.day] = (d[state.appctl.day] ?? 0) + by;
	state._appstat_dirty = true;
}

// 每轮取一次 nft counter 快照（包数与字节），达到阈值的应用才累加时长，
// 时间按实际差值累加（不按固定 TICK 累加，避免调度漂移累积误差）。
function appctl_sample() {
	if (state.cfg.role != "cap" || !state.appctl.enabled) return;
	let out = cmd_output(sprintf("nft -j list table inet %s 2>/dev/null", APPCTL_TABLE));
	if (out == "") return;
	let data;
	try { data = json(out); } catch (e) { return; }
	if (type(data) != "object" || type(data.nftables) != "array") return;

	let now = time();
	let dt = now - state._appstat_ts;
	if (!state._appstat_ts || dt <= 0 || dt > 180)
		dt = int(TICK_INTERVAL / 1000);

	let snap = state._nft_snap ?? {};
	let fresh = {};
	let owner = {};

	for (let item in data.nftables) {
		let r = item.rule;
		if (!r) continue;
		let p = split(r.comment ?? "", ":");
		if (length(p) != 4 || p[0] != "wr") continue;
		let mn = p[1], app = p[2], verdict = p[3];
		let pk = 0, by = 0;
		for (let e in r.expr)
			if (e.counter) {
				pk = int(e.counter.packets ?? 0);
				by = int(e.counter.bytes ?? 0);
				break;
			}
		// v4/v6 两条规则 comment 相同，必须累加；直接赋值会让后者覆盖前者
		let key = mn + "|" + app;
		let f = fresh[key];
		if (!f) {
			f = { pk: 0, by: 0, block: false };
			fresh[key] = f;
		}
		f.pk += pk;
		f.by += by;
		if (verdict == "block") f.block = true;
		owner[key] = [ mn, app ];
	}

	let deltas = {};
	for (let key, t in fresh) {
		let prev = snap[key];
		// 计数被清零（规则重建 / 服务重启）时跳过本轮，避免把归零当增量
		if (!prev || t.pk < prev.pk) continue;
		let dpk = t.pk - prev.pk;
		let dby = t.by - (prev.by ?? 0);
		if (dby < 0) dby = 0;
		let mn = owner[key][0], app = owner[key][1];
		// 被禁止的流量是「拦截尝试」，既不算流量也不算使用时长
		if (t.block) continue;
		let gkey = device_key(mn) + "|" + app;
		let d = deltas[gkey] ??= { key: device_key(mn), app, pk: 0, by: 0 };
		d.pk += dpk;
		d.by += dby;
	}
	for (let gkey, d in deltas) {
		if (d.app == "*") {
			appctl_add_traffic(d.key, d.by);
			continue;
		}
		appctl_add_bytes(d.key, d.app, d.by, now);
		// 同组多成员在一个窗口只累计一次时长；字节和包数先合并再判活跃。
		let active;
		if (appctl_enhanced())
			active = (d.pk >= APP_ACT_ENH_PK && d.by >= APP_ACT_ENH_BYTES);
		else
			active = (d.pk >= APP_ACT_MIN_PK || d.by >= APP_ACT_MIN_BYTES);
		if (active)
			appctl_add_time(d.key, d.app, dt, now);
	}

	state._nft_snap = fresh;
	state._appstat_ts = now;
}

function appstats_load() {
	try {
		let d = json(fs.readfile(APPSTATS_PATH));
		if (type(d) == "object") {
			state.appctl.stats = d.stats ?? {};
			state.appctl.day = d.day ?? "";
			state.appctl.online = d.online ?? {};
			state.appctl.ndata = d.ndata ?? {};
		}
	} catch (e) { /* first boot */ }
}

function appstats_save() {
	fs.mkdir(ALIAS_DIR);
	fs.writefile(APPSTATS_PATH, sprintf("%.J", {
		ver: 1, day: state.appctl.day, stats: state.appctl.stats,
		online: state.appctl.online, ndata: state.appctl.ndata,
	}));
	state._appstat_dirty = false;
	state._appstat_saved = time();
}

// 客户端常用 App 内置 HTTPDNS 或外部 DNS，dnsmasq 看不到这些查询，集合长期
// 只有零星 IP，规则自然拦不住。这里由路由器自己周期性解析应用域名：dnsmasq
// 的 nftset 对任何来源的应答都会写集合，等于替客户端补一次 DNS。
function appctl_warm_list() {
	let out = [];
	// 具体主机（probes）先解析：它们才是真正承载视频的 CDN 入口
	for (let a in APP_DEFS)
		for (let d in (a.probes ?? []))
			push(out, d);
	for (let a in APP_DEFS) {
		for (let d in a.domains) {
			push(out, d);
			push(out, "www." + d);
		}
	}
	return out;
}

function appctl_warm_step() {
	if (state._warm_list == null)
		state._warm_list = appctl_warm_list();
	let list = state._warm_list;
	if (!length(list)) return;
	let host = list[state._warm_i % length(list)];
	state._warm_i++;
	// 每个 tick 只解析一个主机，避免一次性几十次查询拖住主循环
	cmd_output(sprintf("timeout 3 nslookup %s 127.0.0.1 >/dev/null 2>&1", host));
}

function appctl_tick() {
	device_group_refresh();
	let regrouped = state._group_changed == true;
	state._group_changed = false;
	if (regrouped) appctl_read_devices();
	appctl_roll_day();
	online_sample();
	if (state.cfg.role == "cap" && state.appctl.enabled) {
		// 在线终端或设备组变化时重建规则；后者即使原始 MAC 集合不变，
		// 也可能改变每个 MAC 所继承的应用禁止策略。
		let set = appctl_track_macs();
		if (regrouped || join(",", sort(keys(set))) != state._track_key)
			appctl_apply_rules();
		if (regrouped) appctl_dpi_daemon("reload");
		appctl_warm_step();
		// 精准模式的 DNS 出口锁定：幂等，状态变化时才重建链
		appctl_dnslock_apply(appctl_enhanced());
	}
	if (regrouped) ban_apply(true);
	appctl_sample();
	if (state._appstat_dirty && time() - state._appstat_saved >= APPSTATS_FLUSH)
		appstats_save();
}

function appctl_load() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	state.appctl.enabled = cur.get("wifiroam", "appctl", "enabled") == "1";
	state.appctl.enhanced = cur.get("wifiroam", "appctl", "enhanced") == "1";
	state.appctl.strict = cur.get("wifiroam", "appctl", "strict") == "1";
	appctl_read_devices();
	appstats_load();
	if (state.cfg.role != "cap" || !state.appctl.enabled) {
		// 关闭状态也要把之前精准模式挂起的 hw offload 恢复回来
		if (state.cfg.role == "cap") {
			appctl_dpi_daemon("stop");
			appctl_hw_suspend(false);
		}
		return;
	}
	let schema_changed = appctl_nft_schema();
	appctl_apply_rules();
	appctl_dpi_daemon("start");
	appctl_dnslock_apply(appctl_enhanced());
	appctl_hw_suspend(appctl_enhanced());
	// 升级后新增了 v6 集合，需把 dnsmasq 的 ipset 段补齐（内容一致时不会重启）；
	// 集合结构刚被重建时也必须重启，让 dnsmasq 重新绑定新集合。
	// 两项检查必须都执行，不能在签名变化时短路而留下旧域名配置。
	let dnsmasq_changed = appctl_dnsmasq_sync(true);
	if (schema_changed || dnsmasq_changed)
		cmd_output("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
}

// ------------------------------------------------- flow offloading (network)
// 软件与硬件 offload 必须一起改：只关 hw 时软件 flowtable 依然会绕过规则。
// 值未变化时不 reload，避免跨 AP 每次同步都重建 flowtable 打断在用连接。
function offload_apply(on) {
	// The satellite controller owns its forwarding path, including HNAT.
	if (state.cfg.role == "sap" && mesh.managed()) return !on;
	let cur = uci.cursor();
	cur.load("firewall");
	if (cur.get("firewall", "@defaults[0]") == null) return false;
	let want = on ? "1" : "0";
	if (cur.get("firewall", "@defaults[0]", "flow_offloading") == want &&
	    cur.get("firewall", "@defaults[0]", "flow_offloading_hw") == want)
		return true;
	cur.set("firewall", "@defaults[0]", "flow_offloading", want);
	cur.set("firewall", "@defaults[0]", "flow_offloading_hw", want);
	mesh.writeConfig(cur, "firewall", state.cfg.role);
	// reload 会重建 flowtable，已 offload 的旧流随之清空，避免规则长期不生效
	cmd_output("/etc/init.d/firewall reload >/dev/null 2>&1");
	return true;
}

// SAP 侧：转发不在本机，开关必须交由 CAP 统一执行，再由 CAP 广播回全部子 AP
function offload_request_cap(on) {
	let link = state.link;
	if (!link?.authed) return false;
	try {
		link.chan.defer({
			method: "set_offload",
			data: { enabled: on ? true : false },
			data_cb: function() {}, cb: function() {},
		});
	} catch (e) { return false; }
	return true;
}

// ---------------------------------------------------------- self / sys info
// 由 LAN ip/mask 计算定向广播地址。网关设备默认路由走 WAN，
// 发 255.255.255.255 会被路由到 WAN 侧，必须用定向广播才能落在 LAN。
function lan_broadcast(ip, mask) {
	let parts = split(ip ?? "", ".");
	if (length(parts) != 4) return "255.255.255.255";
	let v = 0;
	for (let p in parts) v = (v << 8) | (int(p) & 255);
	let m = int(mask);
	// ucode 无 >>> 运算符；0xffffffff 在 int64 下为正数，>> 等效逻辑右移
	let hostmask = (m > 0 && m < 32) ? (0xffffffff >> m) : 0xff;
	let b = (v | hostmask) & 0xffffffff;
	return sprintf("%d.%d.%d.%d", (b >> 24) & 255, (b >> 16) & 255,
	               (b >> 8) & 255, b & 255);
}

// 本机所有网络接口 MAC：用于把 AP 自身的接口（如无线回程 STA 口）
// 从"下挂终端"中排除，避免 AP 被同时计为终端导致数量虚高
function local_iface_macs() {
	let out = {};
	for (let f in fs.glob("/sys/class/net/*/address")) {
		if (index(f, "/lo/") >= 0) continue;
		let m = macnorm(trim(fs.readfile(f) ?? ""));
		if (length(m) == 12 && m != "000000000000") out[m] = true;
	}
	return out;
}

function detect_self() {
	let st = ubusc.call("network.interface.lan", "status");
	let dev = st?.device ?? st?.l3_device ?? "br-lan";
	state.brdev = dev;
	let ip = st?.["ipv4-address"]?.[0]?.address ?? null;
	// GWRT: 子AP / 未配置设备广播能到主AP 的源地址（br-lan 地址主AP 可能不可达）
	if (state.cfg.role != "cap") {
		let src = trim(cmd_output("ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \\([0-9.]*\\).*/\\1/p'"));
		if (src != "" && src != "1.1.1.1") ip = src;
	}
	let mask = st?.["ipv4-address"]?.[0]?.mask ?? 24;
	state.bcast = lan_broadcast(ip, mask);
	let mac = trim(fs.readfile(`/sys/class/net/${dev}/address`) ?? "");
	if (length(macnorm(mac)) != 12) {
		for (let f in fs.glob("/sys/class/net/*/address")) {
			if (index(f, "/lo/") >= 0) continue;
			let m = trim(fs.readfile(f) ?? "");
			if (length(macnorm(m)) == 12) { mac = m; break; }
		}
	}
	let rel = fs.readfile("/etc/openwrt_release") ?? "";
	let fw = "OpenWrt";
	let m = match(rel, /DISTRIB_DESCRIPTION='([^']+)'/);
	if (m) fw = m[1];

	state.self = {
		mac: uc(mac),
		ip,
		hostname: trim(fs.readfile("/proc/sys/kernel/hostname") ?? "OpenWrt"),
		model: trim(fs.readfile("/tmp/sysinfo/model") ?? "OpenWrt device"),
		firmware: fw,
		nonce: randhex(16),
		ifaces: local_iface_macs(),
	};
	state.self.name = state.cfg.name != "" ? state.cfg.name : state.self.hostname;
	log(sprintf("self: %s %s %s", state.self.mac, state.self.ip ?? "?", state.self.name));
}

// 无线回程检测：优先看本插件托管的 STA 接口，其次看其它已关联的 STA。
// 仅当 STA 真实关联（iw link 显示 Connected）才算无线上行，避免把
// "配置了但没连上" 的接口误报成回程。
function wireless_uplink() {
	let ws = ubusc.call("network.wireless", "status") ?? {};
	let fallback = null;
	for (let rname, r in ws) {
		for (let ifc in r.interfaces ?? []) {
			if (ifc.config?.mode != "sta" || !ifc.ifname) continue;
			let link = cmd_output(sprintf("iw dev %s link 2>/dev/null", ifc.ifname));
			if (index(link, "Connected to") < 0) continue;
			let m = match(link, /Connected to ([0-9a-fA-F:]+)/);
			let s = match(link, /signal:\s*(-?[0-9]+)/);
			let info = {
				type: "wireless", port: ifc.ifname,
				ssid: ifc.config?.ssid ?? null,
				bssid: m ? lc(m[1]) : null,
				rssi: s ? int(s[1]) : null,
			};
			if (ifc.section == BACKHAUL_SECTION) return info;
			if (!fallback) fallback = info;
		}
	}
	return fallback;
}

function detect_uplink() {
	let phase = mesh.readPhase().mode;
	let out = cmd_output("ip route show default 2>/dev/null");
	let words = split(trim(split(out, "\n")[0] ?? ""), " ");
	let gw = field_after(words, "via");
	let dev = field_after(words, "dev");
	if (state.cfg.role == "sap" && phase == "wired")
		return { type: "wired", port: dev ?? "br-lan", gw };
	let wireless = dev && (fs.access(`/sys/class/net/${dev}/wireless`) ||
	                       index(dev, "wlan") == 0 || index(dev, "wl") == 0);
	let wl = wireless_uplink();
	// 本插件托管的无线回程已关联时，回程类型以它为准（即使物理上还有网线）
	if (wl && (wl.port == BACKHAUL_SECTION || current_backhaul_cfg().enabled))
		return { type: "wireless", port: wl.port, gw, ssid: wl.ssid,
		         bssid: wl.bssid, rssi: wl.rssi };
	return { type: wireless ? "wireless" : "wired", port: dev, gw };
}

function self_uptime() {
	return int(split(trim(fs.readfile("/proc/uptime") ?? "0"), " ")[0]);
}

// GWRT: 隐藏回传 AP（wifiroam_bh / wifiroam_bh2）是组网专用，不能当用户热点
function is_backhaul_sec(name) {
	return name != null && index(name, BACKHAUL_SECTION) == 0;
}

function wifi_ifaces() {
	let out = [];
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.disabled == "1") return;
		if (s.wifiroam_guest == "1") return;   // 访客口不算主人网络
		if (is_backhaul_sec(s[".name"])) return;   // 回传 AP 不参与前台 SSID 展示/下发
		push(out, {
			ssid: s.ssid ?? "",
			encryption: s.encryption ?? "none",
			band: cur.get("wireless", s.device, "band") ?? "?",
			device: s.device,
			section: s[".name"],
		});
	});
	return out;
}

// GWRT: 主AP 本机各频段的 SSID/密码，组网成功后自动下发给成员 AP。
// 上游只在「无线设置」保存那一刻推送，配对完成不会自动同步。
function wifi_push_spec() { return front.settings(); }

// 本机各 AP 口的 11k 邻居报告元素：直接取 hostapd 自己生成的 NR（含正确的
// op_class / channel / PHY 类型），避免自行推算信道分组出错，也保证与 AP
// 实际信道一致（5G 信道在各 AP 上并不相同）。
function ap_nr_self() {
	let out = [];
	let ws = null;
	try { ws = ubusc.call("network.wireless", "status") ?? {}; } catch (e) { return out; }
	for (let rname, r in ws) {
		for (let ifc in r.interfaces ?? []) {
			if (!ifc.ifname) continue;
			if (ifc.config?.mode && ifc.config.mode != "ap") continue;
			let own = null, st = null;
			try {
				own = ubusc.call("hostapd." + ifc.ifname, "rrm_nr_get_own");
				st = ubusc.call("hostapd." + ifc.ifname, "get_status");
			} catch (e) { continue; }
			let v = own?.value;
			if (type(v) != "array" || length(v) < 3) continue;
			push(out, {
				ifname: ifc.ifname,
				bssid: lc(v[0]),
				ssid: v[1] ?? "",
				nr: v[2],
				band: int(st?.freq ?? 0) < 3000 ? "2g" : "5g",
				channel: st?.channel ?? null,
			});
		}
	}
	return out;
}

// 可广播给对端的部分（不含本机网卡名，对端不能直接调用本机 hostapd）
function ap_nr_public() {
	let out = [];
	for (let e in ap_nr_self())
		push(out, { bssid: e.bssid, ssid: e.ssid, nr: e.nr,
		            band: e.band, channel: e.channel });
	return out;
}

function self_info() {
	return {
		mac: state.self.mac, ip: state.self.ip,
		name: state.self.name, hostname: state.self.hostname,
		model: state.self.model, firmware: state.self.firmware,
		role: state.cfg.role, uptime: self_uptime(),
		ifaces: state.self.ifaces ?? {},
		wifi: wifi_ifaces(), uplink: detect_uplink(),
		backhaul: state.cfg.role == "sap" ? mesh.backhaulReport() : null,
		nr: ap_nr_public(),
	};
}

// ------------------------------------------------------- Wi-Fi 前台设置
// 读取本机所有 AP 口的 SSID / 是否设了密码，供「无线设置」表单回填。
// unified 表示「多频合一」：所有 AP 口同名且同密码（密码不对外返回）
function wifi_summary() {
	let cur = uci.cursor();
	cur.load("wireless");
	let ifaces = [];
	let has_key = false;
	let unified = true;
	let first_ssid = null, first_key = null;
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.wifiroam_guest == "1" || is_backhaul_sec(s[".name"])) return;
		let ssid = s.ssid ?? "";
		let key = s.key ?? "";
		push(ifaces, {
			section: s[".name"], device: s.device, ssid: ssid,
			encryption: s.encryption ?? "none",
			band: cur.get("wireless", s.device, "band") ?? "?",
		});
		if (key != "") has_key = true;
		if (first_ssid == null) { first_ssid = ssid; first_key = key; }
		else if (ssid != first_ssid || key != first_key) unified = false;
	});
	let first = ifaces[0];
	// 只显示第一组 SSID，多口不一致时标记出来，避免把不同 SSID 合并成假象
	let mixed = false;
	for (let i in ifaces)
		if (i.ssid != (first?.ssid ?? "")) mixed = true;
	return {
		ssid: first?.ssid ?? "", has_key: has_key, mixed: mixed,
		unified: unified, ifaces: ifaces,
	};
}

// 改本机全部 AP 口的 SSID 与密码。ssids = [{ band, ssid, key }]，同频段的接口取同名同密码。
// 某一项的 key 为空表示该频段只改名称、不动密码。无线重启放在后台：
// 前端请求先返回，避免重启把连接断开导致界面误判失败。
function apply_wifi_local(ssids) {
	// GWRT: 强制退出 AP 模式（gwrt.mesh_apmode=0）时忽略主AP 的 SSID/密码下发，
	// 保持路由模式自己的 SSID
	let gc = uci.cursor();
	gc.load("gwrt");
	if (gc.get("gwrt", "mesh_apmode", "enabled") == "0")
		return { ok: true, count: 0 };
	let cur = uci.cursor();
	cur.load("wireless");
	let n = 0;
	let before = mesh.wirelessVersion();
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.wifiroam_guest == "1") return;   // 访客口由访客面板单独管理
		if (is_backhaul_sec(s[".name"])) return;   // 隐藏回传 AP 必须保持原 SSID
		let band = cur.get("wireless", s.device, "band") ?? "?";
		let want = null;
		for (let it in ssids)
			if (it.band == band) want = it;
		if (want == null) return;
		if (want.ssid != "" && s.ssid != want.ssid)
			cur.set("wireless", s[".name"], "ssid", want.ssid);
		if (want.key != "") {
			cur.set("wireless", s[".name"], "key", want.key);
			// 开放网络加密为 none/空时补上 WPA2，否则设了密码也不生效
			let enc = s.encryption ?? "";
			if (enc == "" || enc == "none")
				cur.set("wireless", s[".name"], "encryption", "psk2");
		}
		n++;
	});
	mesh.writeConfig(cur, "wireless", state.cfg.role);
	if (mesh.wirelessVersion() != before)
		cmd_output("( sleep 2; /sbin/wifi reload >/dev/null 2>&1 ) >/dev/null 2>&1 & echo ok");
	return { ok: n > 0, count: n };
}

// 漫游组里记录的 SSID 必须跟着改名，否则 802.11k/v/r 会因找不到同名 SSID 失效。
// pairs = [{ old, new }]：按「旧名 -> 新名」替换，并把仍是新名的条目补齐，
// 避免两个频段同名时连续重命名把另一个频段的组从列表里挤掉。
function roam_rename_ssids(pairs) {
	let hit = 0;
	for (let p in pairs)
		if (p.old != "" && p.old != p.new) hit++;
	if (hit == 0) return;

	let cur = uci.cursor();
	cur.load("wifiroam");
	let raw = cur.get("wifiroam", "roam", "ssids") ?? [];
	let list = [];
	if (type(raw) == "array") list = raw;
	else if (raw != "") list = [ raw ];

	let out = [];
	for (let s in list) {
		let mapped = s;
		for (let p in pairs)
			if (p.old == s && p.new != "") { mapped = p.new; break; }
		push(out, mapped);
	}
	for (let p in pairs)
		if (p.new != "" && index(out, p.new) < 0) push(out, p.new);
	// 两个频段并成一组合一时，替换后可能留下重复项
	let dedup = [];
	for (let s in out)
		if (index(dedup, s) < 0) push(dedup, s);
	cur.set("wifiroam", "roam", "ssids", dedup);
	cur.commit("wifiroam");
}

// GWRT: 老 GWRT 主AP 把 SSID/密码塞在 push_roam_config 的 wifi 字段里一起下发，
// 上游 v5 只认独立的 push_wifi_config。这里把两者收敛成同一套校验/落地逻辑。
function apply_wifi_from_cap(list) {
	return front.sync(list, state.cfg.role);
}


// ------------------------------------------------------- 访客网络
// 每台 AP 建一个独立访客子网（172.16.10.0/24）+ 自己的 DHCP + 隔离防火墙区。
// 主AP 保存后把 SSID/密码/限速/时段推给已配对 AP，各 AP 本地落地。
function hhmm_minutes(s) {
	let f = split(trim(s ?? ""), ":");
	if (length(f) != 2) return null;
	let h = int(f[0]), m = int(f[1]);
	if (h < 0 || h > 23 || m < 0 || m > 59) return null;
	return h * 60 + m;
}

function now_minutes() {
	let s = trim(cmd_output("date +%H:%M"));
	return hhmm_minutes(s) ?? 0;
}

function guest_cfg() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	return {
		enabled: cur.get("wifiroam", GUEST_SECTION, "enabled") == "1",
		ssid: cur.get("wifiroam", GUEST_SECTION, "ssid") ?? GUEST_DEFAULT_SSID,
		key: cur.get("wifiroam", GUEST_SECTION, "key") ?? "",
		bandwidth: int(cur.get("wifiroam", GUEST_SECTION, "bandwidth") ?? "0"),
		schedule: cur.get("wifiroam", GUEST_SECTION, "schedule") == "1",
		start: cur.get("wifiroam", GUEST_SECTION, "start") ?? "08:00",
		end: cur.get("wifiroam", GUEST_SECTION, "end") ?? "23:00",
		allow_lan: cur.get("wifiroam", GUEST_SECTION, "allow_lan") == "1",
		ver: int(cur.get("wifiroam", GUEST_SECTION, "config_ver") ?? "0"),
	};
}

// 开放时段判断：start <= end 为当天区间，否则视为跨零点（如 22:00-07:00）
function guest_open_now(cfg) {
	if (!cfg.enabled) return false;
	if (!cfg.schedule) return true;
	let a = hhmm_minutes(cfg.start), b = hhmm_minutes(cfg.end);
	if (a == null || b == null) return true;
	let t = now_minutes();
	if (a <= b) return t >= a && t < b;
	return t >= a || t < b;
}

function guest_summary() {
	let g = guest_cfg();
	let cur = uci.cursor();
	cur.load("wireless");
	let ifaces = [], open = guest_open_now(g);
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.wifiroam_guest != "1") return;
		push(ifaces, {
			section: s[".name"], device: s.device,
			band: cur.get("wireless", s.device, "band") ?? "?",
			disabled: s.disabled == "1",
		});
	});
	return {
		role: state.cfg.role,
		enabled: g.enabled, ssid: g.ssid, has_key: g.key != "",
		bandwidth: g.bandwidth,
		schedule: g.schedule, start: g.start, end: g.end,
		allow_lan: g.allow_lan, open: open, ifaces: ifaces,
		last: state.last_guest ?? null,
	};
}

function mask_prefix(m) {
	if (index(m ?? "", ".") < 0) return int(m ?? "24");
	let parts = split(m, ".");
	let bits = 0;
	for (let i = 0; i < 4; i++) {
		let v = int(parts[i] ?? "0");
		for (let b = 7; b >= 0; b--) {
			if (v & (1 << b)) bits++;
			else return bits;
		}
	}
	return bits;
}

// "192.168.0.1" + "255.255.255.0" -> "192.168.0.0/24"
function ipv4_cidr(ipmask, mask) {
	let a = split(ipmask ?? "", "/");
	let ip = a[0];
	let prefix = (a[1] != null && a[1] != "") ? int(a[1]) : mask_prefix(mask ?? "255.255.255.0");
	let host = 32 - prefix;
	if (host < 0) host = 0;
	if (host > 31) host = 31;
	let parts = split(ip, ".");
	let ipint = 0;
	for (let i = 0; i < 4; i++) ipint = (ipint * 256) + int(parts[i] ?? "0");
	let div = 1 << host;
	let net = ipint - (ipint % div);
	let o = [];
	let v = net;
	for (let i = 0; i < 4; i++) { push(o, "" + (v % 256)); v = int(v / 256); }
	return sprintf("%s.%s.%s.%s/%d", o[3], o[2], o[1], o[0], prefix);
}

function guest_lan_info() {
	let cur = uci.cursor();
	cur.load("network");
	/* lan 的 ipaddr 可能是 list（本机即 list ipaddr），get() 会返回数组。
	   注意 get_first 的第二参数是 section 类型（interface）而不是段名，
	   这里统一用 get + 数组取首值最稳妥 */
	let pick = function(v) {
		if (type(v) == "array") return v[0];
		return v;
	};
	let ip = pick(cur.get("network", "lan", "ipaddr")) ?? "192.168.0.1";
	let nm = pick(cur.get("network", "lan", "netmask")) ?? "255.255.255.0";
	let gw = pick(cur.get("network", "lan", "gateway"));
	return {
		cidr: ipv4_cidr(ip, nm),
		ip: split(ip, "/")[0],
		gw: gw != null ? split(gw, "/")[0] : state.self.ip,
	};
}

// 已配置的访客 BSS 内核接口名（如 phy0-ap1）。netdev 名不固定，必须按
// SSID 反查，不能假定是 ap1。
function guest_netdevs(ssid) {
	let out = [], cur = null;
	let data = cmd_output("iw dev 2>/dev/null");
	for (let line in split(data, "\n")) {
		let mi = match(line, /^\s*Interface ([^\s]+)/);
		if (mi) { cur = mi[1]; continue; }
		if (cur == null) continue;
		let ms = match(line, /^\s*ssid (.+)$/);
		if (ms && trim(ms[1]) == ssid) push(out, cur);
	}
	return out;
}

// 把访客 SSID/密码/开关写入本机 wireless；时段外保持 disabled
function guest_write_wireless(cfg) {
	let open = guest_open_now(cfg);
	let wc = uci.cursor();
	wc.load("wireless");
	let keep = {};
	let radios = [];
	wc.foreach("wireless", "wifi-device", function(d) {
		push(radios, d[".name"]);
	});
	for (let rname in radios) {
		let sid = GUEST_SEC_PREFIX + rname;
		keep[sid] = true;
		if (wc.get("wireless", sid) == null)
			wc.set("wireless", sid, "wifi-iface");
		wc.set("wireless", sid, "device", rname);
		wc.set("wireless", sid, "mode", "ap");
		wc.set("wireless", sid, "ssid", cfg.ssid != "" ? cfg.ssid : GUEST_DEFAULT_SSID);
		if (cfg.key != "") {
			wc.set("wireless", sid, "encryption", "psk2");
			wc.set("wireless", sid, "key", cfg.key);
		} else {
			wc.set("wireless", sid, "encryption", "none");
			wc.delete("wireless", sid, "key");
		}
		wc.set("wireless", sid, "network", GUEST_IFACE);
		wc.set("wireless", sid, "wifiroam_guest", "1");
		wc.set("wireless", sid, "disabled", (cfg.enabled && open) ? "0" : "1");
	}
	let stale = [];
	wc.foreach("wireless", "wifi-iface", function(s) {
		if (s.wifiroam_guest != "1") return;
		if (!keep[s[".name"]]) push(stale, s[".name"]);
	});
	for (let sid in stale) wc.delete("wireless", sid);
	mesh.writeConfig(wc, "wireless", state.cfg.role);
	return open;
}

// 关闭访客网络时删除残留的桥/接口/DHCP/防火墙段（nft 与 tc 由 after_reload 清理）
function guest_remove_infra() {
	let nc = uci.cursor();
	nc.load("network");
	nc.delete("network", GUEST_IFACE);
	nc.delete("network", GUEST_DEV);
	mesh.writeConfig(nc, "network", state.cfg.role);

	let dc = uci.cursor();
	dc.load("dhcp");
	dc.delete("dhcp", GUEST_IFACE);
	mesh.writeConfig(dc, "dhcp", state.cfg.role);

	let fc = uci.cursor();
	fc.load("firewall");
	fc.foreach("firewall", "zone", function(z) {
		if (z.name == "guest" && z.network == GUEST_IFACE)
			fc.delete("firewall", z[".name"]);
	});
	fc.delete("firewall", GUEST_ZONE);
	for (let r in [ "wifiroam_guest_dhcp", "wifiroam_guest_dns_u", "wifiroam_guest_dns_t",
	                GUEST_FWD_WAN, GUEST_FWD_LAN, GUEST_SNAT ])
		fc.delete("firewall", r);
	mesh.writeConfig(fc, "firewall", state.cfg.role);
}

// 访客桥 / 接口 / DHCP / 防火墙。桥本身固定 br-guest，端口由 guest_port_sync 填。
function guest_write_infra(cfg) {
	let nc = uci.cursor();
	nc.load("network");
	if (nc.get("network", GUEST_DEV) == null)
		nc.set("network", GUEST_DEV, "device");
	nc.set("network", GUEST_DEV, "type", "bridge");
	nc.set("network", GUEST_DEV, "name", GUEST_BRIDGE);
	if (nc.get("network", GUEST_IFACE) == null)
		nc.set("network", GUEST_IFACE, "interface");
	nc.set("network", GUEST_IFACE, "proto", "static");
	nc.set("network", GUEST_IFACE, "device", GUEST_BRIDGE);
	nc.set("network", GUEST_IFACE, "ipaddr", GUEST_IP);
	nc.set("network", GUEST_IFACE, "netmask", "255.255.255.0");
	mesh.writeConfig(nc, "network", state.cfg.role);

	let dc = uci.cursor();
	dc.load("dhcp");
	if (dc.get("dhcp", GUEST_IFACE) == null)
		dc.set("dhcp", GUEST_IFACE, "dhcp");
	dc.set("dhcp", GUEST_IFACE, "interface", GUEST_IFACE);
	dc.set("dhcp", GUEST_IFACE, "start", "10");
	dc.set("dhcp", GUEST_IFACE, "limit", "100");
	dc.set("dhcp", GUEST_IFACE, "leasetime", "12h");
	/* 本机 dnsmasq 的 dhcpv4/dhcpv6 默认值是 disabled，不显式置 server 就不出 dhcp-range。
	   访客只有 IPv4，DHCPv6/RA 全部关闭。force 跳过 br-guest 上的 udhcpc 探测。 */
	dc.set("dhcp", GUEST_IFACE, "dhcpv4", "server");
	dc.set("dhcp", GUEST_IFACE, "dhcpv6", "disabled");
	dc.set("dhcp", GUEST_IFACE, "force", "1");
	mesh.writeConfig(dc, "dhcp", state.cfg.role);

	let fc = uci.cursor();
	fc.load("firewall");
	let zsec = null;
	fc.foreach("firewall", "zone", function(z) {
		if (z.name == "guest" && zsec == null) zsec = z[".name"];
	});
	if (zsec == null) { zsec = GUEST_ZONE; fc.set("firewall", zsec, "zone"); }
	fc.set("firewall", zsec, "name", "guest");
	/* 访客区只用 device 定义，不能写 network / subnet：
	   1) 写 network 时 fw4 会把访客物理设备（br-guest / phy*-ap1）自动加进
	      flowtable，流量被（硬件）卸载后绕过 qdisc，限速失效；
	   2) 写 subnet 时 fw4 会给 input 链加 "ip saddr 172.16.10.0/24" 条件，
	      DHCPDISCOVER 的源地址是 0.0.0.0，匹配不上就进不了 input_guest，
	      DHCP 放行规则不生效，访客拿不到 IP。
	   只写 device 时 related_physdevs / related_subnets 都为空，不会进
	   flowtable、也不带 saddr；NAT 由 srcnat_wan 的全局 masq 处理。 */
	fc.delete("firewall", zsec, "network");
	fc.delete("firewall", zsec, "subnet");
	fc.set("firewall", zsec, "device", GUEST_BRIDGE);
	fc.set("firewall", zsec, "input", "REJECT");
	fc.set("firewall", zsec, "output", "ACCEPT");
	fc.set("firewall", zsec, "forward", "REJECT");

	// input 默认 REJECT，只放行访客自己需要的 DHCP 与 DNS
	let rules = [
		{ sec: "wifiroam_guest_dhcp",    proto: "udp", port: "67" },
		{ sec: "wifiroam_guest_dns_u",   proto: "udp", port: "53" },
		{ sec: "wifiroam_guest_dns_t",   proto: "tcp", port: "53" },
	];
	for (let r in rules) {
		if (fc.get("firewall", r.sec) == null) fc.set("firewall", r.sec, "rule");
		fc.set("firewall", r.sec, "name", r.sec);
		fc.set("firewall", r.sec, "src", "guest");
		fc.set("firewall", r.sec, "proto", r.proto);
		fc.set("firewall", r.sec, "dest_port", r.port);
		fc.set("firewall", r.sec, "target", "ACCEPT");
		fc.set("firewall", r.sec, "family", "ipv4");
		fc.set("firewall", r.sec, "enabled", "1");
	}

	let is_sap = state.cfg.role == "sap";
	/* 主AP 走 wan 出口；子AP 是二层桥接 AP，没有自己的 wan，改由
	   guest→lan 转发 + SNAT。不用的 forwarding 直接删除，避免 fw4 每次
	   reload 报「section is disabled」 */
	if (!is_sap) {
		if (fc.get("firewall", GUEST_FWD_WAN) == null)
			fc.set("firewall", GUEST_FWD_WAN, "forwarding");
		fc.set("firewall", GUEST_FWD_WAN, "src", "guest");
		fc.set("firewall", GUEST_FWD_WAN, "dest", "wan");
		fc.set("firewall", GUEST_FWD_WAN, "enabled", "1");
	} else {
		fc.delete("firewall", GUEST_FWD_WAN);
	}

	if (is_sap || cfg.allow_lan) {
		if (fc.get("firewall", GUEST_FWD_LAN) == null)
			fc.set("firewall", GUEST_FWD_LAN, "forwarding");
		fc.set("firewall", GUEST_FWD_LAN, "src", "guest");
		fc.set("firewall", GUEST_FWD_LAN, "dest", "lan");
		fc.set("firewall", GUEST_FWD_LAN, "enabled", "1");
	} else {
		fc.delete("firewall", GUEST_FWD_LAN);
	}

	// 子AP 的“外网”其实走 lan 桥到主AP，必须放行 guest→lan 并做 SNAT，
	// 否则主AP 没有访客子网的回程路由。
	// 不能用 uci 的 nat 段：fw4 按出接口归 zone，src=guest 的规则只会出现在
	// "oifname br-guest" 的 srcnat_guest 链里，反而会把去访客的下行包 SNAT 掉。
	// SNAT 改由 guest_nft_apply 写在自建表（oifname 为 lan 侧）。
	fc.delete("firewall", GUEST_SNAT);
	mesh.writeConfig(fc, "firewall", state.cfg.role);
}

// 独立 nft 表做访客→内网的兜底拦截（fw4 的 accept 规则之前生效）。
// 允许访客访问内网资源时整表删除。
// 注意：本机 nft 的 -f 文件模式不能解析 table/chain 声明，必须先建表与链。
function guest_nft_apply(cfg) {
	let info = guest_lan_info();
	let snat_ip = info.ip != "" ? info.ip : state.self.ip;
	let sig = (cfg.enabled ? "1" : "0") + "|" + (cfg.allow_lan ? "1" : "0") + "|" +
	          (state.cfg.role ?? "") + "|" + snat_ip + "|" + info.cidr;
	if (sig == state._guest_nft_sig) return;
	state._guest_nft_sig = sig;

	cmd_output(sprintf("nft delete table inet %s 2>/dev/null", GUEST_NFT_TABLE));
	if (!cfg.enabled) return;
	cmd_output(sprintf("nft add table inet %s 2>/dev/null", GUEST_NFT_TABLE));

	/* 子AP 没有独立 wan：访客流量经 br-lan 送主AP，必须在本机 SNAT 成 lan
	   地址，主AP 才能把回包按访客子网送回。fw4 的 nat 段按出接口归 zone，
	   覆盖不到这个方向，所以放在自建表里做。 */
	if (state.cfg.role == "sap" && snat_ip != "") {
		cmd_output(sprintf(
			"nft add chain inet %s nat '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null",
			GUEST_NFT_TABLE));
		cmd_output(sprintf("nft add rule inet %s nat ip saddr %s oifname %s snat ip to %s 2>/dev/null",
			GUEST_NFT_TABLE, GUEST_NET, state.brdev, snat_ip));
	}

	if (cfg.allow_lan) return;
	/* 链名不能用 fwd：nft 把 fwd 当保留字，会报 unexpected fwd */
	cmd_output(sprintf(
		"nft add chain inet %s guard '{ type filter hook forward priority -20; policy accept; }' 2>/dev/null",
		GUEST_NFT_TABLE));
	cmd_output(sprintf("nft add rule inet %s guard iifname %s ip daddr %s drop 2>/dev/null",
		GUEST_NFT_TABLE, GUEST_BRIDGE, info.cidr));
}

function guest_client_ips() {
	let out = [], seen = {};
	let netprefix = split(GUEST_NET, "/")[0];
	netprefix = substr(netprefix, 0, length(netprefix) - length(split(netprefix, ".")[3]) - 1) + ".";
	let data = fs.readfile("/tmp/dhcp.leases") ?? "";
	for (let line in split(data, "\n")) {
		let f = split(trim(line), " ");
		if (length(f) < 4) continue;
		let ip = f[2];
		if (index(ip, netprefix) != 0 || ip == GUEST_IP || seen[ip]) continue;
		seen[ip] = true; push(out, ip);
	}
	let neigh = cmd_output("ip neigh show dev " + GUEST_BRIDGE + " 2>/dev/null");
	for (let line in split(neigh, "\n")) {
		let m = match(line, /^([0-9.]+)\s/);
		if (!m) continue;
		let ip = m[1];
		if (index(ip, netprefix) != 0 || ip == GUEST_IP || seen[ip]) continue;
		seen[ip] = true; push(out, ip);
	}
	return out;
}

// 清理已不需要 qdisc 的访客 netdev；桥上的旧 qdisc 一并删除（历史版本挂在桥上）
function guest_tc_cleanup(keep) {
	for (let d in state.guest_tc_devs) {
		if (keep != null && index(keep, d) >= 0) continue;
		cmd_output("tc qdisc del dev " + d + " root 2>/dev/null");
	}
	cmd_output("tc qdisc del dev " + GUEST_BRIDGE + " root 2>/dev/null");
	state.guest_tc_devs = keep ?? [];
}

// 每台访客设备下行限速：qdisc 必须挂在具体的访客 netdev 上。
// 挂在 br-guest 上的方案实测无效——桥转发（br_dev_xmit）发出的报文不经过
// 桥设备自身的根 qdisc，桥端口才是真正的出队点，所以限制完全不生效。
function guest_tc_apply(cfg) {
	let bw = cfg.bandwidth ?? 0;
	let ports = (cfg.enabled && bw > 0) ? guest_netdevs(cfg.ssid) : [];

	if (length(ports) == 0) {
		// 关闭/时段外/无线还没起来：清掉旧规则，等下一轮再建
		if (length(state.guest_tc_devs) > 0 ||
		    match(cmd_output("tc qdisc show dev " + GUEST_BRIDGE + " 2>/dev/null"), /htb/)) {
			state.guest_tc_sig = "";
			guest_tc_cleanup([]);
		}
		return;
	}

	let ips = guest_client_ips();
	let sig = "" + bw;
	for (let p in ports) sig += "|d" + p;
	for (let ip in ips) sig += "|" + ip;

	let have = true;
	for (let p in ports) {
		if (index(cmd_output("tc qdisc show dev " + p + " 2>/dev/null"), "htb") < 0) {
			have = false;
			break;
		}
	}
	if (sig == state.guest_tc_sig && have) return;
	state.guest_tc_sig = sig;
	guest_tc_cleanup(ports);

	for (let p in ports) {
		cmd_output(sprintf("tc qdisc add dev %s root handle 1: htb default 20 2>/dev/null", p));
		// 默认类同样按限速值：拿不到终端 IP（静态 IP、租约未落盘、刚入网）时
		// 流量会落到这里，若仍给 2Gbit 就等于完全不限
		cmd_output(sprintf("tc class add dev %s parent 1: classid 1:20 htb rate %dkbit ceil %dkbit 2>/dev/null",
			p, bw * 1000, bw * 1000));
		let i = 20;
		for (let ip in ips) {
			i++;
			let cid = "1:" + i;
			cmd_output(sprintf("tc class add dev %s parent 1: classid %s htb rate %dkbit ceil %dkbit 2>/dev/null",
				p, cid, bw * 1000, bw * 1000));
			cmd_output(sprintf("tc filter add dev %s parent 1: protocol ip prio 1 u32 match ip dst %s/32 flowid %s 2>/dev/null",
				p, ip, cid));
		}
	}
}

// 无线重启后 netdev 才会出现，先按 SSID 找到接口再挂到 br-guest
guest_port_sync = function(cfg, cb, tries) {
	tries = tries ?? 0;
	let open = guest_open_now(cfg);
	if (!cfg.enabled) {
		let nc = uci.cursor();
		nc.load("network");
		nc.delete("network", GUEST_DEV);
		mesh.writeConfig(nc, "network", state.cfg.role);
		if (cb) cb();
		return;
	}
	let ports = (cfg.enabled && open) ? guest_netdevs(cfg.ssid) : [];
	if (length(ports) == 0 && cfg.enabled && open && tries < 10) {
		uloop.timer(1000, function() { guest_port_sync(cfg, cb, tries + 1); });
		return;
	}
	let nc = uci.cursor();
	nc.load("network");
	if (nc.get("network", GUEST_DEV) == null)
		nc.set("network", GUEST_DEV, "device");
	nc.set("network", GUEST_DEV, "type", "bridge");
	nc.set("network", GUEST_DEV, "name", GUEST_BRIDGE);
	if (length(ports) > 0)
		nc.set("network", GUEST_DEV, "ports", ports);
	else
		nc.delete("network", GUEST_DEV, "ports");
	mesh.writeConfig(nc, "network", state.cfg.role);
	if (cb) cb();
};

guest_after_reload = function(cfg) {
	uloop.process("/etc/init.d/dnsmasq", [ "reload" ], null,
		function() {});
	uloop.process("/etc/init.d/firewall", [ "reload" ], null, function() {
		guest_nft_apply(cfg);
		state.guest_tc_sig = "";
		guest_tc_apply(cfg);
	});
};

// 本机落地：写 wireless / network / dhcp / firewall，再异步重启无线并补齐桥端口
apply_guest_local = function(cfg) {
	state.guest_open = guest_open_now(cfg);
	guest_write_wireless(cfg);
	if (cfg.enabled)
		guest_write_infra(cfg);
	else
		guest_remove_infra();

	uloop.process("/etc/init.d/network", [ "reload" ], null, function() {});
	uloop.process("/sbin/wifi", [ "reload" ], null, function(res) {
		log("guest wifi reload rc=" + res);
		guest_port_sync(cfg, function() {
			uloop.process("/etc/init.d/network", [ "reload" ], null, function() {
				guest_after_reload(cfg);
			});
		}, 0);
	});
	return { ok: true };
};

// 校验并写入本机 wifiroam.guest（主AP/子AP 都走这里）
guest_save_local = function(g) {
	let enabled = g.enabled ? true : false;
	let ssid = trim(g.ssid ?? "");
	let key = g.open ? "" : (g.key ?? "");
	let start = trim(g.start ?? "08:00");
	let end = trim(g.end ?? "23:00");
	if (enabled && (length(ssid) < 1 || length(ssid) > 32)) return false;
	if (key != "" && (length(key) < 8 || length(key) > 64)) return false;
	if (hhmm_minutes(start) == null || hhmm_minutes(end) == null) return false;

	let cur = uci.cursor();
	cur.load("wifiroam");
	if (cur.get("wifiroam", GUEST_SECTION) == null)
		cur.set("wifiroam", GUEST_SECTION, "guest");
	cur.set("wifiroam", GUEST_SECTION, "enabled", enabled ? "1" : "0");
	cur.set("wifiroam", GUEST_SECTION, "ssid",
		ssid != "" ? ssid : GUEST_DEFAULT_SSID);
	cur.set("wifiroam", GUEST_SECTION, "key", key);
	cur.set("wifiroam", GUEST_SECTION, "bandwidth", "" + int(g.bandwidth ?? 0));
	cur.set("wifiroam", GUEST_SECTION, "schedule", g.schedule ? "1" : "0");
	cur.set("wifiroam", GUEST_SECTION, "start", start);
	cur.set("wifiroam", GUEST_SECTION, "end", end);
	cur.set("wifiroam", GUEST_SECTION, "allow_lan", g.allow_lan ? "1" : "0");
	cur.set("wifiroam", GUEST_SECTION, "config_ver", "" + int(g.ver ?? 0));
	cur.commit("wifiroam");
	return true;
};

// 定时检查开放时段；只在跨过边界时重启无线。限速规则每轮同步一次
guest_tick = function() {
	if (state.cfg.role == "unconfigured") return;
	if (state.cfg.role == "sap" && mesh.managed()) return;
	let g = guest_cfg();
	if (!g.enabled) {
		state.guest_open = false;
		state.guest_tc_sig = "";
		guest_nft_apply(g);
		return;
	}
	/* 旧版本访客区用 option network / subnet 定义（会让 vif 进 flowtable、
	   并给 DHCP 加上 saddr 限制），子AP 还留着无效的 uci nat 段；
	   进程升级后做一次性迁移 */
	if (state._guest_zone_migrated != true) {
		let mc = uci.cursor();
		mc.load("firewall");
		state._guest_zone_migrated = true;
		if (mc.get("firewall", GUEST_ZONE, "network") != null ||
		    mc.get("firewall", GUEST_ZONE, "subnet") != null ||
		    (state.cfg.role == "sap" && mc.get("firewall", GUEST_SNAT) != null)) {
			guest_write_infra(g);
			cmd_output("/etc/init.d/firewall reload 2>/dev/null");
			state._guest_nft_sig = "";
		}
	}
	/* 进程重启后内核里的 nft 表可能丢失（设备重启），按需补建/清理 */
	guest_nft_apply(g);
	let open = guest_open_now(g);
	if (state.guest_open == null) { state.guest_open = open; return; }
	if (open == state.guest_open) { guest_tc_apply(g); return; }
	state.guest_open = open;

	let wc = uci.cursor();
	wc.load("wireless");
	wc.foreach("wireless", "wifi-iface", function(s) {
		if (s.wifiroam_guest != "1") return;
		wc.set("wireless", s[".name"], "disabled", open ? "0" : "1");
	});
	mesh.writeConfig(wc, "wireless", state.cfg.role);
	push_event("guest_schedule", "", open ? "open" : "closed");
	uloop.process("/sbin/wifi", [ "reload" ], null, function() {
		guest_port_sync(g, function() {
			uloop.process("/etc/init.d/network", [ "reload" ], null, function() {
				guest_after_reload(g);
			});
		}, 0);
	});
};

// ------------------------------------------------------- client collection
function freq_band(f) {
	if (!f) return null;
	if (f < 3000) return "2g";
	if (f < 5900) return "5g";
	return "6g";
}

function parse_leases() {
	let out = {};
	let data = fs.readfile("/tmp/dhcp.leases");
	if (!data) return out;
	for (let line in split(data, "\n")) {
		let f = split(trim(line), " ");
		if (length(f) < 4) continue;
		let mn = macnorm(f[1]);
		if (length(mn) != 12) continue;
		out[mn] = {
			ip: f[2], hostname: f[3] != "*" ? f[3] : null,
			expires: int(f[0]) ?? 0,
			clientid: length(f) >= 5 && f[4] != "*" ? f[4] : null,
		};
	}
	return out;
}

function parse_neigh() {
	let out = {};
	let data = cmd_output(`ip neigh show dev ${state.brdev} 2>/dev/null`);
	for (let line in split(data, "\n")) {
		let f = split(trim(line), " ");
		if (length(f) < 3) continue;
		let ip = f[0];
		let mac = field_after(f, "lladdr");
		let st = f[length(f) - 1];
		if (!mac || index(ip, ":") >= 0) continue;      // ipv4 only
		if (st == "FAILED" || st == "INCOMPLETE") continue;
		out[macnorm(mac)] = { ip };
	}
	return out;
}

// CAP 下发的终端名称表：SAP 上没有 DHCP 服务，/tmp/dhcp.leases 为空，
// 只能由 CAP 把租约里的主机名/IP 同步过来，子 AP 拓扑才能显示名称
function client_names() {
	let out = {};
	for (let mn, n in parse_neigh())
		out[mn] = { ip: n.ip };
	for (let mn, l in parse_leases())
		out[mn] = { hostname: l.hostname, ip: l.ip };
	return out;
}

// brctl showstp 输出 "lan6 (7)"：端口号 → 接口名。
// ImmortalWrt 默认不装 iproute2 的 bridge 命令，只能走 brctl 读 MAC 表。
function bridge_port_names() {
	let map = {};
	let data = cmd_output(`brctl showstp ${state.brdev} 2>/dev/null`);
	for (let line in split(data, "\n")) {
		let m = match(line, /^([^\s]+) \(([0-9]+)\)/);
		if (m) map[m[2]] = m[1];
	}
	return map;
}

function parse_fdb() {
	let out = {};
	let data = cmd_output(`bridge fdb show br ${state.brdev} 2>/dev/null`);
	if (data != "") {
		for (let line in split(data, "\n")) {
			let f = split(trim(line), " ");
			if (length(f) < 3) continue;
			let mn = macnorm(f[0]);
			if (length(mn) != 12) continue;
			if (index(f, "self") >= 0 || index(f, "permanent") >= 0) continue;
			let port = field_after(f, "dev");
			if (!port) continue;
			out[mn] = port;
		}
		return out;
	}

	let pnames = bridge_port_names();
	data = cmd_output(`brctl showmacs ${state.brdev} 2>/dev/null`);
	// brctl 的列分隔符是 TAB（且年龄列前有额外空格），必须按任意空白分割
	for (let line in split(data, "\n")) {
		let f = split(trim(line), /[ \t]+/);
		if (length(f) < 3) continue;
		let mn = macnorm(f[1]);
		if (length(mn) != 12) continue;
		if (f[2] == "yes") continue;   // 网桥自身接口 MAC
		out[mn] = pnames[f[0]] ?? f[0];
	}
	return out;
}

// 各站点的累计字节数（iw station dump）：用于由两次采样差分出实时上下行速率。
// hostapd 的 get_clients 只给信号/协商速率，没有字节计数，故单独取一次。
function station_bytes(ifname) {
	let now = time();
	let cache = state.bytes_cache[ifname];
	if (cache && now - cache.ts <= 1) return cache.map;

	let out = {};
	let data = cmd_output(`iw dev ${ifname} station dump 2>/dev/null`);
	let mac = null, rx = 0, tx = 0;

	for (let line in split(data, "\n")) {
		let t = trim(line);
		if (substr(t, 0, 8) == "Station ") {
			if (mac) out[mac] = { rx, tx };
			mac = macnorm(substr(t, 8, 17));
			rx = 0; tx = 0;
		}
		else if (mac && substr(t, 0, 9) == "rx bytes:") {
			rx = int(trim(substr(t, 9))) ?? 0;
		}
		else if (mac && substr(t, 0, 9) == "tx bytes:") {
			tx = int(trim(substr(t, 9))) ?? 0;
		}
	}
	if (mac) out[mac] = { rx, tx };

	state.bytes_cache[ifname] = { ts: now, map: out };
	return out;
}

local_clients = function() {
	let clients = {};
	let now = time();

	// AP 自身接口 MAC（含无线回程 STA 口）不是终端：对端 AP 用无线回程接入时，
	// 其 STA 口会在本机 hostapd 客户端表里出现，若不排除会与 AP 节点重复计数
	let excl = {};
	for (let m in keys(state.self.ifaces ?? {})) excl[m] = true;
	for (let pmn, p in state.peers)
		for (let m in keys(p.info?.ifaces ?? {})) excl[m] = true;

	// wireless stations via hostapd ubus
	let ifmap = {};
	let ws = ubusc.call("network.wireless", "status");
	for (let rname, r in ws ?? {}) {
		let band = r.config?.band;
		for (let ifc in r.interfaces ?? []) {
			if (ifc.ifname)
				ifmap[ifc.ifname] = { ssid: ifc.config?.ssid, band };
		}
	}
	// hostapd ubus 对象名为 hostapd.<ifname>；ubus list(pattern) 在本平台
	// 返回签名表而非名称，故按 ifname 直接拼装
	for (let ifname in keys(ifmap)) {
		let res = ubusc.call("hostapd." + ifname, "get_clients");
		if (!res?.clients) continue;
		let bytes = station_bytes(ifname);
		for (let mac, ci in res.clients) {
			let mn = macnorm(mac);
			if (excl[mn]) continue;   // AP 自身接口，不是终端
			clients[mn] = {
				mac: uc(mac), type: "wifi", ifname,
				ssid: ifmap[ifname]?.ssid,
				band: ifmap[ifname]?.band ?? freq_band(res.freq),
				rssi: ci.signal ?? null,
				connected_time: ci.connected_time ?? null,
				// hostapd 上报的 rate 单位是 100 kbit/s（驱动速率 ×100），
				// 除以 100000 换算为 Mbps（如 7220000 -> 72.2 Mbps）；
				// 注意 ucode 整数相除会截断，必须用浮点字面量
				tx_rate: ci.rate?.tx != null ? ci.rate.tx / 100000.0 : null,
				rx_rate: ci.rate?.rx != null ? ci.rate.rx / 100000.0 : null,
				// 实时速率（Mbps）：由站点字节计数两次采样差分得到。
				// rx_speed = 终端 → AP（终端发送），tx_speed = AP → 终端（终端接收）
				rx_speed: null, tx_speed: null,
			};
			state.wifi_seen[mn] = now;

			let b = bytes[mn];
			if (!b) continue;

			let prev = state.client_bytes[mn];
			if (prev && now > prev.ts) {
				let dt = now - prev.ts;
				// 计数回退（终端重连/计数器复位）时本轮不出速率。
				// 关键：ucode 整数相除会截断（全 int 运算时 <1Mbps 的速率
				// 全被截成 0），必须用浮点字面量 8.0 提升精度
				if (b.rx >= prev.rx)
					clients[mn].rx_speed = (b.rx - prev.rx) * 8.0 / dt / 1000000;
				if (b.tx >= prev.tx)
					clients[mn].tx_speed = (b.tx - prev.tx) * 8.0 / dt / 1000000;
			}
			state.client_bytes[mn] = { ts: now, rx: b.rx, tx: b.tx };
		}
	}

	// ip/hostname enrichment + wired clients
	let leases = parse_leases();
	let neigh = parse_neigh();
	let fdb = parse_fdb();

	// 无线网桥端口集合。FDB 会记录无线站点 MAC（端口为 phy*-ap*），
	// 终端漫游/换频段的一瞬间会从 hostapd 客户端表消失，但 FDB 仍保留
	// 数分钟，若据此判为有线，手机就会被显示成"有线连接"。凡是学自无线
	// 端口的 MAC 一律不当作有线终端。
	let wlan_port = {};
	for (let name in keys(ifmap)) wlan_port[name] = true;

	for (let mn, l in leases) {
		if (clients[mn]) {
			clients[mn].ip = l.ip;
			clients[mn].hostname = l.hostname;
		}
	}
	for (let mn, n in neigh) {
		if (clients[mn] && !clients[mn].ip) clients[mn].ip = n.ip;
	}
	// SAP：用 CAP 下发的名称表补全主机名/IP（本机无 DHCP 租约）
	for (let mn, n in state.net_names ?? {}) {
		if (!clients[mn]) continue;
		if (clients[mn].hostname == null && n.hostname != null)
			clients[mn].hostname = n.hostname;
		if (clients[mn].ip == null && n.ip != null)
			clients[mn].ip = n.ip;
	}

	let self_mn = macnorm(state.self.mac);

	// 级联/上行口：其他 AP（peers/discovered）的 MAC 在 FDB 中所处的端口，
	// 其下游终端由对端 AP 自行上报，本机不再计为终端
	// （否则对端 WiFi 终端会被本机 FDB 从上行口学成 wired 幻影，漫游后长期挂在旧 AP 下）
	let cascade = {};
	for (let mn, p in state.peers) {
		let pt = fdb[mn];
		if (pt) cascade[pt] = true;
		// 无线回程/桥接的 SAP 可能只暴露其 STA/AP 接口 MAC，
		// 这些 MAC 所在的网桥端口同样是"通往对端 AP"的级联口
		for (let m in keys(p.info?.ifaces ?? {})) {
			let q = fdb[m];
			if (q) cascade[q] = true;
		}
	}
	for (let mn in keys(state.discovered)) {
		let pt = fdb[mn];
		if (pt) cascade[pt] = true;
	}

	// 有线终端在线依据只用 FDB（帧级存活，~5min 老化）：
	// DHCP lease（12h）与 ARP STALE 长期残留，会把已离线设备算进来；
	// wired_seen 提供 WIRED_TTL 滞后，防止 FDB 老化边缘抖动
	let seen = state.wired_seen;
	for (let mn, port in fdb) {
		if (mn == self_mn) continue;
		if (excl[mn]) { delete seen[mn]; continue; }      // AP 自身接口
		if (substr(mn, 0, 6) == "01005e" || substr(mn, 0, 4) == "3333") continue;
		if (substr(mn, 0, 6) == "0180c2") continue;       // L2 控制帧（STP/LLDP 等）
		// AP 节点或级联口下游：立即从有线表清除，避免重启初期对端尚未
		// 上报时被记成有线终端后残留 WIRED_TTL 那么久
		if (state.peers[mn] || state.discovered[mn]) { delete seen[mn]; continue; }
		if (cascade[port]) { delete seen[mn]; continue; } // 对端 AP 下游
		if (wlan_port[port]) { delete seen[mn]; continue; } // 无线网桥口学到的是无线终端
		// 最近仍作为无线站点出现过（漫游/换频段的空档期）：不降级为有线
		let wf = state.wifi_seen[mn];
		if (wf != null && now - wf <= WIRED_TTL) { delete seen[mn]; continue; }
		seen[mn] = now;
	}
	for (let mn in keys(state.wifi_seen))
		if (now - state.wifi_seen[mn] > WIRED_TTL * 2) delete state.wifi_seen[mn];
	for (let mn in keys(seen)) {
		if (now - seen[mn] > WIRED_TTL) {
			delete seen[mn];
			continue;
		}
		if (clients[mn]) continue;                        // already wifi
		clients[mn] = {
			mac: maccolon(mn), type: "wired",
			ip: leases[mn]?.ip ?? neigh[mn]?.ip ?? state.net_names?.[mn]?.ip ?? null,
			hostname: leases[mn]?.hostname ?? state.net_names?.[mn]?.hostname ?? null,
			port: fdb[mn] ?? null,
		};
	}

	// first-seen tracking
	for (let mn in keys(clients)) {
		if (!state.client_seen[mn]) state.client_seen[mn] = now;
		clients[mn].since = state.client_seen[mn];
	}
	return clients;
};

// ------------------------------------------------------- physical device groups
function device_host_key(v) {
	return lc(trim(replace(v ?? "", /[_ ]+/g, "-")));
}

function device_generic_host(v) {
	let h = device_host_key(v);
	return h == "" || index([
		"*", "unknown", "localhost", "android", "iphone", "ipad",
		"windows", "desktop", "laptop", "openwrt", "huawei", "xiaomi", "redmi"
	], h) >= 0;
}

function device_group_auto(g) {
	for (let mn in keys(g.members ?? {}))
		if (state.aliases.isolated[mn]) return false;
	return true;
}

function device_new_group(mn, salt) {
	let gid;
	for (let i = 0; i < 20; i++) {
		gid = "g" + substr(sha256(sprintf("device:%s:%s:%d", mn, salt ?? "", i)), 0, 12);
		if (!state.aliases.groups[gid]) break;
	}
	let now = time(), members = {};
	members[mn] = { first_seen: now, last_seen: now };
	state.aliases.groups[gid] = { created: now, members };
	state.device_index[mn] = gid;
	return gid;
}

function device_merge_groups(a, b) {
	// 保留创建较早的组 ID；即使当前代表 MAC 或频段改变，配置键也不变。
	if ((state.aliases.groups[a].created ?? 0) > (state.aliases.groups[b].created ?? 0)) {
		let t = a; a = b; b = t;
	}
	let ga = state.aliases.groups[a], gb = state.aliases.groups[b];
	for (let mn, meta in gb.members ?? {}) {
		ga.members[mn] = meta;
		state.device_index[mn] = a;
	}
	if (!state.aliases.map[a] && state.aliases.map[b])
		state.aliases.map[a] = state.aliases.map[b];
	delete state.aliases.map[b];
	delete state.aliases.groups[b];
	state.aliases.redirect[b] = a;
	push_event("device_merge", maccolon(keys(gb.members ?? {})[0] ?? ""),
	           "→ " + a, device_alias_of(a)?.name ?? "");
	return a;
}

function device_merge_evidence(a, b) {
	let ga = state.aliases.groups[a], gb = state.aliases.groups[b];
	if (!device_group_auto(ga) || !device_group_auto(gb)) return null;
	let simultaneous = false;
	for (let ma in keys(ga.members ?? {}))
		for (let mb in keys(gb.members ?? {}))
			if (state.device_obs[ma]?.online && state.device_obs[mb]?.online)
				simultaneous = true;

	for (let ma, ma_meta in ga.members ?? {}) {
		for (let mb, mb_meta in gb.members ?? {}) {
			// 实时观测缺主机名/IP 时回退到成员元数据（上次在线时的记录），
			// 否则离线设备永远匹配不上双频规则。
			let oa = state.device_obs[ma] ?? {}, ob = state.device_obs[mb] ?? {};
			let ha = device_host_key(oa.hostname ?? ma_meta.hostname);
			let hb = device_host_key(ob.hostname ?? mb_meta.hostname);
			let same_host = !device_generic_host(ha) && ha == hb;
			let ca = lc(trim(oa.clientid ?? ma_meta.clientid ?? ""));
			let cb = lc(trim(ob.clientid ?? mb_meta.clientid ?? ""));
			if (same_host && length(ca) >= 4 && ca == cb && ca != "*")
				return "dhcp_clientid";

			let aa = device_alias_of(ma), ab = device_alias_of(mb);
			let an = device_host_key(aa?.name), bn = device_host_key(ab?.name);
			if (!device_generic_host(an) && an == bn)
				return "custom_alias";

			// 同一台设备的 2.4G/5G 双频：多数手机每个 SSID 各用一个私有 MAC，
			// 两个 MAC 的主机名相同但 IP、DHCP clientid 都不同。只要没有同时
			// 在线（换频段时旧连接通常先消失），就按同一台设备合并。
			if (same_host && !simultaneous)
				return "dual_band";

			// 同 IP 在短时间内由旧随机 MAC 交给新随机 MAC，且没有双端同时在线。
			// 只比较最近 15 分钟的接替，避免 DHCP 地址自然复用造成误并。
			let ia = oa.ip ?? ma_meta.ip, ib = ob.ip ?? mb_meta.ip;
			if (same_host && !simultaneous && ia && ia == ib) {
				let delta = (oa.ip_ts ?? ma_meta.ip_ts ?? 0) - (ob.ip_ts ?? mb_meta.ip_ts ?? 0);
				if (delta < 0) delta = -delta;
				if (delta <= 900) return "lease_handover";
			}
		}
	}
	return null;
}

device_group_refresh = function() {
	if (state.cfg.role != "cap") return;
	let now = time(), obs = {}, changed = false;
	let leases = parse_leases();
	for (let mn, l in leases) {
		// 出厂 MAC 也要进 obs：它可能和同名随机 MAC 组是同一台设备
		obs[mn] = {
			hostname: l.hostname, ip: l.ip, clientid: l.clientid,
			expires: l.expires, ip_ts: now, last_seen: now, online: false,
		};
	}
	let all = local_clients();
	for (let pmn, p in state.peers)
		for (let mn, c in p.clients ?? {}) all[mn] ??= c;
	for (let mn, c in all) {
		let o = obs[mn] ??= { ip_ts: now };
		if (c.hostname) o.hostname = c.hostname;
		if (c.ip) { o.ip = c.ip; o.ip_ts = now; }
		o.last_seen = now;
		o.online = true;
	}
	// 已持久化成员在离线期间也保留最后一次租约证据，供下次接替判断。
	for (let gid, g in state.aliases.groups)
		for (let mn, meta in g.members ?? {})
			if (!obs[mn]) {
				obs[mn] = meta;
				obs[mn].online = false;
			}
	state.device_obs = obs;

	for (let mn, o in obs) {
		if (!mac_is_random(mn)) continue;
		let gid = state.device_index[mn];
		if (!gid || !state.aliases.groups[gid]) {
			gid = device_new_group(mn, "");
			changed = true;
		}
		let meta = state.aliases.groups[gid].members[mn] ??= { first_seen: now };
		for (let k in [ "hostname", "ip", "clientid", "expires", "ip_ts", "last_seen", "online" ])
			if (o[k] != null) meta[k] = o[k];
	}

	// 一轮可能形成 A+B、再与 C 合并；每次只接受强证据，人工拆分组不参与。
	let merged = true;
	while (merged) {
		merged = false;
		let gids = sort(keys(state.aliases.groups));
		for (let i = 0; i < length(gids) && !merged; i++) {
			for (let j = i + 1; j < length(gids); j++) {
				let a = device_key(gids[i]), b = device_key(gids[j]);
				if (a == b || !state.aliases.groups[a] || !state.aliases.groups[b]) continue;
				if (!device_merge_evidence(a, b)) continue;
				device_merge_groups(a, b);
				changed = merged = true;
				break;
			}
		}
	}
	// 出厂 MAC 与随机 MAC 的跨频段合并：同一台设备可能在 2.4G 用出厂 MAC、
	// 5G 用随机 MAC，而出厂 MAC 自己不会建组，需要并入同名（非通用名）的
	// 随机 MAC 组，否则终端列表会出现两条记录。
	for (let mn, o in obs) {
		if (mac_is_random(mn) || state.device_index[mn]) continue;
		if (state.aliases.isolated[mn]) continue;   // 人工拆分过的不再自动合并
		let rh = o.hostname ?? state.net_names?.[mn]?.hostname;
		if (!rh || device_generic_host(rh)) continue;
		let h = device_host_key(rh);
		let best = null, best_online = false;
		for (let gid, g in state.aliases.groups) {
			if (!device_group_auto(g)) continue;
			for (let mb, meta in g.members ?? {}) {
				if (!mac_is_random(mb)) continue;
				if (device_host_key(obs[mb]?.hostname ?? meta.hostname ?? "") != h) continue;
				let on = !!(obs[mb]?.online);
				if (best == null || (on && !best_online)) {
					best = gid;
					best_online = on;
				}
			}
		}
		// 两端同时在线时可能真是两台同型号设备，宁可不并
		if (best == null || (o.online && best_online)) continue;
		state.aliases.groups[best].members[mn] = {
			first_seen: o.last_seen ?? now, hostname: rh, ip: o.ip,
			last_seen: o.last_seen, online: o.online,
		};
		state.device_index[mn] = best;
		changed = true;
	}
	device_reindex();
	if (changed) {
		state._group_changed = true;
		state.aliases.ver = now;
		alias_save();
		alias_broadcast();
	}
};

function device_ungroup(mac) {
	let mn = macnorm(mac);
	let old = device_key(mn), g = state.aliases.groups[old];
	if (!g?.members?.[mn]) return { ok: false, error: "not_found" };
	let now = time();
	// 出厂 MAC 只是被自动并入同名随机 MAC 组：移出并标记隔离即可恢复
	// 独立设备（它本来就不参与随机 MAC 分组），不必再建组。
	if (!mac_is_random(mn)) {
		delete g.members[mn];
		state.aliases.isolated[mn] = true;
		device_reindex();
		state.aliases.ver = now;
		alias_save();
		alias_broadcast();
		return { ok: true, id: mn, mac: maccolon(mn), isolated: true };
	}
	delete g.members[mn];
	state.aliases.isolated[mn] = true;
	let gid = device_new_group(mn, "split:" + now);
	if (!length(keys(g.members))) {
		delete state.aliases.groups[old];
		state.aliases.redirect[old] = gid;
		if (state.aliases.map[old]) {
			state.aliases.map[gid] = state.aliases.map[old];
			delete state.aliases.map[old];
		}
	}
	device_reindex();
	state.aliases.ver = now;
	alias_save();
	alias_broadcast();
	return { ok: true, id: gid, mac: maccolon(mn), isolated: true };
}

// 参与统计/管控的终端：已配置 appdev 的设备 + 本机在线终端 + 对端 AP 上报的终端。
// 若只给「配置过禁止应用」的设备建规则，其余终端没有任何 counter，时长永远为 0。
appctl_track_macs = function() {
	let set = {};
	for (let key in state.appctl.devices)
		for (let mn in device_members_of(key)) set[mn] = true;
	let lc = local_clients();
	for (let mn in lc) set[mn] = true;
	for (let pmn, p in state.peers)
		for (let mn in (p.clients ?? {})) set[mn] = true;
	return set;
};

// 在线时长按天累计：CAP 每 tick 给当前在线终端（本机 + SAP 上报）加窗口秒数，
// 与 appctl 开关无关，供「上网统计」的昨日/今日/过去七天查询
online_sample = function() {
	if (state.cfg.role != "cap") return;
	let now = time();
	let dt = now - (state._online_ts ?? 0);
	if (!state._online_ts || dt <= 0 || dt > 180)
		dt = int(TICK_INTERVAL / 1000);
	state._online_ts = now;

	let seen = {};
	let lc = local_clients();
	for (let mn in lc) seen[mn] = true;
	for (let pmn, p in state.peers)
		for (let mn in (p.clients ?? {})) seen[mn] = true;

	let day = state.appctl.day, groups = {};
	for (let mn in seen) groups[device_key(mn)] = true;
	for (let key in groups) {
		if (!state.appctl.online[key]) state.appctl.online[key] = {};
		state.appctl.online[key][day] = (state.appctl.online[key][day] ?? 0) + dt;
	}
	if (length(keys(groups))) state._appstat_dirty = true;
};

function diff_events(prev, cur, apname) {
	for (let mn in keys(cur))
		if (!prev[mn]) push_event("client_join", maccolon(mn), apname, client_name_of(mn, cur));
	for (let mn in keys(prev))
		if (!cur[mn]) push_event("client_leave", maccolon(mn), apname, client_name_of(mn, prev));
}

// ------------------------------------------------------------- UDP discovery
function udp_send(obj) {
	if (!udp_sock) return;
	udp_sock.send(sprintf("%.J", obj), 0,
		{ address: state.bcast ?? "255.255.255.255", port: UDP_PORT });
	if ((state.bcast ?? "") != "255.255.255.255")
		udp_sock.send(sprintf("%.J", obj), 0, { address: "255.255.255.255", port: UDP_PORT });
}

function refresh_self_addr() {
	let a = mesh.localAddress(ubusc, state.cfg.role, mesh.readPhase().mode);
	if (!a || !state.self) return;
	state.self.ip = a.address;
	state.bcast = lan_broadcast(a.address, a.mask ?? 24);
}

function send_hello() {
	let gc = uci.cursor();
	if (state.cfg.role != "cap" && gc.get("gwrt", "mesh_apmode", "enabled") == "0") return;
	refresh_self_addr();
	udp_send({
		magic: MAGIC, ver: 1, role: state.cfg.role,
		mac: state.self.mac, ip: state.self.ip,
		name: state.self.name, model: state.self.model,
		nonce: state.self.nonce,
		thash: mesh.pairingHash(state.cfg.token),
		alias_ver: state.aliases.ver, ts: time(),
	});
}

function udp_rx() {
	while (true) {
		let pkt = mesh.receive(udp_sock);
		if (!pkt) break;
		let data = pkt.data;
		let peer = pkt.address ?? {};
		let msg;
		try { msg = json(data); } catch (e) { continue; }
		if (type(msg) != "object" || msg.magic != MAGIC) continue;
		let mn = macnorm(msg.mac);
		if (length(mn) != 12 || mn == macnorm(state.self.mac)) continue;

		if (msg.role == "unconfigured") {
			state.discovered[mn] = {
				mac: uc(msg.mac), ip: msg.ip ?? peer.address,
				name: msg.name, model: msg.model,
				nonce: msg.nonce, last_seen: time(),
			};
			continue;
		}

		let my_th = mesh.pairingHash(state.cfg.token);
		if (state.cfg.token == "" || msg.thash != my_th) continue; // foreign net
		mesh.observeCap(pkt, msg, state.cfg, my_th);

		let p = state.peers[mn] ??= { clients: null }; // null = 未收过 report，首轮 diff 抑制
		p.mac = uc(msg.mac);
		p.ip = msg.ip ?? peer.address;
		p.name = msg.name;
		p.model = msg.model;
		p.role = msg.role;
		p.last_seen = time();
		if (msg.role == "cap" && msg.ip)
			state.cap_learned = msg.ip;
	}
}

function expire_tick() {
	let now = time();
	for (let mn in keys(state.peers)) {
		if (now - (state.peers[mn].last_seen ?? 0) > PEER_TTL) {
			let p = state.peers[mn];
			push_event("ap_offline", maccolon(mn), p.name ?? "");
			if (p.chan) p.chan.disconnect();
			delete state.peers[mn];
		}
	}
	for (let mn in keys(state.discovered))
		if (now - state.discovered[mn].last_seen > DISCOVER_TTL)
			delete state.discovered[mn];
}

function setup_udp() {
	udp_sock = socket.create(socket.AF_INET,
		socket.SOCK_DGRAM | socket.SOCK_NONBLOCK, 0);
	if (!udp_sock) { log("udp create failed"); return; }
	udp_sock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	udp_sock.setopt(socket.SOL_SOCKET, socket.SO_BROADCAST, true);
	if (!mesh.enableIngress(udp_sock)) log("could not enable UDP ingress tracking");
	if (!udp_sock.bind("0.0.0.0:" + UDP_PORT)) {
		log("udp bind failed: " + socket.error());
		udp_sock.close(); udp_sock = null;
		exit(1);   // 传输不可用 = 守护进程无意义，fail-fast 交 procd 处置
	}
	uloop.handle(udp_sock.fileno(), udp_rx, uloop.ULOOP_READ);
}

// ---------------------------------------------------------- topology build
function ap_display(mn) {
	if (mn == macnorm(state.self.mac)) return state.self.name;
	let p = state.peers[mn];
	return p ? (p.info?.name ?? p.name ?? maccolon(mn)) : maccolon(mn);
}

// 终端归属表：同一终端可能被多个 AP 的 FDB 学到（对端 WiFi 终端会被
// SAP 侧报成 wired），按 mac 去重，归属优先级：wifi > wired，本机 > 对端
function compute_owner(my, self_mn) {
	let owner = {};
	for (let pass in [ "wifi", "wired" ]) {
		for (let mn, c in my)
			if (!owner[mn] && (c.type ?? "wired") == pass)
				owner[mn] = self_mn;
		for (let pmn, p in state.peers)
			for (let mn, c in p.clients ?? {})
				if (!owner[mn] && (c.type ?? "wired") == pass)
					owner[mn] = pmn;
	}
	return owner;
}

// CAP 视角跨 AP 迁移事件：归属从一台 AP 变到另一台 => roam_move
//（各 AP 本地的 join/leave 事件照旧保留，roam_move 是网络视角的结论）
function owner_events(my) {
	if (state.cfg.role != "cap") return;
	let owner = compute_owner(my, macnorm(state.self.mac));
	if (state.prev_owner != null)
		for (let mn, ap in owner) {
			let old = state.prev_owner[mn];
			if (old != null && old != ap)
				push_event("roam_move", maccolon(mn),
					sprintf("%s → %s", ap_display(old), ap_display(ap)),
					client_name_of(mn, my));
		}
	state.prev_owner = owner;
}

function client_node(mn, c, parent) {
	let key = device_key(mn), al = device_alias_of(key);
	let pin = pin_of(mn);
	let members = [];
	for (let member in device_members_of(key)) push(members, maccolon(member));
	return {
		id: key, type: "client",
		name: (al?.name != null && al.name != "") ? al.name :
		      (c.hostname ?? maccolon(mn)),
		custom_name: (al?.name != null && al.name != "") ? al.name : null,
		hostname: c.hostname ?? null,
		ip: c.ip ?? null, mac: c.mac ?? maccolon(mn),
		members, grouped: length(members) > 1,
		isolated: state.aliases.isolated[mn] == true,
		parent,
		conn: {
			type: c.type, band: c.band ?? null, ssid: c.ssid ?? null,
			rssi: c.rssi ?? null,
			tx_rate: c.tx_rate ?? null, rx_rate: c.rx_rate ?? null,
			// 实时速率（Mbps），由站点字节计数差分得到；无采样时为 null
			tx_speed: c.tx_speed ?? null, rx_speed: c.rx_speed ?? null,
			port: c.port ?? null, since: c.since ?? null,
		},
		icon: al?.icon ?? null, note: al?.note ?? null,
		pin, pin_name: pin ? ap_display(pin) : null,
	};
}

function build_topology() {
	let nodes = [];
	let now = clock(true)[0];
	let self_mn = macnorm(state.self.mac);
	device_group_refresh();
	let myclients = local_clients();

	let ap_nodes = {};
	let self_al = state.aliases.map[self_mn];
	let self_node = {
		id: self_mn, type: "ap", role: state.cfg.role,
		name: (self_al?.name != null && self_al.name != "") ? self_al.name : state.self.name,
		custom_name: (self_al?.name != null && self_al.name != "") ? self_al.name : null,
		model: state.self.model,
		ip: state.self.ip, mac: state.self.mac,
		parent: null, uplink: detect_uplink(),
		firmware: state.self.firmware, uptime: self_uptime(),
		clients: [],
	};
	push(nodes, self_node);
	ap_nodes[self_mn] = self_node;

	let peer_clients = {};
	for (let mn, p in state.peers) {
		let pal = state.aliases.map[mn];
		let pname = (pal?.name != null && pal.name != "") ? pal.name
		                                                 : (p.info?.name ?? p.name ?? mn);
		let n = {
			id: mn, type: "ap",
			role: p.info?.role ?? p.role ?? "sap",
			name: pname,
			custom_name: (pal?.name != null && pal.name != "") ? pal.name : null,
			model: p.info?.model ?? p.model ?? null,
			ip: p.info?.ip ?? p.ip, mac: p.mac ?? maccolon(mn),
			parent: self_mn,
			uplink: p.info?.uplink ?? null,
			backhaul: mesh.peerBackhaul(state.cfg.role, p, now),
			firmware: p.info?.firmware ?? null,
			uptime: p.info?.uptime ?? null,
			authed: !!p.authed,
			clients: [],
		};
		push(nodes, n);
		ap_nodes[mn] = n;
		peer_clients[mn] = p.clients ?? {};
	}

	// 按 mac 去重归属（规则见 compute_owner）
	let owner = compute_owner(myclients, self_mn);
	// 对端（SAP）无 DHCP 服务，其上报终端可能缺 ip/hostname，
	// 用本机 leases/ARP 补全，保证各 AP 下挂设备信息一致
	let leases = parse_leases();
	let neigh = parse_neigh();
	let grouped = {};
	for (let mn, ap in owner) {
		let c = (ap == self_mn ? myclients : peer_clients[ap])[mn];
		if (c.ip == null)
			c.ip = leases[mn]?.ip ?? neigh[mn]?.ip ?? state.net_names?.[mn]?.ip ?? null;
		if (c.hostname == null)
			c.hostname = leases[mn]?.hostname ?? state.net_names?.[mn]?.hostname ?? null;
		let key = device_key(mn);
		let old = grouped[key];
		let prefer = !old || (c.type == "wifi" && old.c.type != "wifi") ||
			(c.type == old.c.type && c.rssi != null && (old.c.rssi == null || c.rssi > old.c.rssi));
		if (prefer) grouped[key] = { mn, c, ap };
	}
	for (let key, item in grouped) {
		push(nodes, client_node(item.mn, item.c, item.ap));
		push(ap_nodes[item.ap].clients, key);
	}
	return { nodes, self: self_mn, role: state.cfg.role, now: time() };
}

// -------------------------------------------------------- device history
// 全网络当前在线的终端表（与 build_topology 相同的归属与信息补全规则）。
// 返回：设备组 ID -> { mn, c, ap }
function devlist_live() {
	let my = local_clients();
	let self_mn = macnorm(state.self.mac);
	let live = {};
	for (let mn, ap in compute_owner(my, self_mn)) {
		let c = (ap == self_mn ? my : (state.peers[ap]?.clients ?? {}))[mn];
		if (!c) continue;
		let key = device_key(mn);
		let old = live[key];
		let prefer = !old || (c.type == "wifi" && old.c.type != "wifi") ||
			(c.type == old.c.type && c.rssi != null && (old.c.rssi == null || c.rssi > old.c.rssi));
		if (prefer) live[key] = { mn, c, ap };
	}
	let leases = parse_leases();
	let neigh = parse_neigh();
	for (let key, it in live) {
		// SAP 无 DHCP，租约与主机名要由 CAP 下发的名称表补全
		if (it.c.ip == null)
			it.c.ip = leases[it.mn]?.ip ?? neigh[it.mn]?.ip ?? state.net_names?.[it.mn]?.ip ?? null;
		if (it.c.hostname == null)
			it.c.hostname = leases[it.mn]?.hostname ?? state.net_names?.[it.mn]?.hostname ?? null;
	}
	return live;
}

function devlist_load() {
	try {
		let data = json(fs.readfile(DEVICES_PATH));
		if (type(data) == "object")
			for (let key, d in data) {
				if (type(d) != "object") continue;
				// 重启后先全部置为离线，本轮扫描到的会立即被标回在线；
				// 这样断电期间产生的"最后离线时间"不会被伪造
				d.online = false;
				state.devices[key] = d;
			}
	} catch (e) { /* first boot */ }
}

function devlist_save(force) {
	let now = time();
	if (!state.dev_dirty) return;
	if (!force && now - state.dev_saved < DEVICES_FLUSH) return;
	fs.mkdir(ALIAS_DIR);
	fs.writefile(DEVICES_PATH, sprintf("%.J", state.devices));
	state.dev_saved = now;
	state.dev_dirty = false;
}

// 历史条数上限：优先淘汰最久未上线、且从未被手动命名/分组的记录
function devlist_trim() {
	let total = length(keys(state.devices));
	if (total <= DEVICES_MAX) return;
	let cand = [];
	for (let key, d in state.devices) {
		if (d.online) continue;
		if (state.aliases.map?.[key] || state.aliases.groups?.[key]) continue;
		push(cand, { key, ts: d.last_online ?? d.first_seen ?? 0 });
	}
	sort(cand, function(a, b) { return a.ts - b.ts; });
	for (let i = 0; i < length(cand) && total > DEVICES_MAX; i++, total--)
		delete state.devices[cand[i].key];
}

// 分组变化后历史键可能仍停留在旧 MAC / 旧组 ID：统一迁移到当前 device_key，
// 同一物理设备的多条记录合并为一条（首次发现取最早，上下线时间取最新）。
function devlist_merge_entry(dstk, src) {
	let dst = state.devices[dstk];
	if (!dst) { state.devices[dstk] = src; return; }
	if (src.first_seen && (!dst.first_seen || src.first_seen < dst.first_seen))
		dst.first_seen = src.first_seen;
	if ((src.last_online ?? 0) > (dst.last_online ?? 0)) {
		dst.last_online = src.last_online;
		dst.mac = src.mac ?? dst.mac;
		dst.ip = src.ip ?? dst.ip;
		dst.hostname = src.hostname ?? dst.hostname;
		dst.ap = src.ap ?? dst.ap;
		dst.conn = src.conn ?? dst.conn;
	}
	else {
		dst.ip ??= src.ip;
		dst.hostname ??= src.hostname;
	}
	if ((src.last_offline ?? 0) > (dst.last_offline ?? 0))
		dst.last_offline = src.last_offline;
	dst.online = dst.online || src.online;
}

function devlist_normalize() {
	let changed = false;
	for (let key in keys(state.devices)) {
		let nk = device_key(key);
		if (nk == key) continue;
		devlist_merge_entry(nk, state.devices[key]);
		delete state.devices[key];
		changed = true;
	}
	if (changed) state.dev_dirty = true;
	return changed;
}

// 每轮 tick 更新在线状态与上下线时间
function devlist_tick() {
	devlist_normalize();
	let now = time();
	let live = devlist_live();
	for (let key, it in live) {
		let d = state.devices[key];
		if (!d) d = state.devices[key] = { first_seen: now };
		if (!d.first_seen) d.first_seen = now;
		if (!d.online) d.online = true;
		d.last_online = now;   // 只要在线就持续刷新，语义是"最后一次在线时间"
		d.mac = maccolon(it.mn);
		d.ip = it.c.ip ?? d.ip ?? null;
		d.hostname = it.c.hostname ?? d.hostname ?? null;
		d.ap = it.ap;
		d.conn = it.c.type ?? null;
		state.dev_dirty = true;
	}
	for (let key, d in state.devices)
		if (!live[key] && d.online) {
			d.online = false;
			d.last_offline = now;
			state.dev_dirty = true;
		}
	devlist_trim();
	devlist_save(false);
	return live;
}

// 终端设备页数据：历史记录 + 本轮在线信息合并，在线优先、最近在线靠前
function devlist_view() {
	// 先刷新分组（含出厂 MAC 与随机 MAC 的跨频段合并），再读历史，
	// 保证页面看到的是合并后的记录而不是旧的两条
	device_group_refresh();
	let live = devlist_tick();
	let now = time();
	let out = [];
	for (let key, d in state.devices) {
		let it = live[key];
		let node = it ? client_node(it.mn, it.c, it.ap) : null;
		let al = state.aliases.map?.[key] ?? device_alias_of(key);
		let custom = (al?.name != null && al.name != "") ? al.name : null;
		let name = custom ?? node?.hostname ?? d.hostname ??
			node?.mac ?? d.mac ?? maccolon(macnorm(key));
		let ap = it?.ap ?? d.ap ?? null;
		let pin = pin_of(key);
		push(out, {
			id: key,
			mac: node?.mac ?? d.mac ?? key,
			members: node?.members ?? [],
			grouped: node?.grouped ?? false,
			name, custom_name: custom,
			hostname: node?.hostname ?? d.hostname ?? null,
			ip: node?.ip ?? d.ip ?? null,
			online: !!it,
			first_seen: d.first_seen ?? null,
			last_online: it ? now : (d.last_online ?? null),
			last_offline: d.last_offline ?? null,
			ap, ap_name: ap ? ap_display(ap) : null,
			conn: node?.conn ?? null,
			icon: al?.icon ?? null, note: al?.note ?? null,
			isolated: node?.isolated ?? false,
			pin, pin_name: pin ? ap_display(pin) : null,
			can_wake: !it,
		});
	}
	sort(out, function(a, b) {
		if (a.online != b.online) return a.online ? -1 : 1;
		return (b.last_online ?? 0) - (a.last_online ?? 0);
	});
	// 固定 AP 下拉框的候选：本机 + 已知对端
	let aps = [ { id: macnorm(state.self.mac), name: state.self.name } ];
	for (let mn, p in state.peers)
		push(aps, { id: mn, name: ap_display(mn) });
	sort(aps, function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
	return { now, devices: out, aps };
}

// --------------------------------------------------------------- wake on LAN
// 直接在本机发魔术包：6×0xFF + 16×目标 MAC，UDP 广播到 7/9 端口。
// 不依赖 etherwake/wakeonlan 二进制，SAP 与 CAP 都能用；广播域相同即可达。
function wol_packet(mn) {
	let pkt = "";
	for (let i = 0; i < 6; i++) pkt += chr(255);
	let raw = "";
	for (let i = 0; i < 12; i += 2)
		raw += chr(hexdec(substr(mn, i, 2)));
	for (let i = 0; i < 16; i++) pkt += raw;
	return pkt;
}

function wol_send(mn) {
	let pkt = wol_packet(mn);
	let sock = socket.create(socket.AF_INET,
		socket.SOCK_DGRAM | socket.SOCK_NONBLOCK, 0);
	if (!sock) return 0;
	sock.setopt(socket.SOL_SOCKET, socket.SO_BROADCAST, true);
	let targets = [
		{ address: "255.255.255.255", port: 9 },
		{ address: "255.255.255.255", port: 7 },
	];
	// 本机网段广播地址更容易被交换机/AP 转发（部分设备会丢弃 255.255.255.255）
	if (state.bcast && state.bcast != "255.255.255.255")
		push(targets, { address: state.bcast, port: 9 });
	let sent = 0;
	for (let t in targets) {
		try {
			sock.send(pkt, 0, t);
			sent++;
		} catch (e) { /* 单个目标失败不影响其它目标 */ }
	}
	sock.close();
	return sent;
}

// --------------------------------------------------------- roam configurator
function roam_md(ssid) { return substr(sha256("md:" + ssid), 0, 4); }
function roam_key0(mac) { return substr(sha256(state.cfg.token + ":r0:" + macnorm(mac)), 0, 32); }
function roam_key1(mac) { return substr(sha256(state.cfg.token + ":r1:" + macnorm(mac)), 0, 32); }

function member_list() {
	let members = [ { mac: state.self.mac, name: state.self.name } ];
	for (let mn, p in state.peers)
		if (p.authed)
			push(members, { mac: p.mac ?? maccolon(mn),
			                name: p.info?.name ?? p.name ?? mn });
	return members;
}

function apply_roam_local(roam, members) {
	let before = mesh.wirelessVersion();
	let cur = uci.cursor();
	cur.load("wireless");
	let touched = [];
	let self_nasid = uc(macnorm(state.self.mac));

	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.wifiroam_guest == "1" || is_backhaul_sec(s[".name"])) return;
		let sid = s[".name"];
		let in_group = roam.enabled && index(roam.ssids ?? [], s.ssid) >= 0;

		if (in_group) {
			// R（802.11r）可单独关闭：关闭时移除全部 FT 相关键，只保留 K/V
			if (roam.r_fast && (roam.ft_mode != "explicit" || mesh.readPhase().mode != "wireless")) {
				cur.set("wireless", sid, "ieee80211r", "1");
				cur.set("wireless", sid, "mobility_domain", roam_md(s.ssid));
				cur.set("wireless", sid, "ft_over_ds", roam.ft_over_ds && mesh.readPhase().mode != "wireless" ? "1" : "0");
				cur.set("wireless", sid, "reassociation_deadline", "2000");
				if (roam.ft_mode == "explicit") {
					cur.set("wireless", sid, "ft_psk_generate_local", "0");
					cur.set("wireless", sid, "nas_identifier", self_nasid + "-" + s.ssid);
					cur.set("wireless", sid, "pmk_r1_push", "1");
					let r0 = [], r1 = [];
					for (let m in members) {
						let mm = m.mac;
						push(r0, sprintf("%s,%s-%s,%s", mm, uc(macnorm(mm)), s.ssid, roam_key0(mm)));
						push(r1, sprintf("%s,%s,%s", mm, mm, roam_key1(mm)));
					}
					cur.set("wireless", sid, "r0kh", r0);
					cur.set("wireless", sid, "r1kh", r1);
				} else {
					cur.set("wireless", sid, "ft_psk_generate_local", "1");
					for (let k in [ "nas_identifier", "pmk_r1_push", "r0kh", "r1kh" ])
						cur.delete("wireless", sid, k);
				}
			} else {
				for (let k in [ "ieee80211r", "mobility_domain", "ft_over_ds",
				                "ft_psk_generate_local", "reassociation_deadline",
				                "nas_identifier", "pmk_r1_push", "r0kh", "r1kh" ])
					cur.delete("wireless", sid, k);
			}
			cur.set("wireless", sid, "ieee80211k", "1");
			cur.set("wireless", sid, "rrm_neighbor_report", roam.k_neighbor ? "1" : "0");
			cur.set("wireless", sid, "rrm_beacon_report", roam.k_beacon ? "1" : "0");
			cur.set("wireless", sid, "ieee80211v", "1");
			cur.set("wireless", sid, "bss_transition", roam.v_bss_transition ? "1" : "0");
			push(touched, s.ssid);
		} else {
			// only strip keys we manage, and only if present
			if (cur.get("wireless", sid, "ieee80211r") != null ||
			    cur.get("wireless", sid, "ieee80211k") != null ||
			    cur.get("wireless", sid, "ieee80211v") != null) {
				for (let k in ROAM_KEYS)
					cur.delete("wireless", sid, k);
			}
		}
	});

	if (!mesh.writeConfig(cur, "wireless", state.cfg.role)) return { ok: false, error: "uci" };
	state.roam_ver_applied = roam.config_ver ?? state.roam_ver_applied;
	// 整份漫游配置落盘：SAP 的设置页读取本地 uci，只写 ver/enabled 会让
	// 子 AP 显示与主 AP 不一致（SSID 组、FT 模式、k/v 开关等仍是默认值）
	let wc = uci.cursor();
	wc.load("wifiroam");
	let dirty = false;
	let want_ssids = roam.ssids ?? [];
	if (type(want_ssids) != "array") want_ssids = want_ssids == "" ? [] : [ want_ssids ];
	let cur_ssids = wc.get("wifiroam", "roam", "ssids") ?? [];
	if (type(cur_ssids) != "array") cur_ssids = cur_ssids == "" ? [] : [ cur_ssids ];
	let want = {
		enabled: roam.enabled ? "1" : "0",
		r_fast: roam.r_fast ? "1" : "0",
		ft_mode: roam.ft_mode == "explicit" ? "explicit" : "simple",
		ft_over_ds: roam.ft_over_ds ? "1" : "0",
		k_neighbor: roam.k_neighbor ? "1" : "0",
		k_beacon: roam.k_beacon ? "1" : "0",
		v_bss_transition: roam.v_bss_transition ? "1" : "0",
		rssi_profile: roam.rssi_profile ?? "balanced",
		rssi_threshold: "" + (roam.rssi_threshold ?? rssi_preset(roam.rssi_profile)),
		config_ver: "" + state.roam_ver_applied,
	};
	if (join("\n", cur_ssids) != join("\n", want_ssids)) {
		wc.set("wifiroam", "roam", "ssids", want_ssids);
		dirty = true;
	}
	for (let k, v in want) {
		if ((wc.get("wifiroam", "roam", k) ?? "") != v) {
			wc.set("wifiroam", "roam", k, v);
			dirty = true;
		}
	}
	if (dirty) wc.commit("wifiroam");
	if (before != mesh.wirelessVersion())
		uloop.process("/sbin/wifi", [ "reload" ], null,
			function(res) { log("wifi reload rc=" + res); });
	push_event("roam_apply", "",
		sprintf("ver=%d ssids=%d", roam.config_ver ?? 0, length(touched)));
	return { ok: true, touched, ver: state.roam_ver_applied };
}

// 本机实际落盘的 K/V/R：随 push_roam_config 回执上报，主AP可显示各 AP 生效状态
function applied_kvr(ssids) {
	let r = true, k = true, v = true, seen = 0;
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-iface", function(s) {
		if (s.mode && s.mode != "ap") return;
		if (s.disabled == "1") return;
		if (s.wifiroam_guest == "1") return;
		if (index(ssids ?? [], s.ssid) < 0) return;
		seen++;
		if (s.ieee80211r != "1" || (s.mobility_domain ?? "") == "") r = false;
		if (s.ieee80211k != "1" || (s.rrm_neighbor_report ?? "0") != "1") k = false;
		if (s.ieee80211v != "1" || (s.bss_transition ?? "0") != "1") v = false;
	});
	return { r: seen > 0 && r, k: seen > 0 && k, v: seen > 0 && v, seen };
}

// ----------------------------------------------------- wireless backhaul
function wifi_radios() {
	let out = [];
	let cur = uci.cursor();
	cur.load("wireless");
	cur.foreach("wireless", "wifi-device", function(s) {
		push(out, {
			name: s[".name"], band: s.band ?? "?",
			disabled: s.disabled == "1",
		});
	});
	return out;
}

function apply_backhaul_local(bh, role) {
	let result = role == "cap" ?
		meshRadio.applyCap(bh, ubusc, function() {
			uloop.process("/sbin/wifi", [ "reload" ], null, function(rc) { log("backhaul wifi reload rc=" + rc); });
		}) : mesh.saveBackhaul(bh);
	if (result.ok) state.backhaul_ver_applied = result.ver;
	return result;
}

function reconcile_cap_backhaul() {
	if (state.cfg.role != "cap") return;
	let result = apply_backhaul_local(current_backhaul_cfg(), "cap");
	if (!result.ok) log("CAP backhaul configuration failed: " + result.error);
}


// --------------------------------------------------------------- prechecks
function ssid_groups() {
	let groups = {};
	let self_mn = macnorm(state.self.mac);
	for (let w in wifi_ifaces()) {
		let g = groups[w.ssid] ??= { ssid: w.ssid, aps: {}, encs: {}, bands: {} };
		g.aps[self_mn] = true;
		g.encs[self_mn] = w.encryption;
		g.bands[w.band] = true;
	}
	for (let mn, p in state.peers) {
		for (let w in p.info?.wifi ?? []) {
			let g = groups[w.ssid] ??= { ssid: w.ssid, aps: {}, encs: {}, bands: {} };
			g.aps[mn] = true;
			g.encs[mn] = w.encryption;
			g.bands[w.band] = true;
		}
	}
	let out = [];
	for (let ssid, g in groups) {
		let encset = {};
		for (let mn, e in g.encs) encset[e] = true;
		let enc_list = keys(encset);
		let enc_ok = true;
		for (let e in enc_list)
			if (index(e, "psk") < 0 && index(e, "sae") < 0) enc_ok = false;
		push(out, {
			ssid, ap_count: length(keys(g.aps)),
			bands: keys(g.bands), encryptions: enc_list,
			consistent: length(enc_list) == 1,
			enc_ok,
		});
	}
	return out;
}

// 全网络 AP 概览：CAP 汇总后下发给 SAP，子 AP 的“开启前检查”与主 AP 保持一致
function ap_overview() {
	let self_mn = macnorm(state.self.mac);
	let aps = [ {
		id: self_mn, name: state.self.name, role: state.cfg.role,
		ip: state.self.ip, online: true, self: true,
		ssids: map(wifi_ifaces(), function(w) { return w.ssid; }),
		// 本机实际落盘的 K/V/R，便于主 AP 与子 AP 看到一致的生效状态
		kvr: applied_kvr(current_roam_cfg().ssids),
	} ];
	for (let mn, p in state.peers) {
		let list = [];
		for (let w in p.info?.wifi ?? [])
			if (index(list, w.ssid) < 0) push(list, w.ssid);
		push(aps, {
			id: mn, name: p.info?.name ?? p.name ?? maccolon(mn),
			role: p.info?.role ?? p.role ?? "sap",
			ip: p.info?.ip ?? p.ip, online: !!p.authed, self: false,
			ssids: list,
			kvr: p.kvr ?? null,
		});
	}
	return { groups: ssid_groups(), aps };
}

function precheck() {
	let checks = [];

	// apk (24.10+) / opkg (legacy) 双栈检测
	let wp = "";
	if (fs.access("/usr/bin/apk") || fs.access("/sbin/apk"))
		wp = trim(cmd_output("apk list --installed 2>/dev/null | awk '{print $1}' | grep -E '^wpad' | head -1"));
	if (wp == "")
		wp = trim(cmd_output("opkg list-installed 2>/dev/null | grep -E '^wpad' | head -1"));
	push(checks, { id: "wpad", ok: wp != "" && index(wp, "basic") < 0,
		info: wp != "" ? wp : "none" });

	// SAP 用 CAP 下发的全网络概览，避免子 AP 只看到本机接口导致计数/状态不一致
	let overview = (state.cfg.role == "sap" && state.roster?.aps) ? state.roster
	                                                               : ap_overview();
	let groups = overview.groups;
	let n_multi = 0;
	for (let g in groups) if (g.ap_count >= 2) n_multi++;
	push(checks, { id: "ssid_group", ok: n_multi > 0,
		info: sprintf("%d", n_multi) });

	for (let g in groups) {
		push(checks, { id: "enc_consistent", ok: g.consistent,
			info: sprintf("%s: %s", g.ssid, join(",", g.encryptions)) });
		push(checks, { id: "enc_allowed", ok: g.enc_ok,
			info: sprintf("%s: %s", g.ssid, join(",", g.encryptions)) });
	}
	push(checks, { id: "role", ok: state.cfg.role == "cap", info: state.cfg.role });

	// 成员 AP 概览：让"开启前检查"能直接看出子路由上报的 SSID/频段是否正确，
	// 而不是只显示一个汇总计数
	// self 标记必须按本机 MAC 重新计算：CAP 下发的 roster 里 "self" 指 CAP 自己
	let self_mn = macnorm(state.self.mac);
	let aps = [];
	for (let a in overview.aps) {
		push(aps, {
			id: a.id, name: a.name, role: a.role, ip: a.ip,
			online: a.online, self: a.id == self_mn, ssids: a.ssids,
			kvr: a.kvr ?? null,
		});
	}
	return { checks, groups, role: state.cfg.role, aps };
}

// ------------------------------------------------------- SAP -> CAP uplink
function sap_rx(req) {
	let link = state.link;
	if (!link || !link.chan) return 0;

	if (!link.authed) {
		if (req.type == "hello") {
			link.cap_mac = macnorm(req.args?.mac ?? "");
			let digest = sha256(state.cfg.token + ":" + (req.args?.nonce ?? ""));
			link.chan.defer({
				method: "auth",
				data: {
					mac: state.self.mac, role: state.cfg.role,
					name: state.self.name, digest,
					alias_ver: state.aliases.ver,
					roam_ver: state.roam_ver_applied,
					roam_sig: roam_sig(current_roam_cfg()),
					backhaul_ver: state.backhaul_ver_applied,
					guest_ver: guest_cfg().ver,
				},
				data_cb: function(m) {
					if (m?.ok) {
						link.authed = true;
						link.last_pong = time();
						state.net_names = m.names ?? {};
						if (m.roster) state.roster = m.roster;
						// 让 SAP 侧 status/peers_online 反映 CAP 在线
						if (link.cap_mac) {
							let cp = state.peers[link.cap_mac] ??= { clients: {} };
							cp.authed = true;
						}
						push_event("cap_connected", "", state.cfg.cap_ip);
						log("link to CAP established");
						sap_report();
					} else {
						log("CAP auth rejected");
						link.chan.disconnect();
					}
				},
				// cb 为 complete 回调（成功也触发），仅 rc != 0 表示失败/超时
				cb: function(rc) {
					if (rc != 0 && state.link == link) {
						log("CAP auth request failed");
						sap_disconnect();
					}
				},
			});
		}
		return 0;
	}

	switch (req.type) {
	case "push_roam_config": {
		if (mesh.managed() && !mesh.ready(mesh.readPhase().mode)) {
			req.reply({ ok: false, error: "link_pending" });
			break;
		}
		log(sprintf("roam push recv: wifi=%d", length(req.args.wifi ?? [])));
		// Older CAPs combine the SSID and roaming settings in one push.
		let w = req.args.wifi;
		let sync = apply_wifi_from_cap(w);
		if (!sync.ok) { req.reply(sync); break; }
		let r = apply_roam_local(req.args.roam, req.args.members ?? [], sync.changed);
		req.reply({ ok: r.ok, ver: r.ver,
		            kvr: applied_kvr(req.args.roam?.ssids ?? []) });
		break;
	}
	case "push_aliases": {
		let a = req.args.aliases;
		if (a && (a.ver ?? 0) > state.aliases.ver) {
			state.aliases = a;
			device_reindex();
			alias_save();
		}
		req.reply({ ok: true, ver: state.aliases.ver });
		break;
	}
	case "push_backhaul_config": {
		let r = apply_backhaul_local(req.args.backhaul ?? {}, "sap");
		req.reply({ ok: r.ok, ver: r.ver, error: r.error });
		break;
	}
	case "push_wifi_config": {
		if (mesh.managed() && !mesh.ready(mesh.readPhase().mode)) {
			req.reply({ ok: false, error: "link_pending" });
			break;
		}
		// CAP 下发的前台 SSID/密码：SAP 按频段改写本地 wireless 并重启无线
		let r = apply_wifi_from_cap(req.args.ssids);
		if (r.changed)
			uloop.process("/sbin/wifi", [ "reload" ], null, function(rc) { log("wifi reload rc=" + rc); });
		req.reply({ ok: r.ok, error: r.error });
		break;
	}
	case "push_guest_config": {
		// The CAP guest subnet needs a local DHCP/NAT server. Keep the
		// original router's guest settings during satellite mode.
		if (mesh.managed()) {
			req.reply({ ok: false, error: "guest_local_only" });
			break;
		}
		// CAP 下发的访客网络配置：SAP 本地落盘并重建访客子网
		let g = req.args.guest ?? {};
		if (!guest_save_local(g)) {
			req.reply({ ok: false, error: "invalid" });
			break;
		}
		let r = apply_guest_local(guest_cfg());
		req.reply({ ok: r.ok, error: r.error });
		break;
	}
	case "push_offload": {
		// CAP 广播下来的 flow offload 开关：SAP 本地落盘并重建自己的 flowtable
		let on = req.args.enabled ? true : false;
		req.reply({ ok: offload_apply(on), enabled: on });
		break;
	}
	case "get_client_detail": {
		let r = find_client(devnorm(req.args.mac));
		if (r)
			req.reply({ ok: true, client: r.node, ap: r.ap });
		else
			req.reply({ ok: false });
		break;
	}
	case "get_topology":
		req.reply(build_topology());
		break;
	case "leave":
		req.reply({ ok: true });
		push_event("unpaired", "", "");
		uloop.timer(300, function() {
			apply_roam_local({ enabled: false, ssids: [], config_ver: 0 }, []);
			state.cfg.role = "unconfigured";
			state.cfg.token = "";
			state.cfg.cap_ip = "";
			save_config();
			reconfigure();
		});
		break;
	}
	return 0;
}

sap_disconnect = function() {
	let link = state.link;
	if (!link) return;
	log("link to CAP closed");
	try { link.chan.disconnect(); } catch (e) {}
	try { link.sock.close(); } catch (e) {}
	if (link.cap_mac && state.peers[link.cap_mac])
		state.peers[link.cap_mac].authed = false;
	state.link = null;
};

function sap_connect(cap_ip) {
	sap_disconnect();
	let addr = socket.sockaddr({ address: cap_ip, port: TCP_PORT });
	if (!addr) return;
	let sock = socket.create(socket.AF_INET,
		socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
	if (!sock) return;
	sock.connect(addr); // nonblocking: completes via channel machinery
	let link = { sock, authed: false, ts: time(), last_pong: time() };
	link.chan = libubus.open_channel(sock, sap_rx, sap_disconnect);
	state.link = link;
	log(sprintf("connecting to CAP %s", cap_ip));
}

function sap_tick() {
	if (state.cfg.role != "sap") return;
	if (mesh.managed()) {
		let phase = mesh.readPhase();
		let current = mesh.ready(phase.mode) ? phase.mode + ":" + phase.ip + ":" + phase.since : null;
		if (current != state.mesh_session) {
			state.mesh_session = current;
			state.roam_ver_applied = -1;
			sap_disconnect();
		}
		if (!current) return;
		refresh_self_addr();
	}
	if (state.link?.authed) {
		// 心跳看门狗：ucode 通道可能感知不到对端死亡（CLOSE_WAIT 半开），
		// 以 report_status 回执刷新 last_pong，超时主动断开重连
		if (time() - (state.link.last_pong ?? state.link.ts) > 45) {
			log("CAP link timeout, reconnecting");
			sap_disconnect();
		} else {
			return;
		}
	}
	let cap = state.cfg.cap_ip != "" ? state.cfg.cap_ip : state.cap_learned;
	if (cap) sap_connect(cap);
}

sap_report = function() {
	if (state.cfg.role != "sap" || !state.link?.authed) return;
	let clients = local_clients();
	if (state.prev_clients != null)
		diff_events(state.prev_clients, clients, state.self.name);
	state.prev_clients = clients;
	let link = state.link;
	try {
		link.chan.defer({
			method: "report_status",
			data: {
				info: self_info(),
				clients,
				alias_ver: state.aliases.ver,
				roam_ver: state.roam_ver_applied,
				roam_sig: roam_sig(current_roam_cfg()),
				backhaul_ver: state.backhaul_ver_applied,
				guest_ver: guest_cfg().ver,
				// 本机落盘的 K/V/R 生效状态，CAP 汇总后展示给用户
				kvr: applied_kvr(current_roam_cfg().ssids),
			},
			data_cb: function(m) {
				link.last_pong = time();
				if (m?.names) state.net_names = m.names;
				if (m?.roster) state.roster = m.roster;
				if (m?.nr) state.cap_nr = m.nr;
			},
			cb: function(rc) {
				// complete 回调：rc == 0 为成功，仅失败/超时才断开重连
				if (rc != 0) {
					log("CAP link report failed");
					if (state.link == link) sap_disconnect();
				}
			},
		});
	} catch (e) {
		log("CAP link report error");
		if (state.link == link) sap_disconnect();
	}
};

// ------------------------------------------------------- TCP server (all)
conn_close = function(conn) {
	if (conn.chan) { try { conn.chan.disconnect(); } catch (e) {} }
	if (conn.sock) { try { conn.sock.close(); } catch (e) {} }
	if (conn.mac) {
		let mn = macnorm(conn.mac);
		let p = state.peers[mn];
		if (p && p.conn == conn) {
			p.conn = null;
			p.chan = null;
			p.authed = false;
		}
	}
};

function srv_rx(conn, req) {
	let args = req.args ?? {};

	if (!conn.authed) {
		if (req.type == "join" && state.cfg.role == "unconfigured") {
			// pairing: CAP pushes credentials to an unconfigured device
			if (args.nonce_echo != state.self.nonce || !args.token) {
				req.reply({ ok: false, error: "bad_nonce" });
				return 0;
			}
			if (type(args.backhaul) == "object" && !mesh.saveBackhaul(args.backhaul).ok) {
				req.reply({ ok: false, error: "backhaul_config" });
				return 0;
			}
			state.cfg.token = args.token;
			state.cfg.cap_ip = args.cap_ip ?? "";
			state.cfg.role = "sap";
			save_config();
			req.reply({ ok: true });
			push_event("paired", "", args.cap_ip ?? "");
			uloop.timer(300, reconfigure);
			return 0;
		}
		if (req.type == "auth") {
			let expect = sha256(state.cfg.token + ":" + conn.nonce);
			if (state.cfg.token == "" || args.digest != expect) {
				req.reply({ ok: false, error: "auth" });
				conn_close(conn);
				return 0;
			}
			let mn = macnorm(args.mac);
			conn.authed = true;
			conn.mac = uc(args.mac ?? "");
			conn.name = args.name;
			let p = state.peers[mn] ??= { clients: null }; // null = 未收过 report，首轮 diff 抑制
			p.mac = conn.mac;
			if (args.name) p.name = args.name;
			p.authed = true;
			p.last_seen = time();
			p.chan = conn.chan;   // 存 channel 本体，conn 仅用于关闭时清理
			p.conn = conn;
			push_event("ap_online", conn.mac, conn.name ?? "");
			req.reply({
				ok: true, role: state.cfg.role,
				alias_ver: state.aliases.ver,
				roam_ver: current_roam_cfg().config_ver,
				backhaul_ver: current_backhaul_cfg().config_ver,
				// CAP 的 DHCP 租约表：SAP 无 DHCP，借此在子 AP 拓扑显示主机名
				names: state.cfg.role == "cap" ? client_names() : {},
				// 全网络 AP/SSID 概览：子 AP 的开启前检查与主 AP 保持一致
				roster: state.cfg.role == "cap" ? ap_overview() : null,
			});
			if ((args.alias_ver ?? 0) < state.aliases.ver)
				push_aliases_to(mn);
			let roam = current_roam_cfg();
			let rsig = roam_sig(roam);
			// ver 落后或内容签名不一致都重新下发：后者用于修复历史遗留的
			// SAP 本地配置与主 AP 不一致（例如只同步了 enabled/ver）
			if (state.cfg.role == "cap" &&
			    ((args.roam_ver ?? -1) < roam.config_ver ||
			     (args.roam_sig && args.roam_sig != rsig)))
				push_roam_to(mn);
			let bh = current_backhaul_cfg();
			if (state.cfg.role == "cap" &&
			    (args.backhaul_ver ?? -1) < bh.config_ver)
				push_backhaul_to(mn);
			/* 访客配置也要在这里补发：只在保存那一刻推送的话，
			   子 AP 重连后仍会保留本地旧配置（旧密码/旧限速） */
			let ga = guest_cfg();
			if (state.cfg.role == "cap" && (args.guest_ver ?? -1) < ga.ver)
				push_guest_to(mn, ga);
			if (state.cfg.role == "cap")
				push_offload_to(mn);
			// GWRT: 认证一成功就下发本机 SSID/密码，无需用户再点保存
			if (state.cfg.role == "cap") {
				let ws = wifi_push_spec();
				if (length(ws) > 0) push_wifi_to(mn, ws);
			}
			return 0;
		}
		return 0;
	}

	// authed dispatch
	let mn = macnorm(conn.mac);
	switch (req.type) {
	case "report_status": {
		let p = state.peers[mn];
		if (p?.conn != conn) {
			req.reply({ ok: false, error: "superseded" });
			return 0;
		}
		conn.reported_at = clock(true)[0];
		let prev = p.clients;
		p.info = args.info;
		p.clients = args.clients ?? {};
		p.alias_ver = args.alias_ver ?? 0;
		p.roam_ver = args.roam_ver ?? 0;
		p.roam_sig = args.roam_sig ?? "";
		p.backhaul_ver = args.backhaul_ver ?? 0;
		p.guest_ver = args.guest_ver ?? 0;
		p.kvr = args.kvr ?? null;
		p.last_seen = time();
		if (prev != null) // 首轮 report 不产 join/leave 事件
			diff_events(prev, p.clients, p.info?.name ?? conn.name ?? mn);
		owner_events(local_clients()); // SAP 终端表更新后立即重算归属（含跨 AP 迁移）
		if (p.alias_ver < state.aliases.ver)
			push_aliases_to(mn);
		let roam = current_roam_cfg();
		if (p.roam_ver < roam.config_ver ||
		    (p.roam_sig != "" && p.roam_sig != roam_sig(roam)))
			push_roam_to(mn);
		let bh = current_backhaul_cfg();
		if (p.backhaul_ver < bh.config_ver)
			push_backhaul_to(mn);
		let ga = guest_cfg();
		if (state.cfg.role == "cap" && p.guest_ver < ga.ver)
			push_guest_to(mn, ga);
		// GWRT: 子AP 报上来的 SSID 与主AP 不一致时补发一次（同类补发 5 分钟一次）
		if (state.cfg.role == "cap") {
			let ws = wifi_push_spec();
			let sw = p.info?.wifi ?? [];
			let drift = false;
			for (let a in ws)
				for (let b in sw)
					if (a.band == b.band && (b.ssid ?? "") != a.ssid) drift = true;
			if (drift && time() - (p.wifi_push_ts ?? 0) > 300) {
				p.wifi_push_ts = time();
				push_wifi_to(mn, ws);
			}
		}
		req.reply({ ok: true, alias_ver: state.aliases.ver,
		            roam_ver: roam.config_ver, backhaul_ver: bh.config_ver,
		            names: state.cfg.role == "cap" ? client_names() : {},
		            roster: state.cfg.role == "cap" ? ap_overview() : null,
		            // SAP 要用 CAP 的 11k 邻居元素做候选列表，CAP 的 info 不经 hello 下发；
		            // 这里给全拓扑 BSS 列表，另一台 SAP 才能被互相看见
		            nr: bss_public() });
		break;
	}
	case "report_event":
		push_event(args.etype ?? "peer_event", args.mac ?? "", args.info ?? "", args.name ?? "");
		req.reply({ ok: true });
		break;
	case "set_offload": {
		// SAP 页面上的开关：转发在 CAP，必须由 CAP 执行后再广播回全部子 AP
		if (state.cfg.role != "cap") {
			req.reply({ ok: false, error: "not_cap" });
			break;
		}
		let on = req.args.enabled ? true : false;
		let ok = offload_apply(on);
		for (let pmn, p in state.peers)
			if (p.authed) push_offload_to(pmn);
		req.reply({ ok: ok, enabled: on });
		break;
	}
	case "get_topology":
		req.reply(build_topology());
		break;
	case "get_client_detail": {
		let r = find_client(devnorm(args.mac));
		if (r)
			req.reply({ ok: true, client: r.node, ap: r.ap });
		else
			req.reply({ ok: false });
		break;
	}
	case "alias_update":
		if (state.cfg.role == "cap" &&
		    alias_apply(args.mac, args.name, args.icon, args.note)) {
			alias_broadcast();
			req.reply({ ok: true, ver: state.aliases.ver });
		} else {
			req.reply({ ok: false });
		}
		break;
	case "pin_update":
		if (state.cfg.role == "cap") {
			let pr = pin_apply(args.mac, args.ap ?? "");
			if (pr.ok) {
				alias_broadcast();
				req.reply({ ok: true, ver: state.aliases.ver });
			} else {
				req.reply({ ok: false, error: pr.error });
			}
		} else {
			req.reply({ ok: false });
		}
		break;
	default:
		req.reply({ ok: false, error: "unknown_method" });
	}
	return 0;
}

function srv_accept() {
	while (true) {
		let addr = {};
		let cs = tcp_srv.accept(addr);
		if (!cs) break;
		let conn = { sock: cs, address: addr.address, authed: false, nonce: randhex(16) };
		conn.chan = libubus.open_channel(
			cs,
			function(req) { return srv_rx(conn, req); },
			function() { conn_close(conn); });
		conn.chan.request({
			method: "hello",
			data: { mac: state.self.mac, role: state.cfg.role,
			        nonce: conn.nonce },
			return: "ignore",
		});
	}
}

function setup_tcp() {
	tcp_srv = socket.create(socket.AF_INET,
		socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
	if (!tcp_srv) { log("tcp create failed"); return; }
	tcp_srv.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	if (!tcp_srv.bind("0.0.0.0:" + TCP_PORT) || !tcp_srv.listen(8)) {
		log("tcp bind/listen failed: " + socket.error());
		tcp_srv.close(); tcp_srv = null;
		exit(1);   // fail-fast：避免僵尸实例与正常实例竞争
	}
	uloop.handle(tcp_srv.fileno(), srv_accept, uloop.ULOOP_READ);
}

// ------------------------------------------------------- push helpers (CAP)
// 通道写失败时清理对端状态，避免僵尸连接导致守护进程崩溃
function peer_link_dead(mn, what) {
	let p = state.peers[mn];
	log(sprintf("%s to %s failed, marking peer offline", what, mn));
	if (!p) return;
	p.authed = false;
	p.chan = null;
	if (p.conn) { let c = p.conn; p.conn = null; conn_close(c); }
}

push_aliases_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return;
	try {
		p.chan.defer({
			method: "push_aliases",
			data: { aliases: state.aliases },
			data_cb: function() {}, cb: function() {},
		});
	} catch (e) {
		peer_link_dead(mn, "push_aliases");
	}
};

push_roam_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.roam_pushing) return true; // 推送在途，避免 auth+report 竞争重复下发
	let roam = current_roam_cfg();
	let name = p.info?.name ?? p.name ?? mn;
	p.roam_pushing = true;
	try {
		p.chan.defer({
			method: "push_roam_config",
			data: { roam, members: member_list() },
			data_cb: function(m) {
				p.roam_pushing = false;
				apply_result_update(mn, name, m?.ok ?? false, m?.ver ?? null, null, m?.kvr ?? null);
			},
			cb: function(rc) {
				// 成功时 data_cb 已写入结果；仅失败/超时标记 timeout
				if (rc != 0) {
					p.roam_pushing = false;
					apply_result_update(mn, name, false, null, "timeout");
				}
			},
		});
	} catch (e) {
		p.roam_pushing = false;
		peer_link_dead(mn, "push_roam_config");
		return false;
	}
	return true;
};

apply_result_update = function(mn, name, ok, ver, err, kvr) {
	if (!state.last_apply) return;
	for (let r in state.last_apply.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.ver = ver; r.error = err;
			if (kvr) r.kvr = kvr;
		}
	}
};

push_backhaul_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.bh_pushing) return true;
	let bh = current_backhaul_cfg();
	let name = p.info?.name ?? p.name ?? mn;
	p.bh_pushing = true;
	try {
		p.chan.defer({
			method: "push_backhaul_config",
			data: { backhaul: bh },
			data_cb: function(m) {
				p.bh_pushing = false;
				apply_backhaul_result_update(mn, name, m?.ok ?? false, m?.ver ?? null, m?.error ?? null);
			},
			cb: function(rc) {
				if (rc != 0) {
					p.bh_pushing = false;
					apply_backhaul_result_update(mn, name, false, null, "timeout");
				}
			},
		});
	} catch (e) {
		p.bh_pushing = false;
		peer_link_dead(mn, "push_backhaul_config");
		return false;
	}
	return true;
};

// 把新的 SSID / 密码（按频段）推给成员 AP（SAP 收到后改写本地 wireless 并重启无线）
push_wifi_to = function(mn, ssids) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.wifi_pushing) return true;
	p.wifi_pushing = true;
	try {
		p.chan.defer({
			method: "push_wifi_config",
			data: { ssids: ssids },
			data_cb: function(m) {
				p.wifi_pushing = false;
				apply_wifi_result_update(mn, m?.ok ?? false, m?.error ?? null);
			},
			cb: function(rc) {
				if (rc != 0) {
					p.wifi_pushing = false;
					apply_wifi_result_update(mn, false, "timeout");
				}
			},
		});
	} catch (e) {
		p.wifi_pushing = false;
		peer_link_dead(mn, "push_wifi_config");
		return false;
	}
	return true;
};

apply_wifi_result_update = function(mn, ok, err) {
	if (!state.last_wifi) return;
	for (let r in state.last_wifi.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.error = err;
		}
	}
};

// 把访客网络配置推给成员 AP（SAP 收到后重建本机访客子网）
push_guest_to = function(mn, cfg) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return false;
	if (p.guest_pushing) return true;
	p.guest_pushing = true;
	try {
		p.chan.defer({
			method: "push_guest_config",
			data: { guest: cfg },
			data_cb: function(m) {
				p.guest_pushing = false;
				apply_guest_result_update(mn, m?.ok ?? false, m?.error ?? null);
			},
			cb: function(rc) {
				if (rc != 0) {
					p.guest_pushing = false;
					apply_guest_result_update(mn, false, "timeout");
				}
			},
		});
	} catch (e) {
		p.guest_pushing = false;
		peer_link_dead(mn, "push_guest_config");
		return false;
	}
	return true;
};

apply_guest_result_update = function(mn, ok, err) {
	if (!state.last_guest) return;
	for (let r in state.last_guest.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.error = err;
		}
	}
};

apply_backhaul_result_update = function(mn, name, ok, ver, err) {
	if (!state.last_backhaul) return;
	for (let r in state.last_backhaul.results) {
		if (r.ap == maccolon(mn) || r.ap == mn) {
			r.ok = ok; r.ver = ver; r.error = err;
		}
	}
};

// CAP：把 flow offload 开关广播给所有已认证的子 AP，保证各页面看到同一状态
push_offload_to = function(mn) {
	let p = state.peers[mn];
	if (!p?.authed || !p.chan) return;
	let cur = uci.cursor();
	cur.load("firewall");
	let on = cur.get("firewall", "@defaults[0]", "flow_offloading") == "1";
	try {
		p.chan.defer({
			method: "push_offload",
			data: { enabled: on },
			data_cb: function() {}, cb: function() {},
		});
	} catch (e) {
		peer_link_dead(mn, "push_offload");
	}
};

// ------------------------------------------------------------------ ubus API
find_client = function(key) {
	let local = local_clients();
	let leases = parse_leases(), neigh = parse_neigh();
	let best = null;
	for (let mn in device_members_of(key)) {
		let c = local[mn], pmn = macnorm(state.self.mac), ap = state.self.name;
		if (!c) {
			for (let pkey, p in state.peers) {
				if (!p.clients?.[mn]) continue;
				c = p.clients[mn]; pmn = pkey;
				ap = p.info?.name ?? p.name ?? pkey;
				break;
			}
		}
		if (!c) continue;
		if (c.ip == null) c.ip = leases[mn]?.ip ?? neigh[mn]?.ip ?? null;
		if (c.hostname == null) c.hostname = leases[mn]?.hostname ?? null;
		if (!best || (c.type == "wifi" && best.c.type != "wifi") ||
		    (c.rssi != null && (best.c.rssi == null || c.rssi > best.c.rssi)))
			best = { mn, c, pmn, ap };
	}
	if (!best) return null;
	return { node: client_node(best.mn, best.c, best.pmn), ap: best.ap };
};

// ------------------------------------------------------ internet schedule
// 定时断网规则存放在 wifiroam 的 ban section：
//   mac(原始 MAC 或设备组 ID) / name / timeon(HH:MM) / timeoff(HH:MM) / weekdays
// weekdays 为 "1 2 3"，1=周一 … 7=周日；timeon > timeoff 表示跨午夜。
// 只在 CAP 执行：CAP 是网关，终端流量最终经由它的 forward 链转发。
function ban_hm(v) {
	let m = match(v ?? "", /^([0-9]{1,2}):([0-9]{1,2})$/);
	if (!m) return null;
	let h = int(m[1]), mi = int(m[2]);
	if (h > 23 || mi > 59) return null;
	return h * 60 + mi;
}

function ban_hm_str(mins) {
	return sprintf("%02d:%02d", mins / 60, mins % 60);
}

function ban_weekdays(v) {
	let s = type(v) == "array" ? join("", v) : replace(v ?? "", /[^0-9]/g, "");
	let out = [];
	for (let i = 0; i < length(s); i++) {
		let d = int(substr(s, i, 1));
		if (d >= 1 && d <= 7 && index(out, d) < 0)
			push(out, d);
	}
	sort(out);
	return out;
}

function ban_read() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let leases = parse_leases();
	let list = [], seen = {};
	cur.foreach("wifiroam", "ban", function(s) {
		let mn = device_key(s.mac ?? "");
		if ((length(mn) != 12 && !match(mn, /^g[0-9a-f]{12}$/)) || seen[mn]) return;
		seen[mn] = true;
		let on = ban_hm(s.timeon), off = ban_hm(s.timeoff);
		let days = ban_weekdays(s.weekdays);
		let members = device_members_of(mn);
		let lease_name = members.length ? leases[members[0]]?.hostname : null;
		push(list, {
			sid: s[".name"], mac: mn,
			name: (s.name ?? "") != "" ? s.name : (device_alias_of(mn)?.name ?? lease_name ?? ""),
			timeon: on == null ? BAN_DEFAULT_ON : ban_hm_str(on),
			timeoff: off == null ? BAN_DEFAULT_OFF : ban_hm_str(off),
			weekdays: length(days) ? days : [ 1, 2, 3, 4, 5, 6, 7 ],
		});
	});
	state.ban.list = list;
	return list;
}

// 当前是否处于断网时段；起止时间相同视为全天生效
function ban_in_window(b, lt, nowmin) {
	if (!length(b.weekdays)) return false;
	let on = ban_hm(b.timeon), off = ban_hm(b.timeoff);
	if (on == null || off == null) return false;
	let wd = lt.wday == 0 ? 7 : lt.wday;   // ucode: 0=周日
	if (on == off) return index(b.weekdays, wd) >= 0;
	if (on < off)
		return index(b.weekdays, wd) >= 0 && nowmin >= on && nowmin < off;
	// 跨午夜：今天已过起始时间，或昨天是起始日且还没到结束时间
	let prev = wd == 1 ? 7 : wd - 1;
	return (index(b.weekdays, wd) >= 0 && nowmin >= on) ||
	       (index(b.weekdays, prev) >= 0 && nowmin < off);
}

// 软件/硬件 flow offload 命中的连接会绕过 forward 钩子。开始断网时清空
// flowtable，让这些连接回落到正常转发路径，从而立即命中丢弃规则
// （conntrack 状态保留，已有连接只是不再走快路径，不会被重置）。
function ban_flush_flows() {
	let fam = null, tab = null;
	for (let line in split(cmd_output("nft list flowtables 2>/dev/null"), "\n")) {
		let t = match(line, /^[ \t]*table[ \t]+(\w+)[ \t]+(\w+)[ \t]*\{/);
		if (t) { fam = t[1]; tab = t[2]; continue; }
		let f = match(line, /^[ \t]*flowtable[ \t]+(\w+)[ \t]*\{/);
		if (f && fam && tab)
			cmd_output(sprintf("nft flush flowtable %s %s %s 2>/dev/null", fam, tab, f[1]));
	}
}

// 同步 nft：只在生效集合变化时重建，避免每 10s 刷链
ban_apply = function(force) {
	let blocked = {}, macs = [];
	if (state.cfg.role == "cap" && state.ban.enabled) {
		let lt = localtime(time());
		let nowmin = lt.hour * 60 + lt.min;
		for (let b in ban_read()) {
			if (!ban_in_window(b, lt, nowmin)) continue;
			for (let x in device_members_of(b.mac)) {
				if (index(macs, x) < 0) push(macs, x);
				blocked[x] = true;
			}
		}
	}
	sort(macs);
	state.ban.active = blocked;

	// 只有 CAP 需要这张表；角色降级为 SAP 时清掉残留规则
	if (state.cfg.role != "cap") {
		if (force || state.ban.sig != "") {
			cmd_output(sprintf("nft delete table inet %s 2>/dev/null", BAN_TABLE));
			state.ban.sig = "";
		}
		return macs;
	}

	let sig = join(",", macs);
	if (!force && sig == state.ban.sig) return macs;
	state.ban.sig = sig;

	cmd_output(sprintf("nft add table inet %s 2>/dev/null", BAN_TABLE));
	cmd_output(sprintf(
		"nft add chain inet %s forward '{ type filter hook forward priority -10; policy accept; }' 2>/dev/null",
		BAN_TABLE));
	cmd_output(sprintf("nft flush chain inet %s forward 2>/dev/null", BAN_TABLE));
	if (length(macs)) {
		let script = "";
		for (let mn in macs)
			script += sprintf("add rule inet %s forward ether saddr %s counter drop\n",
			                  BAN_TABLE, maccolon(mn));
		fs.writefile(BAN_NFT_FILE, script);
		cmd_output(sprintf("nft -f %s 2>/dev/null", BAN_NFT_FILE));
		fs.unlink(BAN_NFT_FILE);
		ban_flush_flows();
	}
	log(sprintf("ban: %d device(s) blocked", length(macs)));
	return macs;
};

// 已设置的上网时段数量。总开关的默认值只看时段是否设置过：
// 未设置时间时默认关闭，保存过时间后默认开启。
function ban_rule_count() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let n = 0;
	cur.foreach("wifiroam", "ban", function() { n++; });
	return n;
}

// 总开关：显式配置优先；从未设置时按是否存在时段规则决定默认值。
function ban_reload_enabled() {
	let cur = uci.cursor();
	cur.load("wifiroam");
	let configured = cur.get("wifiroam", "schedule", "enabled");
	state.ban.enabled = configured == null ? ban_rule_count() > 0 : configured == "1";
	return state.ban.enabled;
}

function ban_load() {
	ban_reload_enabled();
	ban_apply(true);
}

function ban_tick() {
	if (state.cfg.role != "cap") return;
	ban_apply(false);
}

// 历史统计仍按原始 MAC 保留，输出时合并到当前设备组；新采样已直接按组写入。
function appctl_public_stats() {
	let out = {};
	for (let mn, apps in state.appctl.stats) {
		let key = device_key(mn);
		out[key] ??= {};
		for (let app, v in apps) {
			let o = out[key][app] ??= {
				today: 0, total: 0, last: 0, btoday: 0, btotal: 0,
				days: {}, bdays: {},
			};
			o.today += v.today ?? 0;
			o.total += v.total ?? 0;
			o.btoday += v.btoday ?? 0;
			o.btotal += v.btotal ?? 0;
			if ((v.last ?? 0) > o.last) o.last = v.last;
			for (let day, sec in v.days ?? {})
				o.days[day] = (o.days[day] ?? 0) + sec;
			for (let day, by in v.bdays ?? {})
				o.bdays[day] = (o.bdays[day] ?? 0) + by;
		}
	}
	return out;
}

function appctl_public_days(src, online) {
	let out = {};
	for (let mn, days in src) {
		let key = device_key(mn);
		out[key] ??= {};
		for (let day, value in days) {
			// 在线时长是设备是否在线，不是各频段在线时长的总和；旧数据取最大值。
			if (online) {
				if ((value ?? 0) > (out[key][day] ?? 0)) out[key][day] = value ?? 0;
			} else out[key][day] = (out[key][day] ?? 0) + (value ?? 0);
		}
	}
	return out;
}

let api_obj = {
	mesh_policy: {
		args: { ubus_rpc_session: "" },
		call: function() { return mesh.getPolicy(); },
	},
	set_mesh_policy: {
		args: { ubus_rpc_session: "", search_seconds: 0, router_seconds: 0 },
		call: function(req) { return mesh.setPolicy(req.args); },
	},
	status: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let online = 0, nclients = 0, device_set = {};
			for (let mn, p in state.peers) {
				if (p.authed) online++;
				for (let cmn in p.clients ?? {}) device_set[device_key(cmn)] = true;
			}
			for (let cmn in local_clients()) device_set[device_key(cmn)] = true;
			nclients = length(keys(device_set));
			// SAP 以 CAP 下发的概览为准，成员 AP 计数与主AP保持一致
			let peers_total = length(keys(state.peers));
			if (state.cfg.role == "sap" && type(state.roster?.aps) == "array") {
				let o = 0, t = 0;
				let self_mn = macnorm(state.self.mac);
				for (let a in state.roster.aps) {
					if (a.id == self_mn) continue;
					t++;
					if (a.online) o++;
				}
				online = o; peers_total = t;
			}
			return {
				version: DAEMON_VERSION,
				daemon_started: daemon_started,
				kvr: applied_kvr(current_roam_cfg().ssids),
				mesh_mode: mesh.readPhase().mode,
				role: state.cfg.role, name: state.self.name,
				mac: state.self.mac, ip: state.self.ip,
				cap_ip: state.cfg.cap_ip != "" ? state.cfg.cap_ip : state.cap_learned,
				model: state.self.model, firmware: state.self.firmware,
				uptime: self_uptime(),
				peers_online: online, peers_total,
				clients_total: nclients,
				roam: current_roam_cfg(),
				backhaul: current_backhaul_cfg(),
				alias_ver: state.aliases.ver,
				last_apply: state.last_apply,
				last_backhaul: state.last_backhaul,
			};
		},
	},
	topology: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return build_topology(); },
	},
	// 终端历史（含已离线设备）：设备页卡片与网络唤醒的数据源
	device_history: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return devlist_view(); },
	},
	wake: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let key = device_key(req.args.mac ?? "");
			if (!state.devices[key]) {
				key = macnorm(req.args.mac ?? "");
				if (!state.devices[key])
					return { ok: false, error: "unknown_device" };
			}
			// 只唤醒曾经在线过的设备（历史白名单），在线设备直接拒绝
			if (state.devices[key].online)
				return { ok: false, error: "already_online" };
			let members = device_members_of(key);
			if (!length(members))
				return { ok: false, error: "invalid_mac" };
			let sent = 0;
			for (let mn in members)
				if (length(mn) == 12) sent += wol_send(mn);
			if (!sent)
				return { ok: false, error: "send_failed" };
			return { ok: true, sent, mac: maccolon(members[0]) };
		},
	},
	client_detail: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			let r = find_client(devnorm(mac));
			if (!r) return libubus.STATUS_NOT_FOUND;
			return { ok: true, client: r.node, ap: r.ap };
		},
	},
	set_alias: {
		args: { ubus_rpc_session: "", mac: "", name: "", icon: "", note: "" },
		call: function(req) {
			let a = req.args;
			if (!a.mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role == "sap" && state.link?.authed) {
				// forward to CAP; CAP broadcasts the new alias table
				try {
					state.link.chan.defer({
						method: "alias_update",
						data: { mac: a.mac, name: a.name, icon: a.icon, note: a.note },
						data_cb: function() {}, cb: function() {},
					});
				} catch (e) {
					sap_disconnect();
					return { ok: false, error: "link_down" };
				}
				return { ok: true, forwarded: true };
			}
			if (!alias_apply(a.mac, a.name, a.icon, a.note))
				return { ok: false, error: "invalid_mac" };
			alias_broadcast();
			return { ok: true, ver: state.aliases.ver };
		},
	},
	set_pin: {
		args: { ubus_rpc_session: "", mac: "", ap: "" },
		call: function(req) {
			let a = req.args;
			if (!a.mac) return libubus.STATUS_INVALID_ARGUMENT;
			// SAP 侧改动同样交给 CAP 统一保存并广播，避免各 AP 记录不一致
			if (state.cfg.role == "sap" && state.link?.authed) {
				try {
					state.link.chan.defer({
						method: "pin_update",
						data: { mac: a.mac, ap: a.ap ?? "" },
						data_cb: function() {}, cb: function() {},
					});
				} catch (e) {
					sap_disconnect();
					return { ok: false, error: "link_down" };
				}
				return { ok: true, forwarded: true };
			}
			let r = pin_apply(a.mac, a.ap ?? "");
			if (r.ok) alias_broadcast();
			return r;
		},
	},
	ungroup_device: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			if (state.cfg.role != "cap") return { ok: false, error: "not_cap" };
			let mn = macnorm(req.args.mac ?? "");
			if (length(mn) != 12) return { ok: false, error: "invalid_mac" };
			let r = device_ungroup(mn);
			if (r.ok) {
				appctl_read_devices();
				if (state.appctl.enabled) {
					appctl_apply_rules();
					appctl_dpi_daemon("reload");
				}
				ban_apply(true);
			}
			return r;
		},
	},
	set_role: {
		args: { ubus_rpc_session: "", role: "" },
		call: function(req) {
			let r = req.args.role;
			if (index([ "cap", "sap", "unconfigured" ], r) < 0)
				return libubus.STATUS_INVALID_ARGUMENT;
			if (r == "sap")
				return { ok: false, error: "sap_via_pairing" };
			state.cfg.role = r;
			if (r == "cap") ensure_token();
			if (r == "unconfigured") {
				state.cfg.token = "";
				state.cfg.cap_ip = "";
			}
			save_config();
			if (r == "cap") roam_default_init();
			reconfigure();
			reconcile_cap_backhaul();
			return { ok: true, role: r };
		},
	},
	get_roam: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			// SAP 侧用 CAP 下发的全网络概览，避免 SSID 组 AP 数量与成员列表
			// 只看到本机（显示 1 台）而与主AP不一致
			let use_roster = (state.cfg.role == "sap" && state.roster?.groups);
			let members = member_list();
			if (use_roster && type(state.roster.aps) == "array") {
				members = [];
				for (let a in state.roster.aps)
					push(members, { mac: maccolon(a.id), name: a.name ?? a.id });
			}
			return {
				roam: current_roam_cfg(),
				groups: use_roster ? state.roster.groups : ssid_groups(),
				members,
				kvr: applied_kvr(current_roam_cfg().ssids),
			};
		},
	},
	set_roam: {
		args: {
			ubus_rpc_session: "",
			enabled: false, ssids: [], r_fast: true, ft_mode: "",
			ft_over_ds: false, k_neighbor: false,
			k_beacon: false, v_bss_transition: false,
			rssi_profile: "", rssi_threshold: 0,
		},
		call: function(req) {
			let a = req.args;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let profile = a.rssi_profile ?? "balanced";
			if (index([ "aggressive", "balanced", "conservative", "custom" ], profile) < 0)
				profile = "balanced";
			let threshold = int(a.rssi_threshold ?? 0);
			if (profile != "custom" || threshold == 0)
				threshold = rssi_preset(profile);
			if (threshold > -30) threshold = -30;
			if (threshold < -95) threshold = -95;
			let cur = uci.cursor();
			cur.load("wifiroam");
			let ver = int(cur.get("wifiroam", "roam", "config_ver") ?? "0") + 1;
			cur.set("wifiroam", "roam", "enabled", a.enabled ? "1" : "0");
			cur.set("wifiroam", "roam", "ssids", a.ssids ?? []);
			cur.set("wifiroam", "roam", "r_fast", a.r_fast ? "1" : "0");
			cur.set("wifiroam", "roam", "ft_mode",
				a.ft_mode == "explicit" ? "explicit" : "simple");
			cur.set("wifiroam", "roam", "ft_over_ds", a.ft_over_ds ? "1" : "0");
			cur.set("wifiroam", "roam", "k_neighbor", a.k_neighbor ? "1" : "0");
			cur.set("wifiroam", "roam", "k_beacon", a.k_beacon ? "1" : "0");
			cur.set("wifiroam", "roam", "v_bss_transition",
				a.v_bss_transition ? "1" : "0");
			cur.set("wifiroam", "roam", "rssi_profile", profile);
			cur.set("wifiroam", "roam", "rssi_threshold", "" + threshold);
			cur.set("wifiroam", "roam", "config_ver", "" + ver);
			cur.commit("wifiroam");

			let roam = current_roam_cfg();
			let members = member_list();
			let results = [];
			let lr = apply_roam_local(roam, members);
			push(results, { ap: state.self.mac, name: state.self.name,
			                ok: lr.ok, ver: lr.ver, kvr: applied_kvr(roam.ssids) });
			// 先落 last_apply，再推送，才能收集到各 SAP 的异步回执
			state.last_apply = { ts: time(), ver, results };
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_roam_to(mn);
			}
			return { ok: true, ver, results };
		},
	},
	precheck: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return precheck(); },
	},
	get_backhaul: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			return {
				backhaul: current_backhaul_cfg(),
				radios: wifi_radios(),
				self: { mac: state.self.mac, name: state.self.name },
			};
		},
	},
	// 「无线设置」：读取本机 SSID / 密码状态（SAP 上也返回本机值，仅展示）
	get_wifi: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let s = wifi_summary();
			s.role = state.cfg.role;
			s.last = state.last_wifi ?? null;
			return s;
		},
	},
	// 改名 / 改密码：主AP 生效后同步到所有已配对 AP。
	// ifaces = [{ band, ssid, key }]：每个频段一个名称/密码（多频合一时各项相同）
	set_wifi: {
		args: { ubus_rpc_session: "", unified: false, ifaces: [] },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let list = req.args.ifaces;
			if (type(list) != "array" || length(list) < 1)
				return { ok: false, error: "ssid_invalid" };

			let ssids = [];
			for (let it in list) {
				let ssid = trim(it.ssid ?? "");
				let key = it.key ?? "";
				if (length(ssid) < 1 || length(ssid) > 32)
					return { ok: false, error: "ssid_invalid" };
				// WPA2/WPA3 的口令为 8-63 字符；64 位十六进制也接受（原始 PSK）
				if (key != "" && (length(key) < 8 || length(key) > 64))
					return { ok: false, error: "key_invalid" };
				push(ssids, { band: it.band ?? "?", ssid: ssid, key: key });
			}

			// 多频合一且密码留空：沿用现有密码复制到所有频段，避免只合一名称
			if (req.args.unified) {
				let cur = uci.cursor();
				cur.load("wireless");
				let common = "";
				cur.foreach("wireless", "wifi-iface", function(s) {
					if (common != "") return;
					if (s.mode && s.mode != "ap") return;
					if (s.wifiroam_guest == "1") return;
					if (s.key != null && s.key != "") common = s.key;
				});
				if (common != "")
					for (let it in ssids)
						if (it.key == "") it.key = common;
			}

			// 漫游组记录里的 SSID 跟随改名（两频段同名时按频段逐条映射）
			let pairs = [];
			for (let it in wifi_summary().ifaces) {
				for (let s in ssids)
					if (s.band == it.band) push(pairs, { old: it.ssid, new: s.ssid });
			}
			roam_rename_ssids(pairs);

			let lr = apply_wifi_local(ssids);

			let results = [ { ap: state.self.mac, name: state.self.name,
			                 ok: lr.ok, error: lr.ok ? null : "no_ap_iface" } ];
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_wifi_to(mn, ssids);
			}
			state.last_wifi = { ts: time(), ssids: ssids, results: results };
			return { ok: lr.ok, results: results };
		},
	},
	// 访客网络：读取本机配置（SAP 上也返回本机值）
	get_guest: {
		args: { ubus_rpc_session: "" },
		call: function(req) { return guest_summary(); },
	},
	// 保存访客网络：主AP 生效后同步到所有已配对 AP
	set_guest: {
		args: {
			ubus_rpc_session: "", enabled: false, ssid: "", key: "",
			bandwidth: 0, schedule: false, start: "", end: "",
			allow_lan: false, open: false,
		},
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let a = req.args;
			let prev = guest_cfg();
			let enabled = a.enabled ? true : false;
			let ssid = trim(a.ssid ?? "");
			let key = a.key ?? "";
			// 开放网络（无密码）：显式标记，避免和「留空沿用旧密码」混淆
			let open_net = a.open ? true : false;

			if (open_net)
				key = "";
			else if (key == "")
				key = prev.key;

			if (enabled) {
				if (length(ssid) < 1 || length(ssid) > 32)
					return { ok: false, error: "ssid_invalid" };
				if (!open_net) {
					// 密码留空沿用旧密码，密码框只改名称时不必重输
					if (key == "") return { ok: false, error: "key_invalid" };
					if (length(key) < 8 || length(key) > 64)
						return { ok: false, error: "key_invalid" };
				}
			}
			if (key != "" && (length(key) < 8 || length(key) > 64))
				return { ok: false, error: "key_invalid" };

			let start = trim(a.start ?? prev.start);
			let end = trim(a.end ?? prev.end);
			if (hhmm_minutes(start) == null || hhmm_minutes(end) == null)
				return { ok: false, error: "time_invalid" };

			let bandwidth = int(a.bandwidth ?? 0);
			if (bandwidth < 0) bandwidth = 0;
			if (bandwidth > 1000) bandwidth = 1000;

			let cfg = {
				enabled: enabled,
				ssid: ssid != "" ? ssid : prev.ssid,
				key: key,
				bandwidth: bandwidth,
				schedule: a.schedule ? true : false,
				start: start, end: end,
				allow_lan: a.allow_lan ? true : false,
				ver: prev.ver + 1,
			};

			if (!guest_save_local(cfg))
				return { ok: false, error: "invalid" };
			let lr = apply_guest_local(guest_cfg());

			let results = [ { ap: state.self.mac, name: state.self.name,
			                 ok: lr.ok, error: lr.ok ? null : "invalid" } ];
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_guest_to(mn, cfg);
			}
			state.last_guest = { ts: time(), config: cfg, results: results };
			return { ok: lr.ok, results: results };
		},
	},
	set_backhaul: {
		args: {
			ubus_rpc_session: "", enabled: false,
			ssid: "", key: "", device: "",
		},
		call: function(req) {
			let a = req.args;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let prev = current_backhaul_cfg();
			let ssid = (a.ssid ?? "") != "" ? a.ssid : BACKHAUL_DEFAULT_SSID;
			let key = a.key ?? "";
			if (key == "" && a.enabled)
				key = prev.key != "" ? prev.key : randhex(16);
			let ver = (prev.config_ver ?? 0) + 1;

			let cur = uci.cursor();
			cur.load("wifiroam");
			cur.set("wifiroam", "backhaul", "enabled", a.enabled ? "1" : "0");
			cur.set("wifiroam", "backhaul", "ssid", ssid);
			cur.set("wifiroam", "backhaul", "key", key);
			cur.set("wifiroam", "backhaul", "device", a.device ?? "");
			cur.set("wifiroam", "backhaul", "config_ver", "" + ver);
			cur.commit("wifiroam");

			let bh = current_backhaul_cfg();
			let results = [];
			let lr = apply_backhaul_local(bh, "cap");
			push(results, { ap: state.self.mac, name: state.self.name,
			                ok: lr.ok, ver: lr.ver, error: lr.error ?? null });
			state.last_backhaul = { ts: time(), ver, results };
			for (let mn, p in state.peers) {
				if (!p.authed) continue;
				push(results, { ap: p.mac ?? maccolon(mn),
				                name: p.info?.name ?? p.name ?? mn,
				                ok: null, error: "pending" });
				push_backhaul_to(mn);
			}
			return { ok: true, ver, results, backhaul: bh };
		},
	},
	discover: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let out = [];
			for (let mn, d in state.discovered)
				push(out, {
					mac: d.mac, ip: d.ip, name: d.name,
					model: d.model, last_seen: d.last_seen,
				});          // 不下发 nonce，配对所需凭据仅留在守护进程内
			return { devices: out };
		},
	},
	pair: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let mn = macnorm(mac);
			let d = state.discovered[mn];
			if (!d) return { ok: false, error: "not_found" };
			if (!d.ip) return { ok: false, error: "no_ip" };

			let addr = socket.sockaddr({ address: d.ip, port: TCP_PORT });
			let sock = socket.create(socket.AF_INET,
				socket.SOCK_STREAM | socket.SOCK_NONBLOCK, 0);
			if (!addr || !sock) return { ok: false, error: "socket" };
			sock.connect(addr);
			let done = false;
			let chan = null;
			chan = libubus.open_channel(sock,
				function(req2) {
					if (req2.type == "hello" && chan) {
						try {
							chan.defer({
								method: "join",
								data: {
									token: state.cfg.token,
									cap_ip: state.self.ip,
									backhaul: current_backhaul_cfg(),
									nonce_echo: d.nonce,
								},
								data_cb: function(m) {
									done = true;
									if (m?.ok) {
										push_event("paired", d.mac, d.ip);
										delete state.discovered[mn];
									}
									chan.disconnect();
								},
								cb: function(rc) {
									// 成功时 data_cb 已处理并断开；仅失败时兜底断开
									if (rc != 0 && chan)
										try { chan.disconnect(); } catch (e) {}
								},
							});
						} catch (e) {
							try { chan.disconnect(); } catch (e2) {}
						}
					}
					return 0;
				},
				function() {});
			uloop.timer(8000, function() {
				if (!done && chan) { try { chan.disconnect(); } catch (e) {} }
			});
			return { ok: true, ip: d.ip };
		},
	},
	unpair: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			let mac = req.args.mac;
			if (!mac) return libubus.STATUS_INVALID_ARGUMENT;
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let mn = macnorm(mac);
			let p = state.peers[mn];
			if (!p) return { ok: false, error: "not_found" };
			if (p.authed && p.chan)
				try {
					p.chan.defer({
						method: "leave", data: {},
						data_cb: function() {}, cb: function() {},
					});
				} catch (e) {}
			delete state.peers[mn];
			push_event("unpaired", maccolon(mn), p.name ?? "");
			return { ok: true };
		},
	},
	roam_log: {
		args: { ubus_rpc_session: "", limit: 0 },
		call: function(req) {
			let limit = int(req.args.limit ?? 50);
			if (limit <= 0) limit = 50;
			if (limit > MAX_EVENTS) limit = MAX_EVENTS;
			let ev = state.events;
			if (length(ev) > limit)
				ev = slice(ev, length(ev) - limit);
			return { events: ev };
		},
	},
	appctl_status: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let apps = [];
			for (let a in APP_DEFS)
				push(apps, { id: a.id, name: a.name, cat: a.cat ?? "" });

			let devices = {};
			for (let mn, d in state.appctl.devices)
				devices[mn] = { name: d.name, block: d.block };

			return {
				ok: state.cfg.role == "cap",
				error: state.cfg.role == "cap" ? "" : "not_cap",
				enabled: state.appctl.enabled,
				enhanced: state.appctl.enhanced == true,
				strict: state.appctl.strict == true,
				day: state.appctl.day,
				apps, devices, stats: appctl_public_stats(),
				online: appctl_public_days(state.appctl.online, true),
				ndata: appctl_public_days(state.appctl.ndata, false),
			};
		},
	},
	/* 定时断网：规则列表 + 当前生效集合。只在 CAP 可配置/生效。 */
	ban_list: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let lt = localtime(time());
			let nowmin = lt.hour * 60 + lt.min;
			let items = [];
			for (let b in ban_read())
				push(items, {
					mac: b.mac, name: b.name,
					timeon: b.timeon, timeoff: b.timeoff,
					weekdays: b.weekdays,
					active: state.ban.enabled && ban_in_window(b, lt, nowmin),
				});
			return {
				ok: state.cfg.role == "cap",
				error: state.cfg.role == "cap" ? "" : "not_cap",
				enabled: state.ban.enabled,
				items: items,
				blocked: sort(keys(state.ban.active)),
			};
		},
	},
	set_ban: {
		args: { ubus_rpc_session: "", enabled: false },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let on = req.args.enabled ? true : false;
			let cur = uci.cursor();
			cur.load("wifiroam");
			if (cur.get("wifiroam", "schedule") == null)
				cur.set("wifiroam", "schedule", "schedule");
			cur.set("wifiroam", "schedule", "enabled", on ? "1" : "0");
			cur.commit("wifiroam");
			state.ban.enabled = on;
			ban_apply(true);
			return { ok: true, enabled: on };
		},
	},
	ban_set: {
		args: { ubus_rpc_session: "", mac: "", name: "",
		        timeon: "", timeoff: "", weekdays: "" },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let a = req.args;
			let mn = device_key(a.mac ?? "");
			if (length(mn) != 12 && !match(mn, /^g[0-9a-f]{12}$/))
				return { ok: false, error: "invalid_mac" };
			let on = ban_hm(a.timeon), off = ban_hm(a.timeoff);
			if (on == null || off == null) return { ok: false, error: "invalid_time" };
			let days = ban_weekdays(a.weekdays);
			if (!length(days)) return { ok: false, error: "invalid_weekdays" };

			let name = a.name ?? "";
			if (name == "") {
				let r = find_client(mn);
				name = r?.node?.name ?? "";
			}

			let cur = uci.cursor();
			cur.load("wifiroam");
			let sid = null, old = [];
			cur.foreach("wifiroam", "ban", function(s) {
				if (device_key(s.mac ?? "") == mn) {
					if (!sid) sid = s[".name"];
					push(old, s[".name"]);
				}
			});
			if (!sid) {
				sid = cur.add("wifiroam", "ban");
				cur.set("wifiroam", sid, "mac", mn);
			}
			cur.set("wifiroam", sid, "mac", mn);
			cur.set("wifiroam", sid, "name", name);
			cur.delete("wifiroam", sid, "enabled");
			cur.set("wifiroam", sid, "timeon", ban_hm_str(on));
			cur.set("wifiroam", sid, "timeoff", ban_hm_str(off));
			cur.set("wifiroam", sid, "weekdays", join(" ", days));
			for (let id in old)
				if (id != sid) cur.delete("wifiroam", id);
			cur.commit("wifiroam");

			// 首次保存时段时总开关默认开启（已显式关闭的保持关闭）
			ban_reload_enabled();
			ban_apply(true);
			let blocked = false;
			for (let member in device_members_of(mn))
				if (state.ban.active[member]) blocked = true;
			return { ok: true, mac: mn, blocked };
		},
	},
	ban_del: {
		args: { ubus_rpc_session: "", mac: "" },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let mn = device_key(req.args.mac ?? "");
			let cur = uci.cursor();
			cur.load("wifiroam");
			let old = [];
			cur.foreach("wifiroam", "ban", function(s) {
				if (device_key(s.mac ?? "") == mn) push(old, s[".name"]);
			});
			if (!length(old)) return { ok: false, error: "not_found" };
			for (let sid in old) cur.delete("wifiroam", sid);
			cur.commit("wifiroam");
			// 删掉最后一个时段后，未显式配置的总开关回到默认关闭
			ban_reload_enabled();
			ban_apply(true);
			return { ok: true };
		},
	},
	/* 硬件/软件 flow offload 状态：fw4 的 flowtable 一旦命中，后续数据包会绕过
	   netfilter 链，inet wifiroam forward 里的 counter 不再增长，应用统计与
	   访问控制都会受影响。这里读 fw4 的实际 forward 链判断是否真的生效。 */
	offload_status: {
		args: { ubus_rpc_session: "" },
		call: function(req) {
			let cur = uci.cursor();
			cur.load("firewall");
			let sw = cur.get("firewall", "@defaults[0]", "flow_offloading") == "1";
			let hw = cur.get("firewall", "@defaults[0]", "flow_offloading_hw") == "1";
			let active = index(cmd_output("nft list chain inet fw4 forward 2>/dev/null"),
				"flow add") >= 0;
			return { enabled: sw, hw: hw, active: active };
		},
	},
	set_offload: {
		args: { ubus_rpc_session: "", enabled: false },
		call: function(req) {
			let on = req.args.enabled ? true : false;
			// 子 AP 的转发不发生在本地：本地先落盘保持一致，再通知 CAP 统一执行，
			// CAP 改完会把最终状态广播回所有子 AP（含本机）
			if (state.cfg.role == "sap") {
				offload_apply(on);
				offload_request_cap(on);
				return { ok: true, enabled: on };
			}
			if (!offload_apply(on))
				return { ok: false, error: "no_firewall_defaults" };
			for (let mn, p in state.peers)
				if (p.authed) push_offload_to(mn);
			return { ok: true, enabled: on };
		},
	},
	set_appctl: {
		// 调用方必须显式传 enhanced（ubus 参数是白名单校验，未声明的参数会被拒；
		// 默认值取 false，类型可推断，publish 正常）
		// strict 留空表示沿用当前值，避免旧调用点（总开关）把严格模式重置
		args: { ubus_rpc_session: "", enabled: false, enhanced: false, strict: "" },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let on = req.args.enabled ? true : false;
			let cur = uci.cursor();
			cur.load("wifiroam");
			// 老配置里可能没有 appctl section，先按类型创建再写选项
			if (cur.get("wifiroam", "appctl") == null)
				cur.set("wifiroam", "appctl", "appctl");
			// enhanced 为必填调用参数（前端所有调用点都显式传当前值）
			let enh = req.args.enhanced ? true : false;
			let strict = state.appctl.strict == true;
			if (req.args.strict == "1") strict = true;
			else if (req.args.strict == "0") strict = false;
			cur.set("wifiroam", "appctl", "enabled", on ? "1" : "0");
			cur.set("wifiroam", "appctl", "enhanced", enh ? "1" : "0");
			cur.set("wifiroam", "appctl", "strict", strict ? "1" : "0");
			cur.commit("wifiroam");
			state.appctl.enabled = on;
			state.appctl.enhanced = enh;
			state.appctl.strict = strict;

			let dirty = appctl_dnsmasq_sync(on);
			if (on) {
				// 精准/宽松切换会改变集合默认超时：schema 标记不一致即重建集合
				if (appctl_nft_schema()) dirty = true;
				appctl_apply_rules();
				appctl_dpi_daemon("start");
				appctl_dnslock_apply(enh);
				appctl_hw_suspend(enh);
			}
			else {
				appctl_table_remove();
				appctl_hw_suspend(false);
			}
			// dnsmasq 需要重读 nftset 配置才生效，约 1s DNS 瞬断
			if (dirty)
				cmd_output("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
			return { ok: true, enabled: on, enhanced: enh, strict: strict };
		},
	},
	set_app_policy: {
		args: { ubus_rpc_session: "", mac: "", app: "", action: "" },
		call: function(req) {
			if (state.cfg.role != "cap")
				return { ok: false, error: "not_cap" };
			let a = req.args;
			let mn = device_key(a.mac ?? "");
			if ((length(mn) != 12 && !match(mn, /^g[0-9a-f]{12}$/)) || !appctl_app(a.app ?? ""))
				return { ok: false, error: "invalid_args" };
			if (!state.appctl.enabled)
				return { ok: false, error: "disabled" };
			if (index([ "block", "allow" ], a.action ?? "") < 0)
				return { ok: false, error: "invalid_action" };

			let devs = appctl_read_devices();
			let blocks = [];
			for (let b in (devs[mn]?.block ?? []))
				push(blocks, b);
			let i = index(blocks, a.app);
			if (a.action == "block" && i < 0) push(blocks, a.app);
			if (a.action == "allow" && i >= 0) splice(blocks, i, 1);

			let name = devs[mn]?.name ?? "";
			if (name == "")
				name = find_client(mn)?.node?.name ?? "";
			appctl_write_device(mn, blocks, name);
			appctl_read_devices();
			appctl_apply_rules();
			appctl_dpi_daemon("reload");
			return { ok: true, mac: mn, app: a.app, action: a.action, block: blocks };
		},
	},
};

// ------------------------------------------------------- RSSI steering (11v)
// 本机 + 各对端 hello 上报。SAP 侧拿不到 CAP 的 self_info，
// CAP 在 report_status 回执里单独下发自己的 NR（state.cap_nr）。
function steer_bss_list() {
	let out = [], seen = {};
	for (let e in ap_nr_self()) {
		push(out, e);
		seen[lc(e.bssid) + "|" + e.ssid] = true;
	}
	let others = [];
	for (let mn, p in state.peers)
		for (let e in p.info?.nr ?? [])
			push(others, e);
	for (let e in state.cap_nr ?? [])
		push(others, e);
	for (let e in others) {
		if (e?.bssid == null || e?.nr == null) continue;
		let k = lc(e.bssid) + "|" + (e.ssid ?? "");
		if (seen[k]) continue;
		seen[k] = true;
		push(out, { bssid: lc(e.bssid), ssid: e.ssid ?? "",
		            nr: e.nr, band: e.band, channel: e.channel });
	}
	return out;
}

// 全拓扑视角的 BSS 列表（去掉本机网卡名）。CAP 用它在 report_status 回执里
// 下发候选：SAP 之间没有直连通道，只能经 CAP 交换，否则各自只认识 CAP，
// 邻居库里缺少另一台 SAP，终端也就看不到那台更近的 AP。
bss_public = function() {
	let out = [];
	for (let e in steer_bss_list())
		push(out, { bssid: e.bssid, ssid: e.ssid, nr: e.nr,
		            band: e.band, channel: e.channel });
	return out;
};

// 把其它 AP 的同 SSID BSS 写进本机 hostapd 的 11k 邻居库。终端主动发
// BSS Transition Query 询问候选时，hostapd 才有内容可答；邻居库为空时
// 手机只能自己扫描，华为/荣耀等机型往往干脆不动。
function neighbor_sync(bsses) {
	let sig = "";
	for (let e in bsses) sig += e.ssid + "|" + e.bssid + ";";
	if (sig == state.nr_sig) return;
	state.nr_sig = sig;
	for (let e in bsses) {
		if (!e.ifname) continue;                 // 只有本机接口能调用
		let list = [];
		for (let o in bsses) {
			if (o.ssid != e.ssid) continue;
			if (lc(o.bssid) == lc(e.bssid)) continue;
			if (o.nr == null || o.nr == "") continue;
			push(list, [ o.bssid, o.ssid, o.nr ]);
		}
		if (!length(list)) continue;
		try { ubusc.call("hostapd." + e.ifname, "rrm_nr_set", { list }); }
		catch (err) { log("nr_set " + e.ifname + " failed"); }
	}
}

// 信号低于阈值时，通过 hostapd 的 BSS Transition Management 主动引导终端
// 切换到更合适的 AP。CAP/SAP 各自对自己下挂的终端执行，避免跨节点转发。
// 关键点：BTM 请求必须带候选列表（neighbors）。没有候选时多数手机
// （华为/荣耀/部分 IoT）会直接忽略请求，表现为“信号很差也不切换”。
function steer_tick() {
	if (state.cfg.role == "sap" && mesh.managed() && !mesh.ready(mesh.readPhase().mode)) return;
	if (state.cfg.role == "unconfigured") return;
	let roam = current_roam_cfg();
	if (!roam.enabled || !roam.v_bss_transition) return;
	let threshold = roam.rssi_threshold;
	if (threshold == null || threshold >= 0) return;
	if (!length(roam.ssids)) return;

	let has_peer = false;
	for (let mn, p in state.peers)
		if (p.authed) { has_peer = true; break; }
	if (!has_peer) return;   // 单 AP 无处分流，引导只会让终端掉线

	let self_nr = ap_nr_self();
	let bsses = steer_bss_list();
	if (roam.k_neighbor) neighbor_sync(bsses);

	let now = time();
	let clients = local_clients();
	for (let mn, c in clients) {
		if (c.type != "wifi" || !c.ifname) continue;
		// 固定 AP 的终端完全退出自动引导：钉在本 AP 时信号再差也不迁走
		if (pin_of(mn)) { delete state.steer_tries[mn]; continue; }
		if (c.ssid == null || index(roam.ssids, c.ssid) < 0) continue;
		let rssi = c.rssi;
		if (rssi == null) continue;
		rssi = int(rssi);
		if (rssi >= threshold) { delete state.steer_tries[mn]; continue; }
		// 刚入网（含刚被引导成功）时先观察，同时清零失败计数
		if (c.connected_time != null && int(c.connected_time) < MIN_STEER_ASSOC) {
			delete state.steer_tries[mn];
			continue;
		}

		// 候选：同 SSID 的其它 BSS（排除终端当前所在的 BSS）
		let cur_bssid = null;
		for (let e in self_nr)
			if (e.ifname == c.ifname) cur_bssid = lc(e.bssid);
		let cand_nr = [], cand = 0;
		for (let e in bsses) {
			if (e.ssid != c.ssid) continue;
			if (cur_bssid != null && lc(e.bssid) == cur_bssid) continue;
			if (e.nr == null || e.nr == "") continue;
			push(cand_nr, e.nr);
			cand++;
		}
		if (!cand) { delete state.steer_tries[mn]; continue; }

		if (now - (state.steer_last[mn] ?? 0) < STEER_COOLDOWN) continue;

		let tries = state.steer_tries[mn] ?? 0;
		if (tries >= STEER_KICK_AFTER) {
			// 刚被踢过又回到原 AP，说明附近没有更强的 AP，别再反复踢
			if ((state.steer_mute[mn] ?? 0) > now) continue;
			try {
				ubusc.call("hostapd." + c.ifname, "del_client", {
					addr: maccolon(mn), deauth: true, reason: 1, ban_time: 0 });
				state.kick_last[mn] = now;
				state.steer_mute[mn] = now + STEER_KICK_COOLDOWN;
				state.steer_tries[mn] = 0;
				state.steer_last[mn] = now;
				push_event("roam_kick", maccolon(mn),
					sprintf("rssi=%d < %d", rssi, threshold),
					client_name_of(mn, clients));
			} catch (e) {
				log("kick " + mn + " failed");
			}
			continue;
		}

		try {
			ubusc.call("hostapd." + c.ifname, "bss_transition_request", {
				addr: maccolon(mn),
				disassociation_imminent: true,
				disassociation_timer: 10,
				validity_period: 30,
				abridged: false,
				neighbors: cand_nr,
			});
			state.steer_last[mn] = now;
			state.steer_tries[mn] = tries + 1;
			push_event("roam_steer", maccolon(mn),
				sprintf("rssi=%d < %d cand=%d", rssi, threshold, cand),
				client_name_of(mn, clients));
		} catch (e) {
			log("steer " + mn + " failed");
		}
	}
}

// ------------------------------------------------------------ AP pinning
// 固定 AP 的本机执行：连到非目标 AP 的终端直接断开并禁入一段时间
//（pin_of / pin_apply 定义在文件前部，见 ucode 单遍编译说明）
function pin_tick() {
	if (state.cfg.role == "unconfigured") return;
	let pin = state.aliases.pin;
	if (!pin || !length(keys(pin))) return;
	let self_mn = macnorm(state.self.mac);
	let now = time();
	let clients = local_clients();
	for (let mn, c in clients) {
		if (c.type != "wifi" || !c.ifname) continue;
		let ap = pin_of(mn);
		if (!ap || ap == self_mn) continue;
		if (now - (state.pin_last[mn] ?? 0) < PIN_KICK_COOLDOWN) continue;
		try {
			ubusc.call("hostapd." + c.ifname, "del_client", {
				addr: maccolon(mn), deauth: true, reason: 1,
				ban_time: PIN_BAN_MS });
			state.pin_last[mn] = now;
			push_event("pin_kick", maccolon(mn),
				sprintf("%s → %s", ap_display(self_mn), ap_display(ap)),
				client_name_of(mn, clients));
		} catch (e) {
			log("pin kick " + mn + " failed");
		}
	}
}

// ---------------------------------------------------------------- lifecycle
ensure_token = function() {
	if (state.cfg.role == "cap" && state.cfg.token == "") {
		state.cfg.token = sha256(sprintf("wifiroam-%d-%d-%s",
			time(), rand(), state.self.mac));
		save_config();
		log("generated new network token");
	}
};

reconfigure = function() {
	load_config();
	state.self.name = state.cfg.name != "" ? state.cfg.name : state.self.hostname;
	sap_disconnect();
	state.peers = {};
	state.cap_learned = null;
	state.mesh_session = null;
	state.prev_clients = null;
	state.wired_seen = {};
	state.wifi_seen = {};
	state.prev_owner = null;
	state.steer_last = {};
	state.steer_tries = {};
	state.kick_last = {};
	state.steer_mute = {};
	state.nr_sig = "";
	state.cap_nr = [];
	send_hello();
	// 角色/网段变化后重新评估定时断网（例如从 SAP 提升为 CAP）
	ban_apply(true);
};

// 插件启用后按默认设置开启漫游：首次启动（从未保存过漫游配置）时，
// 自动选中本机全部主网络 SSID，并按默认 k/v/r 参数下发一次。
// 注意：ucode 的函数声明不做提升，本函数必须定义在 wifi_ifaces /
// member_list / apply_roam_local / applied_kvr 之后。
roam_default_init = function() {
	if (state.cfg.role != "cap") return;
	let cur = uci.cursor();
	cur.load("wifiroam");
	if (int(cur.get("wifiroam", "roam", "config_ver") ?? "0") != 0) return;
	if (cur.get("wifiroam", "roam", "enabled") != "1") return;

	let raw = cur.get("wifiroam", "roam", "ssids");
	if (type(raw) == "array" ? length(raw) > 0 : (raw ?? "") != "") return;

	let ssids = [];
	for (let w in wifi_ifaces())
		if (w.ssid != "" && index(ssids, w.ssid) < 0)
			push(ssids, w.ssid);
	if (!length(ssids)) return;

	cur.set("wifiroam", "roam", "ssids", ssids);
	cur.set("wifiroam", "roam", "config_ver", "1");
	cur.commit("wifiroam");

	let roam = current_roam_cfg();
	apply_roam_local(roam, member_list());
	state.last_apply = {
		ts: time(), ver: roam.config_ver,
		results: [ { ap: state.self.mac, name: state.self.name,
		             ok: true, ver: roam.config_ver,
		             kvr: applied_kvr(roam.ssids) } ],
	};
	log(sprintf("roam defaults enabled for %d SSID(s)", length(ssids)));
};

function main() {
	srand(time());
	uloop.init();

	ubusc = libubus.connect(null, 60);
	if (!ubusc) {
		log("ubus connect failed");
		exit(1);
	}

	load_config();
	alias_load();
	devlist_load();
	detect_self();
	device_group_refresh();
	// 建规则要用到本机接口/网桥信息，必须放在 detect_self 之后
	appctl_load();
	ban_load();
	ensure_token();
	// 首次启用插件：按默认设置开启漫游（自动选中本机 SSID）
	roam_default_init();

	setup_udp();
	setup_tcp();
	reconcile_cap_backhaul();

	ubusc.publish("wifiroam", api_obj);

	uloop.interval(HELLO_INTERVAL, send_hello);
	uloop.interval(TICK_INTERVAL, sap_tick);
	uloop.interval(TICK_INTERVAL, sap_report);
	uloop.interval(TICK_INTERVAL, expire_tick);
	uloop.interval(TICK_INTERVAL, steer_tick);
	uloop.interval(TICK_INTERVAL, pin_tick);
	uloop.interval(TICK_INTERVAL, guest_tick);
	uloop.interval(TICK_INTERVAL, appctl_tick);
	uloop.interval(TICK_INTERVAL, ban_tick);
	uloop.interval(TICK_INTERVAL, devlist_tick);
	uloop.interval(TICK_INTERVAL, function() {
		if (state.cfg.role != "cap") return;
		let cur = local_clients();
		if (state.prev_clients != null)
			diff_events(state.prev_clients, cur, state.self.name);
		state.prev_clients = cur;
		owner_events(cur);
	});

	send_hello();
	log(sprintf("started role=%s", state.cfg.role));
	uloop.run();
}

main();
