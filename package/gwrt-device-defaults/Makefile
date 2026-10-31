#
# GWRT 机型默认配置（仅 XINGLOO AX3000 / CF-WR630AX 使用）
# 首次启动给无线设置一个可用的默认 SSID/密码，避免"WiFi 未配置"。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-device-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-device-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=GWRT XINGLOO AX3000 first-boot defaults
  PKGARCH:=all
endef

define Package/gwrt-device-defaults/description
  First-boot defaults for XINGLOO AX3000 (CF-WR630AX):
  wireless SSID/key, radios enabled, LAN/WAN sanity check.
endef

define Build/Compile
endef

define Package/gwrt-device-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/etc/init.d \
		$(1)/usr/libexec $(1)/usr/share/gwrt/apk $(1)/usr/share/gwrt/wifiroam
	$(INSTALL_BIN) ./files/92_gwrt-wifiroam-fw $(1)/etc/uci-defaults/92_gwrt-wifiroam-fw
	$(INSTALL_BIN) ./files/93_gwrt-lang $(1)/etc/uci-defaults/93_gwrt-lang
	$(INSTALL_BIN) ./files/94_gwrt-lan-ip $(1)/etc/uci-defaults/94_gwrt-lan-ip
	$(INSTALL_BIN) ./files/95_gwrt-wifi-defaults $(1)/etc/uci-defaults/95_gwrt-wifi-defaults
# 预置离线 apk：wifiroam 三件是纯脚本，全架构通用，常装；
# ucode-mod-socket 仅 aarch64 目标附带（mipsel 等由 ucode 包直接编入固件）。
	$(INSTALL_BIN) ./files/96_gwrt-preset-apk $(1)/etc/uci-defaults/96_gwrt-preset-apk
	$(INSTALL_BIN) ./files/97_gwrt-wifiroam-defaults $(1)/etc/uci-defaults/97_gwrt-wifiroam-defaults
	$(INSTALL_BIN) ./files/98_gwrt-agent-defaults $(1)/etc/uci-defaults/98_gwrt-agent-defaults
	$(INSTALL_BIN) ./files/99_gwrt-data-part $(1)/etc/uci-defaults/99_gwrt-data-part
	$(INSTALL_BIN) ./files/gwrt-ssid-name $(1)/usr/libexec/gwrt-ssid-name
	$(INSTALL_DATA) ./files/apk/luci-app-wifiroam-*.apk ./files/apk/luci-i18n-wifiroam-*.apk ./files/apk/wifiroam-*.apk $(1)/usr/share/gwrt/apk/
ifneq ($(findstring aarch64,$(ARCH)),)
	$(INSTALL_DATA) ./files/apk/ucode-mod-socket*.apk $(1)/usr/share/gwrt/apk/
endif
	$(INSTALL_BIN) ./files/gwrt-wifiroam-autopair $(1)/usr/libexec/gwrt-wifiroam-autopair
	$(INSTALL_BIN) ./files/gwrt-wifiroam-autopair.init $(1)/etc/init.d/gwrt-wifiroam-autopair
	$(INSTALL_DATA) ./files/wifiroam/*.js $(1)/usr/share/gwrt/wifiroam/
	$(INSTALL_DATA) ./files/wifiroam/wifiroamd.uc $(1)/usr/share/gwrt/wifiroam/wifiroamd.uc
	$(INSTALL_DATA) ./files/wifiroam/menu.json $(1)/usr/share/gwrt/wifiroam/menu.json
endef

$(eval $(call BuildPackage,gwrt-device-defaults))
