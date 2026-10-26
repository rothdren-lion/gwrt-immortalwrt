#
# GWRT mesh 状态灯 + 一键配对
#
# 支持机型：
#   XINGLOO AX3000 (CF-WR630AX) : blue:status          （默认；可用 uci 改成 green:status）
#   Qihoo 360T7                 : red:status + green:status（两灯同亮 = 琥珀色/黄色）
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-mesh-led
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-mesh-led
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=GWRT mesh status LED + one-key pairing
  DEPENDS:=+jsonfilter
  PKGARCH:=all
endef

define Package/gwrt-mesh-led/description
  Drives the mesh indicator LED from wifiroam state:
    off      = mesh disabled / no daemon
    slow blink = waiting for pairing (unconfigured or sub AP without uplink)
    fast blink = main AP sees unpaired APs
    solid    = mesh established (peers online / sub AP linked to main AP)
  Also provides the WPS/MESH button handler for one-key pairing.
endef

define Build/Compile
endef

define Package/gwrt-mesh-led/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/rc.wps $(1)/etc/uci-defaults \
		$(1)/usr/libexec
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-mesh-led $(1)/etc/init.d/gwrt-mesh-led
	$(INSTALL_BIN) ./files/etc/rc.wps/50-gwrt-mesh $(1)/etc/rc.wps/50-gwrt-mesh
	$(INSTALL_BIN) ./files/etc/uci-defaults/99_gwrt-mesh-led $(1)/etc/uci-defaults/99_gwrt-mesh-led
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-mesh-led $(1)/usr/libexec/gwrt-mesh-led
	$(INSTALL_BIN) ./files/usr/libexec/gwrt-mesh-pair $(1)/usr/libexec/gwrt-mesh-pair
endef

$(eval $(call BuildPackage,gwrt-mesh-led))
