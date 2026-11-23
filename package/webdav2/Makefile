include $(TOPDIR)/rules.mk

PKG_NAME:=webdav2
PKG_VERSION:=4.3.2
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/webdav2
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WebDAV server (standalone)
  DEPENDS:=@TARGET_qualcommax
endef

define Package/webdav2/description
 Standalone WebDAV2 server (prebuilt aarch64 ELF + init + config). NOT part of samba4.
endef

define Package/webdav2/conffiles
/etc/config/webdav2
endef
# 预编译/原样安装 files/ 下的内容，无构建步骤
define Build/Compile
endef

define Package/webdav2/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,webdav2))
