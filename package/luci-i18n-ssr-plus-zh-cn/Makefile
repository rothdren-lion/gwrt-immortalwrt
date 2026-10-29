include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-ssr-plus-zh-cn
PKG_VERSION:=0
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-ssr-plus-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=SSR Plus Simplified Chinese translation
  DEPENDS:=+luci-app-ssr-plus
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-i18n-ssr-plus-zh-cn/install
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,luci-i18n-ssr-plus-zh-cn))
