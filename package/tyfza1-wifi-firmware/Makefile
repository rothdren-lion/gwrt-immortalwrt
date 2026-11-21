include $(TOPDIR)/rules.mk

PKG_NAME:=tyfza1-wifi-firmware
PKG_VERSION:=0.8.5_beta
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/tyfza1-wifi-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=TYFZA1 RTL8852C/RTL8192XB AP firmware and RF inputs
  DEPENDS:=@TARGET_rtl9617c
endef

define Package/tyfza1-wifi-firmware/description
Common firmware and RF parameter inputs for the native TYFZA1 rtl_ax_ap
driver. Per-device flash calibration remains a symlink managed by
tyfza1-pon-control into the factory capsule.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/tyfza1-wifi-firmware/install
	$(INSTALL_DIR) $(1)/lib
	$(CP) ./files/lib/firmware $(1)/lib/
endef

$(eval $(call BuildPackage,tyfza1-wifi-firmware))
