module("luci.controller.tvadblock", package.seeall)

function index()
	local ok, nixio = pcall(require, "nixio")
	if ok and nixio.fs and not nixio.fs.access("/etc/config/gwrt-tv-adblock") then
		return
	end
	entry({"admin", "network", "tvadblock"}, cbi("tvadblock"), _("电视广告拦截"), 60).dependent = false
end
