include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kixdns-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=KixDNS control (lite)
LUCI_DESCRIPTION:=Minimal LuCI page to start or stop KixDNS and to change its listen port
LUCI_DEPENDS:=+luci-base +kixdns
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=GWRT

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
