include $(TOPDIR)/rules.mk

PKG_NAME:=jdcloud-ax3000-wifi-board
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
# 纯 board 数据，无需编译；两个架构通用
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/jdcloud-ax3000-wifi-board
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=JDCloud AX3000 stock WiFi board data (IPQ5018+QCN6122)
  DEPENDS:=@TARGET_qualcommax_ipq50xx
endef

define Package/jdcloud-ax3000-wifi-board/description
 Stock board data (BDF) extracted from the Nwrt factory image
 (Nwrt-2025-06-01-openwrt-ipq50xx-ipq50xx_32-jdcloud_ax3000,
 lib/firmware/{IPQ5018,qcn6122}/bdwlan.bin), installed as the
 ath11k board.bin fallback for both radios.
 Upstream has no JDCloud-AX3000 board file; verify with on-device
 dmesg that the fallback (not a mismatched qmi-board-id entry) is used.
endef

define Build/Compile
endef

define Package/jdcloud-ax3000-wifi-board/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ5018/hw1.0
	$(INSTALL_DATA) ./files/board-ipq5018.bin $(1)/lib/firmware/ath11k/IPQ5018/hw1.0/board.bin
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/QCN6122/hw1.0
	$(INSTALL_DATA) ./files/board-qcn6122.bin $(1)/lib/firmware/ath11k/QCN6122/hw1.0/board.bin
endef

$(eval $(call BuildPackage,jdcloud-ax3000-wifi-board))
