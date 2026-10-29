# GWRT 精简主题（16M SPI 设备专用，如京东云鲁班 RE-CP-02）
#
# 来源：package/gwrt-theme/luci-theme-gwrt（完整版），去掉以下纯图标目录：
#   htdocs/luci-static/gwrt/img/app_icons/    (3.4M，OAF 应用图标，本机无 OAF)
#   htdocs/luci-static/gwrt/img/plugin_icons/ (0.4M，插件图标)
#   htdocs/luci-static/gwrt/img/containers/   (0.2M，容器图标，本机无 docker)
# 其余（css/fonts/js/模板/后端脚本/uci-defaults）与完整版一致。
# 与完整版同路径安装（/luci-static/gwrt），uci-defaults 已改名避免文件冲突；
# 两者混装无意义（完整版会补上图标），想换完整版时先删本包再装完整版。
#
# 主题更新后重新生成：
#   SRC=package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt
#   DST=package/gwrt-theme-lite/luci-theme-gwrt-lite
#   rm -rf $DST/htdocs $DST/root && cp -a $SRC/htdocs $SRC/root $DST/ && \
#   rm -rf $DST/htdocs/luci-static/gwrt/img/{app_icons,plugin_icons,containers}
include $(TOPDIR)/rules.mk

LUCI_TITLE:=GWRT Theme (lite, no per-app icons)
LUCI_DEPENDS:=+luci-base

PKG_NAME:=luci-theme-gwrt-lite
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0

define Build/Prepare/luci-theme-gwrt-lite
	@if grep -Eq 'injectDashboard|buildDashboardHTML|__gwrtDashboard' \
		$(PKG_BUILD_DIR)/htdocs/luci-static/gwrt/resources/gwrt.js; then \
		echo "ERROR: obsolete GWRT dashboard injector is present" >&2; \
		exit 1; \
	fi
	@test ! -e $(PKG_BUILD_DIR)/root/usr/share/ucode/luci/template/admin_status/index.ut.bak-src || { \
		echo "ERROR: obsolete GWRT dashboard backup is present" >&2; \
		exit 1; \
	}
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/gwrt
	printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' > \
		$(PKG_BUILD_DIR)/root/usr/share/gwrt/theme-version
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/htdocs/luci-static/resources
	$(CP) $(PKG_BUILD_DIR)/htdocs/luci-static/gwrt/resources/menu-gwrt.js \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/menu-gwrt.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
