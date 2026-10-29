include $(TOPDIR)/rules.mk

LUCI_TITLE:=GWRT Theme
LUCI_DEPENDS:=+luci-base

PKG_NAME:=luci-theme-gwrt
# Display version: YYYY.MM.DD-0X (0X = nth theme change that day).
# scripts/integrate.sh bumps these when the theme content changes.
PKG_VERSION:=2026.10.27
PKG_RELEASE:=03
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0

define Build/Prepare/luci-theme-gwrt
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
	printf '%s\n' '$(PKG_VERSION)-$(PKG_RELEASE)' > \
		$(PKG_BUILD_DIR)/root/usr/share/gwrt/theme-version
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/htdocs/luci-static/resources
	$(CP) $(PKG_BUILD_DIR)/htdocs/luci-static/gwrt/resources/menu-gwrt.js \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/menu-gwrt.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
