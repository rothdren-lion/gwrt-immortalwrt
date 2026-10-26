include $(TOPDIR)/rules.mk

PKG_NAME:=v2dat
PKG_VERSION:=2022.12.15~47b8ee51
PKG_RELEASE:=4
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/v2dat
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=v2ray geo data tool (v2dat)
  DEPENDS:=@TARGET_qualcommax
endef

define Package/v2dat/description
 Prebuilt aarch64 v2dat binary for unpacking v2ray geoip/geoosite dat files.
endef


# 预编译/原样安装 files/ 下的内容，无构建步骤
define Build/Compile
endef

define Package/v2dat/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,v2dat))
