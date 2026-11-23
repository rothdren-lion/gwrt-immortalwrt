include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ecm
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ecm
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=LuCI support for ECM offload status
  DEPENDS:=+luci-base
endef

define Package/luci-app-ecm/description
 ECM (Enhanced Connection Manager) status view. Files taken verbatim from installed package on 192.168.9.9.
endef


# 预编译/原样安装 files/ 下的内容，无构建步骤
define Build/Compile
endef

define Package/luci-app-ecm/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,luci-app-ecm))
