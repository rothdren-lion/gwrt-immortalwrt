include $(TOPDIR)/rules.mk

PKG_NAME:=tyfza1-pon-firmware
PKG_VERSION:=0.8.5_beta
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/tyfza1-pon-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=TYFZA1 RTL9617C PON SerDes profile tables
  DEPENDS:=@TARGET_rtl9617c
endef

define Package/tyfza1-pon-firmware/description
SerDes register tables requested as realtek/rtl9617c/pon_serdes_<mode>.bin by
the native rtl9617c-pon driver when a line mode is written to the device.
Without them every serdes write fails with ENOENT and the PON downstream never
initialises. Per-unit bosa and flash calibration stay symlinks managed by
tyfza1-pon-control into the factory capsule.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/tyfza1-pon-firmware/install
	$(INSTALL_DIR) $(1)/lib
	$(CP) ./files/lib/firmware $(1)/lib/
endef

$(eval $(call BuildPackage,tyfza1-pon-firmware))
