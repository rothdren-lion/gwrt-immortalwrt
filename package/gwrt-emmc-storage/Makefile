include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-emmc-storage
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-emmc-storage
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=GWRT existing eMMC data and swap initialization
  DEPENDS:=+block-mount +blkid +swap-utils +flock
  PKGARCH:=all
endef

define Package/gwrt-emmc-storage/description
  Mount an existing eMMC data filesystem and initialize only explicitly
  designated, signature-free swap partitions. Prepare optional file sharing
  and download services without enabling them.
endef

define Build/Compile
endef

define Package/gwrt-emmc-storage/install
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/etc/init.d $(1)/etc/hotplug.d/block
	$(INSTALL_BIN) ./files/gwrt-emmc-storage $(1)/usr/libexec/gwrt-emmc-storage
	$(INSTALL_BIN) ./files/gwrt-emmc-storage.init $(1)/etc/init.d/gwrt-emmc-storage
	$(INSTALL_BIN) ./files/89-gwrt-emmc-storage $(1)/etc/hotplug.d/block/89-gwrt-emmc-storage
endef

$(eval $(call BuildPackage,gwrt-emmc-storage))
