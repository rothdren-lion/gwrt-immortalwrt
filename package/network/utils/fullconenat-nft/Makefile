# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2018 Chion Tang <tech@chionlab.moe>
#   Original xt_FULLCONENAT and related iptables extension author
# Copyright (c) 2019-2022 GitHub/llccd Twitter/@gNodeB
#   Added IPv6 support for xt_FULLCONENAT and ip6tables extension
#   Ported to recent kernel versions
# Copyright (c) 2022 Syrone Wong <wong.syrone@gmail.com>
#   Massively rewrite the whole module, split the original code into library and nftables 'fullcone' expression module

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=fullconenat-nft
PKG_RELEASE:=3

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/fullcone-nat-nftables/nft-fullcone.git
PKG_SOURCE_DATE:=2023-05-17
PKG_SOURCE_VERSION:=07d93b626ce5ea885cd16f9ab07fac3213c355d9
PKG_MIRROR_HASH:=84d54b5e6091148c31d4eddff2f8ead763c9ef318fdf35098a6f9cea9a29b7c8

PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Syrone Wong <wong.syrone@gmail.com>

include $(INCLUDE_DIR)/package.mk

define KernelPackage/nft-fullcone
  SUBMENU:=Netfilter Extensions
  DEPENDS:=+kmod-nft-nat
  TITLE:=nftables fullcone expression support
  FILES:= $(PKG_BUILD_DIR)/src/nft_fullcone.ko
  # 2026-10-10 GWRT: 不再强制 NF_CONNTRACK_CHAIN_EVENTS=y（源码两种 API 都有分支，
  # !defined(CONFIG_NF_CONNTRACK_CHAIN_EVENTS) 时走 5.15+ 新单参 API）；
  # qca-nss-ecm 2026.04 只支持新 API，强制 y 会让 ecm 编译失败，统一走新 API。
  KCONFIG:= \
    CONFIG_NF_CONNTRACK_EVENTS=y
  AUTOLOAD:=$(call AutoProbe,nft_fullcone)
endef

define KernelPackage/nft-fullcone/Description
  Kernel module adds the fullcone expression that you can use
  to perform NAT in the RFC3489-compatible full cone SNAT flavour.
  Currently only UDP traffic is supported for full-cone NAT.
  For other protos FULLCONENAT is equivalent to MASQUERADE.
endef

define Build/Compile
	+$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)/src" modules
endef

$(eval $(call KernelPackage,nft-fullcone))
