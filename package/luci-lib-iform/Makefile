include $(TOPDIR)/rules.mk

PKG_NAME:=luci-lib-iform
PKG_VERSION:=1.1.1
PKG_RELEASE:=20221115
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-lib-iform
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=LuCI form framework - iform
  DEPENDS:=+luci-base
endef

define Package/luci-lib-iform/description
 iform lua library + static JS/CSS (1.0/1.1). Taken from installed package on 192.168.9.9.
endef


# 预编译/原样安装 files/ 下的内容，无构建步骤
define Build/Compile
endef

define Package/luci-lib-iform/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,luci-lib-iform))
