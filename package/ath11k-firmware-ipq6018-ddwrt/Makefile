include $(TOPDIR)/rules.mk

PKG_NAME:=ath11k-firmware-ipq6018-ddwrt
PKG_VERSION:=2026.03.21~e853ab3f
PKG_RELEASE:=1
PKG_MAINTAINER:=GWRT
PKG_LICENSE:=proprietary
# 预编译固件 blob（aarch64 目标），无源码构建
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/ath11k-firmware-ipq6018-ddwrt
  SECTION:=kernel
  CATEGORY:=Kernel
  TITLE:=IPQ6018 ath11k firmware (ddwrt build)
  DEPENDS:=@TARGET_qualcommax
endef

define Package/ath11k-firmware-ipq6018-ddwrt/description
 IPQ6018 ath11k firmware (WLAN.HK / Q6 / M3 + board-2.bin + regdb) from the
 DD-WRT-based build used by GWRT. Files copied verbatim from the installed
 package on 192.168.9.9 (apk V:2026.03.21~e853ab3f-r1, S:2548271).
 Note: board calibration for the device itself comes from ipq-wifi-*.
endef

define Build/Compile
endef

define Package/ath11k-firmware-ipq6018-ddwrt/install
	$(INSTALL_DIR) $(1)/lib/firmware/IPQ6018
	$(INSTALL_DATA) ./files/lib/firmware/IPQ6018/* $(1)/lib/firmware/IPQ6018/
endef

$(eval $(call BuildPackage,ath11k-firmware-ipq6018-ddwrt))
