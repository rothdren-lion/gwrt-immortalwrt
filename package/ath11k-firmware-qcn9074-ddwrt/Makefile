include $(TOPDIR)/rules.mk

# QCN9074 ath11k firmware (ddwrt build)
#
# 用途：CS-02 (JDCloud AX6600) 的 PCIe QCN9074 5.2G 射频。
#       集成 2.4G/5G 用的是 IPQ6018 内部 AHB 射频（ath11k-firmware-ipq6018-ddwrt），
#       QCN9074 走 PCIe，需要独立的一套固件（amss.bin / m3.bin / regdb.bin）。
#
# 来源：https://github.com/VIKINGYFY/ath11k-firmware-ddwrt
#       固定在 commit e853ab3fedec869ca666e871ef4bab41237b09e6
#       （"Update QCN9074 FW" 2026-03-21），与树里已有的
#       ath11k-firmware-ipq6018-ddwrt (2026.03.21~e853ab3f) 同一批，
#       并与 192.168.9.9 上实机装的 apk V:2026.03.21~e853ab3f-r1 逐字节一致。
#
# 预编译 blob（aarch64 目标），无源码构建。
PKG_NAME:=ath11k-firmware-qcn9074-ddwrt
PKG_VERSION:=2026.03.21~e853ab3f
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=proprietary
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/ath11k-firmware-qcn9074-ddwrt
  SECTION:=kernel
  CATEGORY:=Kernel
  TITLE:=QCN9074 ath11k firmware (ddwrt build)
  DEPENDS:=@TARGET_qualcommax
endef

define Package/ath11k-firmware-qcn9074-ddwrt/description
 QCN9074 ath11k firmware (amss.bin / m3.bin / regdb.bin / board-2.bin) from the
 DD-WRT-based build used by GWRT. Used by the CS-02 / CS-02-GWRT2 PCIe radio
 (5.2G). Files copied verbatim from the installed package on 192.168.9.9
 (apk V:2026.03.21~e853ab3f-r1), which in turn matches upstream
 VIKINGYFY/ath11k-firmware-ddwrt @ e853ab3f byte for byte.

 Note: the per-device calibration/board data actually used at runtime comes
 from ipq-wifi-jdcloud_re-cs-02 (board-jdcloud_re-cs-02.qcn9074), which
 overwrites the generic board-2.bin shipped here.
endef

define Build/Compile
endef

define Package/ath11k-firmware-qcn9074-ddwrt/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/QCN9074/hw1.0
	$(INSTALL_DATA) ./files/lib/firmware/ath11k/QCN9074/hw1.0/* $(1)/lib/firmware/ath11k/QCN9074/hw1.0/
endef

$(eval $(call BuildPackage,ath11k-firmware-qcn9074-ddwrt))
