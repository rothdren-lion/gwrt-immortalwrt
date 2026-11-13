-- GWRT 电视广告拦截: dnsmasq 域名层, 三档模式
local sys = require "luci.sys"

local function count_rules(path)
	local out = sys.exec("grep -c '^address=/' " .. path .. " 2>/dev/null")
	return (tonumber(out:match("%d+")) or 0)
end

m = Map("gwrt-tv-adblock", translate("电视广告拦截"),
	translate("在 dnsmasq 域名层拦截国内智能电视广告：开机广告、视频App广告SDK、投屏广告。对局域网内所有使用本机 DNS 的设备生效。注意：视频贴片广告与正片同一内容域名，DNS 层拦不住；改动生效后建议到电视端清理缓存并重启。"))

s = m:section(NamedSection, "config", "gwrt-tv-adblock", translate("拦截模式"))
s.addremove = false

o = s:option(ListValue, "mode", translate("模式"))
o:value("off",      translate("关闭"))
o:value("core",     translate("核心档（推荐）"))
o:value("extended", translate("激进档（有副作用）"))
o.description = translate("核心档：开机广告与视频App广告域名，无副作用。激进档：额外拦截各品牌应用商店/系统升级/语音助手/投屏服务，相应功能会失效。")

d = s:option(DummyValue, "_status", translate("当前状态"))
d.rawhtml = true
function d.cfgvalue(self, section)
	local mode = m.uci:get("gwrt-tv-adblock", "config", "mode") or "core"
	local html = { string.format("<div>模式：<b>%s</b></div>", mode) }
	if mode ~= "off" then
		html[#html+1] = string.format("<div>核心档规则：<b>%d</b> 条域名</div>",
			count_rules("/usr/share/gwrt-tv-adblock/tv-ads-core.conf"))
	end
	if mode == "extended" then
		html[#html+1] = string.format("<div>激进档规则：<b>%d</b> 条域名</div>",
			count_rules("/usr/share/gwrt-tv-adblock/tv-ads-extended.conf"))
	end
	local function test(dom)
		local out = sys.exec("nslookup " .. dom .. " 127.0.0.1 >/dev/null 2>&1 && echo OK || echo BLOCKED")
		return out:match("OK") and "未拦截" or "已拦截"
	end
	html[#html+1] = string.format(
		"<div>验证：api.ad.xiaomi.com（小米开机广告）<b>%s</b>；ads.huan.tv（长虹广告）<b>%s</b></div>",
		test("api.ad.xiaomi.com"), test("ads.huan.tv"))
	return table.concat(html, "")
end

m.on_after_commit = function()
	sys.call("/etc/init.d/gwrt-tv-adblock reload >/dev/null 2>&1")
end

return m
