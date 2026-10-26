#
# GWRT mesh AP 模式
#
# 未组网：普通路由（192.168.3.3 + 本机 DHCP）
# 已组网：切成真 AP（关本机 DHCP、LAN 取主路由分配的地址、
#         有线回传时把 WAN 并进 br-lan 取消 NAT）
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-mesh-apmode
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-mesh-apmode
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=GWRT mesh -> real AP mode switch
  DEPENDS:=+jsonfilter
  PKGARCH:=all
endef

define Package/gwrt-mesh-apmode/description
  Switches the device to a real access point once it is paired to a mesh
  main router (CAP): disables the local DHCP server, makes br-lan a DHCP
  client (management IP assigned by the main router) and bridges the wired
  uplink (WAN) into br-lan. Reverts to the normal router (192.168.3.3 +
  DHCP) when the mesh link is lost.
endef

define Build/Compile
endef

define Package/gwrt-mesh-apmode/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/libexec
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-mesh-apmode $(1)/etc/init.d/gwrt-mesh-apmode
	$(INSTALL_BIN) ./files/etc/uci-defaults/98_gwrt-mesh-apmode $(1)/etc/uci-defaults/98_gwrt-mesh-apmode
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-mesh-apmode $(1)/usr/libexec/gwrt-mesh-apmode
endef

$(eval $(call BuildPackage,gwrt-mesh-apmode))
