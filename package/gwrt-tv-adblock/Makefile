#
# GWRT 国内广告拦截 (dnsmasq 域名层, 纯文本规则库)
#
# 覆盖: 电视开机广告 (小米/创维/TCL/长虹/海信/索尼), 视频App广告SDK
# (银河奇艺/腾讯视频TV/优酷CIBN), 乐播投屏广告子域; 国内通用广告
# (百度/腾讯/字节/快手/网易/新浪微博/友盟/华为/OPPO/vivo/小米手机/
# 主流广告联盟); 安全软件与更新 (360全家桶/腾讯管家/微软Defender与
# 遥测/Windows Update); 必拦 hao123/2345. 分类: tv(核心) tv-ext(激进)
# cn(国内综合) sec(安全软件与更新), LuCI 按分类开关; kill 为固定必拦档.
# 规则库为纯文本 /etc/gwrt-tv-adblock/ads-library.txt, 可整体替换升级,
# 无数据库/SQLite 依赖.
# 设计文档: docs/GWRT-TV-ADBLOCK.md
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-tv-adblock
PKG_VERSION:=2.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-tv-adblock
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GWRT domestic ad blocker (dnsmasq domain layer, text library)
  DEPENDS:=+dnsmasq
  PKGARCH:=all
endef

define Package/gwrt-tv-adblock/description
  Blocks domestic ads at the DNS layer via dnsmasq address=/domain/
  entries driven by a plain-text rule library (no database). Categories:
  tv (TV boot ads + video app ad SDKs), tv-ext (appstore/upgrade/voice,
  may break features), cn (Baidu/Tencent/ByteDance etc. web+app ads and
  analytics), sec (360 suite, Tencent PC/phone manager + risk control,
  Microsoft Defender cloud/telemetry, Windows Update, Office update CDN
  - may break those features by design). Fixed kill category (no switch,
  always on): hao123/2345 navigation hijack domains. Per-category
  switches on the LuCI page, custom block/allow lists, and library
  hot-swap update (replace the txt file or use the update button;
  survives firmware upgrades). Managed by /usr/libexec/gwrt-tv-adblock
  or the LuCI page. NOTE: does not cover pre-roll ads embedded in the
  same CDN as video content, and ads that use hardcoded IPs (see docs
  for the nftset option).
endef

define Package/gwrt-tv-adblock/conffiles
/etc/config/gwrt-tv-adblock
/etc/gwrt-tv-adblock/ads-library.txt
endef

define Build/Compile
endef

define Package/gwrt-tv-adblock/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/gwrt-tv-adblock
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/usr/share/gwrt-tv-adblock
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-tv-adblock $(1)/etc/init.d/gwrt-tv-adblock
	$(INSTALL_BIN) ./files/etc/uci-defaults/90_gwrt-tv-adblock $(1)/etc/uci-defaults/90_gwrt-tv-adblock
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-tv-adblock $(1)/usr/libexec/gwrt-tv-adblock
	$(INSTALL_CONF) ./files/etc/config/gwrt-tv-adblock $(1)/etc/config/gwrt-tv-adblock
	$(INSTALL_CONF) ./files/etc/gwrt-tv-adblock/ads-library.txt $(1)/etc/gwrt-tv-adblock/ads-library.txt
	$(INSTALL_DATA) ./files/etc/gwrt-tv-adblock/ads-library.txt $(1)/usr/share/gwrt-tv-adblock/ads-library.txt
endef

$(eval $(call BuildPackage,gwrt-tv-adblock))
