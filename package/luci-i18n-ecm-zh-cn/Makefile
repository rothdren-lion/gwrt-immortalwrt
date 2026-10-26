include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-ecm-zh-cn
PKG_VERSION:=0.260729.42294
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-ecm-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=luci-app-ecm - Chinese translation
  DEPENDS:=+luci-app-ecm
endef

define Package/luci-i18n-ecm-zh-cn/description
 Chinese translations for luci-app-ecm (prebuilt .lmo).
endef


# 预编译/原样安装 files/ 下的内容，无构建步骤
define Build/Compile
endef

define Package/luci-i18n-ecm-zh-cn/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,luci-i18n-ecm-zh-cn))
