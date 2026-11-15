include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-cs06-diag-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-cs06-diag-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=CS-06 minimal Wi-Fi diagnostic defaults
  DEPENDS:=@TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06
  CONFLICTS:=gwrt-device-defaults
  PKGARCH:=all
endef

define Build/Compile
endef

# Reuse the production LAN/SSID/encryption defaults verbatim. Deliberately
# exclude data partition creation, APK recovery, mesh pairing and plugin setup.
define Package/gwrt-cs06-diag-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/usr/libexec
	$(INSTALL_BIN) $(TOPDIR)/package/gwrt-device-defaults/files/94_gwrt-lan-ip $(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(TOPDIR)/package/gwrt-device-defaults/files/95_gwrt-wifi-defaults $(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(TOPDIR)/package/gwrt-device-defaults/files/gwrt-ssid-name $(1)/usr/libexec/
endef

$(eval $(call BuildPackage,gwrt-cs06-diag-defaults))
