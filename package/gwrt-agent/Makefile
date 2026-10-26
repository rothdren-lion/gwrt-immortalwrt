include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-agent
PKG_VERSION:=1712
PKG_RELEASE:=6
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0
# shell 部分跨架构通用；预编译 aarch64(musl) 二进制仅随 aarch64 目标安装。
# 其它架构（MT7621 等 mipsel）：不装 .bin，shim 自动退回最小遥测载荷
# （payload() 已有 [ -x $ORIG ] 降级保护）。
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-agent
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=GWRT device agent (prebuilt aarch64 binary + scripts)
  DEPENDS:=+jsonfilter +libubox +curl
endef

define Package/gwrt-agent/description
 GWRT agent: telemetry/OTA/report daemon. v1712-r2 replaces the reporting
 loop with a shell shim matching the current op.gwrt.uk contract
 (Bearer pair_token, no hardware_id field); gwrt-agent.bin keeps the
 original prebuilt aarch64 binary (dump/status/cgi fallbacks).
endef

define Package/gwrt-agent/conffiles
/etc/config/gwrt-agent
endef

# 预编译产物：不编译，直接安装 files/ 下的原样内容
define Build/Compile
endef

define Package/gwrt-agent/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/gwrt-agent $(1)/etc/config/gwrt-agent
	$(INSTALL_DIR) $(1)/etc/gwrt-agent
	$(INSTALL_DATA) ./files/etc/gwrt-agent/gwrt-agent.pub $(1)/etc/gwrt-agent/gwrt-agent.pub
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-agent $(1)/etc/init.d/gwrt-agent
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-mesh-window $(1)/etc/init.d/gwrt-mesh-window
	$(INSTALL_BIN) ./files/etc/init.d/gwrt-ipv6-auto $(1)/etc/init.d/gwrt-ipv6-auto
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90_gwrt-agent-ipv6 $(1)/etc/uci-defaults/90_gwrt-agent-ipv6
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/gwrt-agent $(1)/usr/sbin/gwrt-agent
ifneq ($(findstring aarch64,$(ARCH)),)
	$(INSTALL_BIN) ./files/usr/sbin/gwrt-agent.bin $(1)/usr/sbin/gwrt-agent.bin
endif
	$(INSTALL_BIN) ./files/usr/sbin/gwrt-ipv6-auto.sh $(1)/usr/sbin/gwrt-ipv6-auto.sh
	$(INSTALL_BIN) ./files/usr/sbin/gwrt-mesh-window $(1)/usr/sbin/gwrt-mesh-window
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./files/www/cgi-bin/gwrt-agent $(1)/www/cgi-bin/gwrt-agent
	$(INSTALL_BIN) ./files/www/cgi-bin/mesh_status.sh $(1)/www/cgi-bin/mesh_status.sh
	$(INSTALL_DIR) $(1)/www
	$(INSTALL_DATA) ./files/www/mesh.html $(1)/www/mesh.html
endef

$(eval $(call BuildPackage,gwrt-agent))
