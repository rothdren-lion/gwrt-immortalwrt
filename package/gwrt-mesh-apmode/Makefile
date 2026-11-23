include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-mesh-apmode
PKG_VERSION:=1.1
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-mesh-apmode
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=GWRT wired-first satellite AP controller
  DEPENDS:=+jsonfilter +relayd +flock
  PKGARCH:=all
endef

define Package/gwrt-mesh-apmode/description
  Selects the paired main AP over Ethernet or Wi-Fi, relays IPv4 DHCP over
  a wireless backhaul, and temporarily restores the saved router settings
  between searches when neither uplink is available.
endef

define Build/Compile
endef

define Package/gwrt-mesh-apmode/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/libexec \
		$(1)/usr/share/gwrt/mesh-apmode
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-mesh-apmode $(1)/etc/init.d/gwrt-mesh-apmode
	$(INSTALL_BIN) ./files/etc/uci-defaults/98_gwrt-mesh-apmode $(1)/etc/uci-defaults/98_gwrt-mesh-apmode
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-mesh-apmode $(1)/usr/libexec/gwrt-mesh-apmode
	$(INSTALL_DATA) ./files/usr/share/gwrt/mesh-apmode/*.sh $(1)/usr/share/gwrt/mesh-apmode/
endef

$(eval $(call BuildPackage,gwrt-mesh-apmode))
