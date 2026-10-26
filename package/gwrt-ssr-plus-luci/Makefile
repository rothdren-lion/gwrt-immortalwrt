#
# luci-app-ssr-plus 预编译包（all 架构，来自 helloworld feed 的 196-r19）
# 只解包数据文件进镜像；其运行依赖（dns2tcp/ipt2socks/microsocks/xray 等）
# 需另行安装，否则面板能显示但无法真正代理。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-ssr-plus-luci
PKG_VERSION:=196.0
PKG_RELEASE:=19
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-ssr-plus-luci
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=luci-app-ssr-plus (prebuilt files)
  DEPENDS:=+luci-compat +luci-lua-runtime +curl
  PKGARCH:=all
endef

define Package/gwrt-ssr-plus-luci/description
  Prebuilt luci-app-ssr-plus (196-r19) files + zh-cn i18n unpacked from upstream .ipk files.
  The proxy backends (xray/v2ray/trojan, dns2tcp, ipt2socks, microsocks ...)
  are not bundled.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/app $(PKG_BUILD_DIR)/i18n
	$(CP) ./src/luci-app-ssr-plus_*.ipk $(PKG_BUILD_DIR)/app/app.ipk
	$(CP) ./src/luci-i18n-ssr-plus-zh-cn_*.ipk $(PKG_BUILD_DIR)/i18n/i18n.ipk
	cd $(PKG_BUILD_DIR)/app && tar xzf app.ipk
	cd $(PKG_BUILD_DIR)/i18n && tar xzf i18n.ipk
endef

define Build/Compile
endef

define Package/gwrt-ssr-plus-luci/install
	$(INSTALL_DIR) $(1)
	$(TAR) -xzf $(PKG_BUILD_DIR)/app/data.tar.gz -C $(1)
	# 简体中文语言包（luci-i18n-ssr-plus-zh-cn -> ssr-plus.zh-cn.lmo）
	$(TAR) -xzf $(PKG_BUILD_DIR)/i18n/data.tar.gz -C $(1)
endef

$(eval $(call BuildPackage,gwrt-ssr-plus-luci))
