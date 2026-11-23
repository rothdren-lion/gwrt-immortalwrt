include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=qualcommax
BOARDNAME:=Qualcomm Atheros 64-bit devices
FEATURES:=squashfs fpu ramdisk nand emmc
SUBTARGETS:=ipq807x ipq60xx ipq50xx

KERNELNAME:=Image dtbs
KERNEL_PATCHVER:=6.18

include $(INCLUDE_DIR)/target.mk
DEFAULT_PACKAGES += \
	kmod-usb3 kmod-usb-dwc3 kmod-usb-dwc3-qcom \
	kmod-leds-gpio kmod-gpio-button-hotplug \
	kmod-ath11k-ahb wpad-openssl \
	uboot-envtools losetup \
	automount cpufreq \
	kmod-qca-nss-dp kmod-qca-nss-ecm \
	kmod-qca-nss-drv kmod-qca-nss-drv-bridge-mgr

$(eval $(call BuildTarget))
