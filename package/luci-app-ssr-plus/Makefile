include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ssr-plus
PKG_VERSION:=196
PKG_RELEASE:=19
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ssr-plus
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=SSR Plus (binary payload from 192.168.9.9 IPK)
  DEPENDS:=+libc +libuci-lua +lua +luci-compat +dns2tcp +dnsmasq-full +ip-full \
	+lua-neturl +microsocks +ipt2socks +lyaml +resolveip +bind-dig +curl \
	+nping +luci-lua-runtime
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-ssr-plus/install
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,luci-app-ssr-plus))
