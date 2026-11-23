# SPDX-License-Identifier: GPL-2.0-only
#
# luci-app-pon-info: 采集并记录全部 PON 参数（光口、身份、OMCI、接口统计）
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon-info
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=LuCI PON information recorder
LUCI_DESCRIPTION:=Reads every exported PON parameter, records state changes to \
/etc/poninfo/history.jsonl and shows them in LuCI under ONU -> PON 信息记录.
LUCI_DEPENDS:=+rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
