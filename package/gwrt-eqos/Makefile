#
# GWRT EQoS — 简易限速（tc/htb），配合 luci-theme-gwrt 首页「EQoS 控速」面板
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-eqos
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-eqos
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GWRT EQoS traffic shaping (global + per-device)
  DEPENDS:=+kmod-sched-core +tc-full
  PKGARCH:=all
endef

define Package/gwrt-eqos/description
  tc/htb based rate limiter used by the GWRT dashboard (EQoS 控速).
  UCI config: /etc/config/eqos
    config eqos 'config'   option enabled/download/download_unit/upload/upload_unit
    config device          option enabled/ip/download/download_unit/upload/upload_unit
  Service: /etc/init.d/eqos {start|stop|reload}
endef

define Build/Compile
endef

define Package/gwrt-eqos/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/eqos.init $(1)/etc/init.d/eqos
	$(INSTALL_CONF) ./files/eqos.config $(1)/etc/config/eqos
	$(INSTALL_BIN) ./files/90_gwrt-eqos $(1)/etc/uci-defaults/90_gwrt-eqos
endef

$(eval $(call BuildPackage,gwrt-eqos))
