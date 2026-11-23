-- GWRT 国内广告拦截: 纯文本规则库 + 分类开关 + 自定义拦截/放行 + 库升级
local sys = require "luci.sys"
local LIB_ETC = "/etc/gwrt-tv-adblock/ads-library.txt"
local LIB_SHARE = "/usr/share/gwrt-tv-adblock/ads-library.txt"

local function libpath()
	local f = io.open(LIB_ETC, "r")
	if f then f:close() return LIB_ETC end
	f = io.open(LIB_SHARE, "r")
	if f then f:close() return LIB_SHARE end
	return nil
end

local function lib_version(path)
	local out = sys.exec("grep -m1 '^# 版本:' " .. path .. " 2>/dev/null")
	return (out:match("版本:%s*(%S+)")) or "未知"
end

local function cat_count(path, cat)
	local cmd = string.format(
		[[awk -v c="%s" '/^#/{next} /^\[/{cat=$0; gsub(/^\[/,"",cat); gsub(/\].*$/,"",cat); next} cat==c && $1 ~ /^[a-z0-9._-]+$/ {n++} END{print n+0}' %s 2>/dev/null]],
		cat, path)
	return tonumber(sys.exec(cmd):match("%d+")) or 0
end

m = Map("gwrt-tv-adblock", translate("广告拦截（电视/国内通用/360）"),
	translate("基于纯文本规则库在 dnsmasq 域名层拦截，A 与 AAAA 查询均受规则控制：电视广告（tv）、应用商店/升级/语音/投屏（tv-ext）、百度/腾讯/字节等国内Web与APP广告（cn）、360全家桶注册域整域拦截（360）、腾讯管家/微软Defender与Windows Update（sec）。360 分类默认开启，会阻断 360 官网和旗下服务；可单独关闭。hao123/2345 为预置必拦项。只对使用本机 DNS 的设备生效；Mesh 子 AP 模式下 DNS 由主 AP 提供，应在主 AP 配置拦截。自动下发的运营商 IPv6 DNS 也可能绕过本机规则；DoH/DoT、外部 DNS、缓存地址或直连 IP 不受 DNS 规则控制。"))

s = m:section(NamedSection, "config", "gwrt-tv-adblock", translate("开关"))
s.addremove = false

o = s:option(ListValue, "enabled", translate("总开关"))
o:value("1", translate("开启"))
o:value("0", translate("关闭"))
o.default = "1"

o = s:option(ListValue, "cat_tv", translate("电视核心档（tv）"))
o:value("1", translate("开"))
o:value("0", translate("关"))
o.default = "1"
o.description = translate("各品牌开机广告域 + 视频App广告SDK，无副作用。小米/创维/TCL/长虹等。")

o = s:option(ListValue, "cat_tv_ext", translate("电视激进档（tv-ext）"))
o:value("1", translate("开"))
o:value("0", translate("关"))
o.default = "0"
o.description = translate("应用商店/系统升级/语音助手/投屏服务，对应功能会失效。")

o = s:option(ListValue, "cat_cn", translate("国内综合档（cn）"))
o:value("1", translate("开"))
o:value("0", translate("关"))
o.default = "0"
o.description = translate("百度/腾讯/字节/快手/网易/新浪微博/友盟/华为/OPPO/vivo/小米手机等广告SDK与统计、主流广告联盟。默认关，开启后若某App异常可加自定义放行。")

o = s:option(ListValue, "cat_360", translate("360 全家桶整域拦截（360）"))
o:value("1", translate("开"))
o:value("0", translate("关"))
o.default = "1"
o.description = translate("360.cn、360safe.com、360safe.cn、qhupdate.com、mayi360.cn、ads360.cn、360os.com 根域及所有子域；A/AAAA 均返回 NXDOMAIN，包含 www.360.cn。会阻断 360 官网及相关服务，默认开启。")

o = s:option(ListValue, "cat_sec", translate("安全软件与更新档（sec）"))
o:value("1", translate("开"))
o:value("0", translate("关"))
o.default = "0"
o.description = translate("腾讯管家/风控（guanjia/pcmgr/sec/aegis）、微软 Defender 云查杀与遥测、Windows Update 更新域、Office 更新 CDN。默认关；开启后相关安全组件与 Windows 更新将失效。360 由独立的 360 分类控制。")

-- 用户自定义拦截域名
local function filter_domains(self, value)
	if value == nil then return nil end
	local src = (type(value) == "table") and value or { value }
	local out = {}
	for _, raw in ipairs(src) do
		local d = tostring(raw):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%.+", "")
		if d ~= "" then
			-- Lua patterns cannot repeat captured groups as a regular expression can.
			if #d > 253 or not d:find("%.") or d:find("[^a-z0-9.%-]") or
			   d:find("..", 1, true) or d:sub(-1) == "." then
				return nil
			end
			for label in d:gmatch("[^.]+") do
				if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
					return nil
				end
			end
			if not d:match("%.([a-z][a-z0-9%-]*)$") then return nil end
			out[#out+1] = d
		end
	end
	return out
end

cb = s:option(DynamicList, "custom_block", translate("自定义拦截域名"))
cb.description = translate("额外拦截的域名，每条一个（不带 http://），如 ads.example.com。保存后自动挂到 dnsmasq 并重启。")
function cb.validate(self, value)
	return filter_domains(self, value)
end

ca = s:option(DynamicList, "custom_allow", translate("自定义放行域名（白名单）"))
ca.description = translate("放行项会从生成的 address 规则中移除自身及其子域，再转发到正常 DNS。被更宽的父域拦截时，较窄的子域放行无法覆盖它；例如放行 www.360.cn 不能覆盖 360.cn，需放行 360.cn（会放行该根域及所有子域）。")
function ca.validate(self, value)
	return filter_domains(self, value)
end

-- 规则库信息
d = s:option(DummyValue, "_libinfo", translate("规则库"))
d.rawhtml = true
function d.cfgvalue(self, section)
	local p = libpath()
	if not p then
		return "<div style='color:red'>规则库缺失！</div>"
	end
	local html = { string.format(
		"<div>活动库：<code>%s</code>（版本 <b>%s</b>）</div>", p, lib_version(p)) }
	html[#html+1] = string.format(
		"<div>条目：tv <b>%d</b> / tv-ext <b>%d</b> / cn <b>%d</b> / 360 <b>%d</b> / sec <b>%d</b> / 必拦 <b>%d</b></div>",
		cat_count(p, "tv"), cat_count(p, "tv-ext"), cat_count(p, "cn"), cat_count(p, "360"),
		cat_count(p, "sec"), cat_count(p, "kill"))
	html[#html+1] = translate("升级方式：填库地址后点下方按钮；或直接替换库文件后执行 /etc/init.d/gwrt-tv-adblock reload。固件升级不影响已替换的库（位于 /etc）。")
	return table.concat(html, "")
end

-- 库地址 + 更新按钮
u = s:option(Value, "library_url", translate("库更新地址"))
u.placeholder = "https://example.com/ads-library.txt"
u.description = translate("纯文本规则库的下载地址。留空则按钮无效果。")
u.rmempty = true

local has_button = (type(Button) == "table")
-- Button.write 在 CBI 解析阶段就执行, 早于 uci commit:
-- 直接在里面调 update 会拿到上一个 library_url。改为只置标记,
-- 真正的下载放到 on_after_commit(提交之后)。
local want_update = false
if has_button then
	local b = s:option(Button, "_updlib", translate("更新"))
	b.inputtitle = translate("从库地址更新规则库")
	b.description = translate("下载 → 内容与 dnsmasq 语法双重校验 → 备份原库(.bak) → 替换 → 重新生成。结果见 /tmp/gwrt-tv-adblock-update.log")
	function b.write(self, section, value)
		want_update = true
	end
end

d = s:option(DummyValue, "_status", translate("当前状态"))
d.rawhtml = true
function d.cfgvalue(self, section)
	local function onoff(v)
		return (v == "1") and "开" or "关"
	end
	local en = m.uci:get("gwrt-tv-adblock", "config", "enabled") or "1"
	local html = { string.format("<div>总开关：<b>%s</b></div>", onoff(en)) }
	html[#html+1] = string.format("<div>分类：tv <b>%s</b>；tv-ext <b>%s</b>；cn <b>%s</b>；360 <b>%s</b>；sec <b>%s</b>（hao123/2345 固定拦截）</div>",
		onoff(m.uci:get("gwrt-tv-adblock", "config", "cat_tv") or "1"),
		onoff(m.uci:get("gwrt-tv-adblock", "config", "cat_tv_ext") or "0"),
		onoff(m.uci:get("gwrt-tv-adblock", "config", "cat_cn") or "0"),
		onoff(m.uci:get("gwrt-tv-adblock", "config", "cat_360") or "1"),
		onoff(m.uci:get("gwrt-tv-adblock", "config", "cat_sec") or "0"))
	local bl = m.uci:get_list("gwrt-tv-adblock", "config", "custom_block") or {}
	local al = m.uci:get_list("gwrt-tv-adblock", "config", "custom_allow") or {}
	html[#html+1] = string.format("<div>自定义：拦截 <b>%d</b> 条 / 放行 <b>%d</b> 条</div>", #bl, #al)
	local function test(dom, qtype)
		local state = sys.exec("/usr/libexec/gwrt-tv-adblock-query " .. dom .. " " .. qtype):gsub("%s+$", "")
		if state == "blocked" then return "已拦截" end
		if state == "unblocked" then return "未拦截" end
		if state == "no-record" then return "未拦截（无此类型记录）" end
		if state == "dns-error" then return "DNS异常" end
		return "结果不明"
	end
	html[#html+1] = string.format(
		"<div>360 实测：www.360.cn A <b>%s</b> / AAAA <b>%s</b>；s.360.cn A <b>%s</b> / AAAA <b>%s</b></div>",
		test("www.360.cn", "A"), test("www.360.cn", "AAAA"),
		test("s.360.cn", "A"), test("s.360.cn", "AAAA"))
	return table.concat(html, "")
end

m.on_after_commit = function()
	-- 先换库(带校验, 失败保留原库), 再按新库重建规则
	if want_update then
		sys.call("/usr/libexec/gwrt-tv-adblock update noreload >/tmp/gwrt-tv-adblock-update.log 2>&1")
	end
	sys.call("/etc/init.d/gwrt-tv-adblock reload >/dev/null 2>&1")
end

return m
