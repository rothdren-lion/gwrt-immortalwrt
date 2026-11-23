# SPDX-License-Identifier: GPL-2.0-only
#
# KixDNS - Rust 异步非递归 DNS 转发器（使用上游 GitHub Release 预编译二进制，
#          静态链接 musl，不引入 Rust 工具链，编译秒级完成）

include $(TOPDIR)/rules.mk

PKG_NAME:=kixdns
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=GWRT
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_URL:=https://github.com/olicesx/kixdns

# 预编译 asset 选择：只覆盖上游 CI 实际产出的两个 linux-musl 目标。
# 其余架构（arm/mips/riscv…）由下面的 DEPENDS 条件隐藏，不会被选中。
ifeq ($(ARCH),aarch64)
  KIXDNS_ASSET:=kixdns-linux-arm64-musl
  KIXDNS_ASSET_HASH:=37f1bba4d8c5ba9301530b3077aef50572ae3c9a50a7ed75dcf7e13aac484ad5
else ifeq ($(ARCH),x86_64)
  KIXDNS_ASSET:=kixdns-linux-x86_64-musl
  KIXDNS_ASSET_HASH:=e63817b446828a5715c011bc6ee5f741942445567c0c33ad6cf6bae8e9a9bcbf
endif

# PKG_SOURCE 直接用上游 asset 名，这样 URL/PKG_SOURCE 拼起来就是完整下载地址。
# 两种架构的 asset 名互不相同，dl/ 下不会互相覆盖。
ifneq ($(strip $(KIXDNS_ASSET)),)
  PKG_SOURCE:=$(KIXDNS_ASSET)
  PKG_SOURCE_URL:=https://github.com/olicesx/kixdns/releases/download/v$(PKG_VERSION)
  PKG_HASH:=$(KIXDNS_ASSET_HASH)
endif

# 上游产物是裸 ELF，不是归档包：自定义解包方式（直接落进 PKG_BUILD_DIR）。
# 必须在 include package.mk（其第 81 行引入 unpack.mk）之前定义。
define UNPACK_CMD
	mkdir -p $(1) && cp $(DL_DIR)/$(PKG_SOURCE) $(1)/kixdns && chmod 0755 $(1)/kixdns
endef

include $(INCLUDE_DIR)/package.mk

define Package/kixdns
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=KixDNS asynchronous DNS forwarder (prebuilt musl)
  URL:=https://github.com/olicesx/kixdns
  DEPENDS:=$(if $(strip $(KIXDNS_ASSET)),@(aarch64||x86_64))
endef

define Package/kixdns/description
 KixDNS is an asynchronous, non-recursive DNS forwarder written in Rust.
 It accepts DNS over UDP/TCP (optionally inbound DoH), applies an ordered
 pipeline of matchers/actions, then forwards to UDP/TCP/DoH/DoT/DoQ
 upstreams, with in-memory caching, GeoIP/GeoSite routing and hot config
 reload.

 This package installs the statically linked musl binary published on the
 upstream GitHub releases page; no Rust toolchain is required to build it.
endef

define Package/kixdns/conffiles
/etc/config/kixdns
/etc/kixdns/pipeline.json
endef

# 预编译二进制：不做任何编译
define Build/Compile
endef

define Package/kixdns/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/kixdns $(1)/usr/bin/kixdns

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/kixdns.init $(1)/etc/init.d/kixdns

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/kixdns.config $(1)/etc/config/kixdns

	$(INSTALL_DIR) $(1)/etc/kixdns
	$(INSTALL_DATA) ./files/pipeline.json $(1)/etc/kixdns/pipeline.json
endef

$(eval $(call BuildPackage,kixdns))
