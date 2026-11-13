include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=open-app-filter
PKG_RELEASE:=3

PKG_SOURCE_URL:=https://github.com/destan19/OpenAppFilter.git
PKG_SOURCE_PROTO:=git
PKG_SOURCE_DATE:=2026-09-24
PKG_SOURCE_VERSION:=7fcf9e87dc75f7c28c74e09504a4efa0a2db3c92
PKG_HASH:=2f03988a01b8049b7dee720ef5f24c8432dfe1508caaf80bf353155f7df27b82

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:

define KernelPackage/oaf
  SECTION:=Kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Netfilter Extensions
  TITLE:=open app filter kernel module
  FILES:=$(PKG_BUILD_DIR)/oaf/src/oaf.ko
  DEPENDS:=+kmod-ipt-conntrack
  AUTOLOAD:=$(call AutoLoad,0,oaf)
endef

define Package/appfilter
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+libblobmsg-json +libjson-c +libpthread +libubox +libubus +libuci +libuci-lua +lua +kmod-oaf +libcurl +libsqlite3
  TITLE:=App filter userspace module
endef

MAKE_PATH:=open-app-filter/src
MAKE_VARS+= LIBS="-lm -lpthread -lubox -luci -lubus -ljson-c -lblobmsg_json -lcurl -lsqlite3"

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(PKG_BUILD_DIR)/oaf/src" modules

	$(call Build/Compile/Default)
endef

define Package/appfilter/conffiles
/etc/config/appfilter
/etc/config/appfilter_whitelist
/etc/config/fwx
/etc/config/fwx_record
/etc/config/macfilter
/etc/config/macfilter_whitelist
/etc/config/mac_blacklist
/etc/config/user_info
/etc/fwxd/feature.bin
/etc/fwxd/custom_feature.cfg
endef

define Package/appfilter/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/open-app-filter/src/oafd $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/open-app-filter/files/hnat.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/open-app-filter/files/rule_manager.lua $(1)/usr/bin/rule_manager
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/appfilter.config $(1)/etc/config/appfilter
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/appfilter_whitelist.config $(1)/etc/config/appfilter_whitelist
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/fwx.config $(1)/etc/config/fwx
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/fwx_record.config $(1)/etc/config/fwx_record
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/macfilter.config $(1)/etc/config/macfilter
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/macfilter_whitelist.config $(1)/etc/config/macfilter_whitelist
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/mac_blacklist.config $(1)/etc/config/mac_blacklist
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/open-app-filter/files/user_info.config $(1)/etc/config/user_info
	$(INSTALL_DIR) $(1)/etc/fwxd
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/open-app-filter/files/feature.bin $(1)/etc/fwxd/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/open-app-filter/files/custom_feature.cfg $(1)/etc/fwxd/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/open-app-filter/files/appfilter.init $(1)/etc/init.d/appfilter
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/open-app-filter/files/oaf_version $(1)/etc/oaf_version
endef

$(eval $(call KernelPackage,oaf))
$(eval $(call BuildPackage,appfilter))
