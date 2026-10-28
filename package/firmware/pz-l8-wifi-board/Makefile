include $(TOPDIR)/rules.mk

PKG_NAME:=pz-l8-wifi-board
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
# 纯 board 数据，无需编译；两个架构通用
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/pz-l8-wifi-board
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=CMCC PZ-L8 stock WiFi board data (IPQ5018+QCN6122)
  DEPENDS:=@TARGET_qualcommax_ipq50xx
endef

define Package/pz-l8-wifi-board/description
 Stock board data (BDF) extracted from the factory Nwrt image
 (PZL8-AX3000-openwrt-v1.6.bin wifi_fw volume), installed as the
 ath11k board.bin fallback for both radios:
   IPQ5018 2.4G (WIFI0, q6_wcss) and QCN6122 5G (WIFI1, userpd2).
 Upstream qca-wireless has no CMCC-PZ-L8 board file and the DTS
 keeps both radios disabled; this package + the DTS/hotplug
 changes make PZ-L8 usable as a GWRT mesh AP.
endef

define Build/Compile
endef

define Package/pz-l8-wifi-board/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ5018/hw1.0
	$(INSTALL_DATA) ./files/board-ipq5018.bin $(1)/lib/firmware/ath11k/IPQ5018/hw1.0/board.bin
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/QCN6122/hw1.0
	$(INSTALL_DATA) ./files/board-qcn6122.bin $(1)/lib/firmware/ath11k/QCN6122/hw1.0/board.bin
endef

$(eval $(call BuildPackage,pz-l8-wifi-board))
