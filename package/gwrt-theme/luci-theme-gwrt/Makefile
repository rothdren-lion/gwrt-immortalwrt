include $(TOPDIR)/rules.mk

LUCI_TITLE:=GWRT Theme
LUCI_DEPENDS:=+luci-base

PKG_NAME:=luci-theme-gwrt
PKG_VERSION:=1.0
# Keep this above the last field package (r111).  The theme owns a runtime
# repair hook; a lower release would make apk/opkg keep the older package and
# leave a luci-mod-status upgrade able to restore the stock dashboard.
PKG_RELEASE:=113
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
	printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' > \
		$(PKG_BUILD_DIR)/root/usr/share/gwrt/theme-version
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/htdocs/luci-static/resources
	$(CP) $(PKG_BUILD_DIR)/htdocs/luci-static/gwrt/resources/menu-gwrt.js \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/menu-gwrt.js
endef

# luci-mod-status owns the stock admin_status/index.ut entrypoint.  Installing
# this theme intentionally replaces that entrypoint through the dispatcher
# helper, so a later luci package upgrade can put the stock file back.  Run the
# idempotent repair immediately after an on-device package upgrade and arm the
# boot-time checker; never run it while assembling the firmware image.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /etc/init.d/gwrt-theme 2>/dev/null || true
	[ -x /etc/init.d/gwrt-theme ] && /etc/init.d/gwrt-theme enable >/dev/null 2>&1 || true
	[ -x /etc/init.d/gwrt-theme ] && /etc/init.d/gwrt-theme reload >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
