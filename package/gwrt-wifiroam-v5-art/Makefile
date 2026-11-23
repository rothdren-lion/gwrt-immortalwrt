#
# wifiroam v5 图片资源（OUI 库 / 机型图 / 应用图标）
#
# 与 gwrt-wifiroam-v5 拆开，因为 16M SPI 机型（CP-02）放不下这 3.5 MB：
# 不选本包时页面用预置 apk 自带的旧 oui.js，仅机型图为 404（纯外观）。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-wifiroam-v5-art
PKG_VERSION:=0.261115
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

RES_SRC:=../gwrt-wifiroam-v5/files/usr/share/gwrt/wifiroam-v5/res

define Package/gwrt-wifiroam-v5-art
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=wifiroam v5 OUI 库与机型图（仅大容量机型）
  DEPENDS:=+gwrt-wifiroam-v5
  PKGARCH:=all
endef

define Package/gwrt-wifiroam-v5-art/description
  wifiroam v5 页面用的大体积静态资源：oui.js（1.7 MB）、router/（130 张机型图）、
  apps/（应用图标）。拆成独立包，避免 16 MB SPI 机型镜像超限。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/gwrt-wifiroam-v5-art/install
	$(INSTALL_DIR) $(1)/usr/share/gwrt/wifiroam-v5/res
	$(INSTALL_DATA) $(RES_SRC)/oui.js $(1)/usr/share/gwrt/wifiroam-v5/res/
	$(CP) -r $(RES_SRC)/router $(1)/usr/share/gwrt/wifiroam-v5/res/
	$(CP) -r $(RES_SRC)/apps $(1)/usr/share/gwrt/wifiroam-v5/res/
endef

$(eval $(call BuildPackage,gwrt-wifiroam-v5-art))
