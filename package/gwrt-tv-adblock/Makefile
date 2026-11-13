#
# GWRT 国内电视广告拦截 (dnsmasq 域名层)
#
# 覆盖: 小米/创维/TCL/长虹/海信/索尼 开机广告, 银河奇艺/腾讯视频TV/优酷CIBN
# 等视频App广告SDK, 乐播投屏广告子域. 核心档无副作用; 激进档含应用商店/
# 系统升级域名 (会让相应功能失效, 默认不启用).
# 设计文档: docs/GWRT-TV-ADBLOCK.md
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-tv-adblock
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-tv-adblock
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GWRT domestic smart TV ad blocker (dnsmasq domain layer)
  DEPENDS:=+dnsmasq
  PKGARCH:=all
endef

define Package/gwrt-tv-adblock/description
  Blocks domestic smart TV ads at the DNS layer via dnsmasq
  address=/domain/ entries: boot ads (Xiaomi/Skyworth/TCL/Hisense/
  Changhong/Sony), video-app ad SDKs (GITV/Tencent Video TV/Youku CIBN),
  and LeBo (hpplay) casting ad subdomains. Modes: off / core (safe) /
  extended (also blocks appstore/upgrade/voice domains, may break
  features). Managed by /usr/libexec/gwrt-tv-adblock or the LuCI page.
  NOTE: does not cover pre-roll ads embedded in the same CDN as video
  content, and ads that use hardcoded IPs (see docs for the nftset
  option).
endef

define Package/gwrt-tv-adblock/conffiles
/etc/config/gwrt-tv-adblock
endef

define Build/Compile
endef

define Package/gwrt-tv-adblock/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/usr/share/gwrt-tv-adblock
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-tv-adblock $(1)/etc/init.d/gwrt-tv-adblock
	$(INSTALL_BIN) ./files/etc/uci-defaults/90_gwrt-tv-adblock $(1)/etc/uci-defaults/90_gwrt-tv-adblock
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-tv-adblock $(1)/usr/libexec/gwrt-tv-adblock
	$(INSTALL_CONF) ./files/etc/config/gwrt-tv-adblock $(1)/etc/config/gwrt-tv-adblock
	$(INSTALL_DATA) ./files/usr/share/gwrt-tv-adblock/tv-ads-core.conf $(1)/usr/share/gwrt-tv-adblock/
	$(INSTALL_DATA) ./files/usr/share/gwrt-tv-adblock/tv-ads-extended.conf $(1)/usr/share/gwrt-tv-adblock/
endef

$(eval $(call BuildPackage,gwrt-tv-adblock))
