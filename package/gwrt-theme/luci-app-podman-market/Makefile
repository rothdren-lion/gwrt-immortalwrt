include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Podman Market - one-click container plugin deployment
LUCI_DEPENDS:=+luci-base +rpcd
# view JS ships pre-minified; keep as-is (same reason as theme CSS above).
LUCI_MINIFY_JS:=0

PKG_NAME:=luci-app-podman-market
PKG_VERSION:=1.0
PKG_RELEASE:=1

# GWRT: no hard dependency on podman on purpose.
# The rpcd backend reports podman_present=false when podman is absent and the
# theme (gwrt.js initPodmanMarketVisibility) hides the menu entry, so the app
# can be baked into every firmware while the entry only shows with podman.
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
