include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-wifi-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-wifi-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=GWRT policy for newly detected wireless radios
  DEPENDS:=+wifi-scripts
  PKGARCH:=all
endef

define Package/gwrt-wifi-defaults/description
  Small opt-in policy for wireless configuration generation. Existing radio,
  user and Mesh settings are preserved. Does not install first-boot services.
endef

define Build/Compile
endef

define Package/gwrt-wifi-defaults/install
	$(INSTALL_DIR) $(1)/usr/share/gwrt
	$(INSTALL_DATA) ./files/wifi-defaults.json $(1)/usr/share/gwrt/wifi-defaults.json
endef

$(eval $(call BuildPackage,gwrt-wifi-defaults))
