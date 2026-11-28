# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=rtl9617c
BOARDNAME:=Realtek RTL9617C (Taurus)
SUBTARGETS:=generic
FEATURES:=fpu nand ramdisk squashfs
CPU_TYPE:=cortex-a53

KERNEL_PATCHVER:=6.18

include $(INCLUDE_DIR)/target.mk

# 本 target 固定使用 6.18.64：crysister 的驱动/补丁按 .64 校准。
# 其它 target（an758x）继续用 generic/kernel-6.18 里的 .62。
LINUX_VERSION:=6.18.64
LINUX_KERNEL_HASH:=020d45510c539972e6f14c5c71566878d3b7ef56fb082b3e09134f2ebaade562
DEFAULT_PACKAGES += ubi-utils nand-utils ucode-mod-uci kmod-gpio-button-hotplug

define Target/Description
  Native OpenWrt support for the Realtek RTL9617C (Taurus) SoC family routers
endef

$(eval $(call BuildTarget))
