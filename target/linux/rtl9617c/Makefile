# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=rtl9617c
BOARDNAME:=Realtek RTL9617C (Taurus)
CPU_TYPE:=cortex-a55
# mbedtls 3.6 + GCC 14 + musl fortify：-D_FORTIFY_SOURCE 让 string.h 的 memset
# 变成 __always_inline，只要 target 带 crypto/NEON 扩展（-mcpu=cortex-a55 或
# -march=armv8-a+crypto）就会报 "target specific option mismatch"。
# 这里用最保守的 armv8-a（不含 crypto），只保留 -mtune 做调度优化；
# 同时 workflow 里对 mbedtls 关掉 FORTIFY（见 Install feeds 步骤）。
CPU_CFLAGS_cortex-a55:=-march=armv8-a -mtune=cortex-a55
SUBTARGETS:=generic
FEATURES:=fpu nand ramdisk squashfs targz usb
DEPENDS:=+@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT
KERNEL_PATCHVER:=6.18
KERNELNAME:=Image
DEVICE_TYPE:=router

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += ubi-utils nand-utils ucode-mod-uci

define Target/Description
  Native RTL9617C support. TYFZA1 serial bring-up; hardware validation pending.
endef

$(eval $(call BuildTarget))
