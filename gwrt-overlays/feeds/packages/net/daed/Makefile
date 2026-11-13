# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 ImmortalWrt.org
# GWRT: pin the runtime validated on Linux 6.18 and build the active-plane
# traffic accounting repair instead of shipping the older release executable.

include $(TOPDIR)/rules.mk

PKG_NAME:=daed
PKG_VERSION:=2.1.1
PKG_RELEASE:=3

WING_REV:=dc50308
CORE_REV:=5db27a0
HEADERS_REV:=56937c66784879fe5e2ff89db5bc05aa061d594c
DAED_RUNTIME_VERSION:=daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1

PKG_SOURCE:=dae-wing-$(WING_REV).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/daeuniverse/dae-wing/tar.gz
PKG_SOURCE_URL_FILE:=$(WING_REV)
PKG_HASH:=97474d801d1626b8d38c1abd6d99a182c306b6c4357bc83c50da5e501e32fb3f

PKG_LICENSE:=AGPL-3.0-only MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>
PKG_BUILD_DEPENDS:=golang/host
PKG_FILE_DEPENDS:=$(TOPDIR)/scripts/gwrt-build-daed-runtime.sh \
  $(TOPDIR)/scripts/patches/daed-runtime-overview-active-plane.patch

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Download/daed-core
  FILE:=dae-core-$(CORE_REV).tar.gz
  URL:=https://codeload.github.com/daeuniverse/dae/tar.gz
  URL_FILE:=$(CORE_REV)
  HASH:=2f108404adf9c68d52bb3d836ce6f5cbef9b149b3425945d26b74066fc2e61b7
endef

define Download/daed-bpf-headers
  FILE:=dae-bpf-headers-$(HEADERS_REV).tar.gz
  URL:=https://codeload.github.com/daeuniverse/dae_bpf_headers/tar.gz
  URL_FILE:=$(HEADERS_REV)
  HASH:=af66714e5a192aca39d736e7c9024cde42f1d7471ad31f9577c27dd74eebf6f0
endef

define Download/daed-web
  FILE:=daed-web-$(PKG_VERSION).zip
  URL:=https://github.com/daeuniverse/daed/releases/download/v$(PKG_VERSION)
  URL_FILE:=web.zip
  HASH:=7eb8f42d4860ab7311f87bda2a921bad34a6d54db7edad47466dcb8d9382fea8
endef

$(eval $(call Download,daed-core))
$(eval $(call Download,daed-bpf-headers))
$(eval $(call Download,daed-web))

define Package/daed/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/daeuniverse/daed
endef

define Package/daed
  $(call Package/daed/Default)
  TITLE:=A Modern Dashboard For dae (GWRT runtime traffic repair)
  DEPENDS:=@aarch64 +ca-bundle +kmod-sched-core +kmod-sched-bpf +kmod-xdp-sockets-diag \
    +kmod-veth
endef

define Package/daed-geoip
  $(call Package/daed/Default)
  TITLE:=geoip for daed
  DEPENDS:=+daed +v2ray-geoip
  PKGARCH:=all
endef

define Package/daed-geosite
  $(call Package/daed/Default)
  TITLE:=geosite for daed
  DEPENDS:=+daed +v2ray-geosite
  PKGARCH:=all
endef

define Package/daed/description
  daed is a backend of dae, provides a method to bundle arbitrary
  frontend, dae and geodata into one binary.
  GWRT builds pinned dae-wing/core sources with the active control-plane
  traffic accounting repair and the official v2.1.1 frontend for aarch64.
endef

define Package/daed/conffiles
/etc/daed/wing.db
/etc/config/daed
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) --strip-components=1 -C $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/dae-core/control/kern/headers
	$(TAR) -xzf $(DL_DIR)/dae-core-$(CORE_REV).tar.gz --strip-components=1 -C $(PKG_BUILD_DIR)/dae-core
	$(TAR) -xzf $(DL_DIR)/dae-bpf-headers-$(HEADERS_REV).tar.gz --strip-components=1 -C $(PKG_BUILD_DIR)/dae-core/control/kern/headers
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/dae-core/trace/kern/headers
	$(TAR) -xzf $(DL_DIR)/dae-bpf-headers-$(HEADERS_REV).tar.gz --strip-components=1 -C $(PKG_BUILD_DIR)/dae-core/trace/kern/headers
	unzip -q -o $(DL_DIR)/daed-web-$(PKG_VERSION).zip -d $(PKG_BUILD_DIR)/webrender
	find $(PKG_BUILD_DIR)/webrender/web -type f ! -name '*.gz' -exec gzip -9 -n {} +
endef

define Build/Compile
	$(GO_BIN_PATH) GOTOOLCHAIN=local GOFLAGS=-mod=mod \
		GOMODCACHE="$(GO_MOD_CACHE_DIR)" GOCACHE="$(GO_BUILD_CACHE_DIR)" \
		sh $(TOPDIR)/scripts/gwrt-build-daed-runtime.sh $(PKG_BUILD_DIR) $(PKG_BUILD_DIR)/daed
endef

define Package/daed/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/daed $(1)/usr/bin/daed
	$(INSTALL_DIR) $(1)/usr/share/daed
	printf '%s\n' '$(DAED_RUNTIME_VERSION)' > $(1)/usr/share/daed/gwrt-runtime-version

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/daed.config $(1)/etc/config/daed

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/daed.init $(1)/etc/init.d/daed
endef

define Package/daed-geoip/install
	$(INSTALL_DIR) $(1)/usr/share/daed
	$(LN) ../v2ray/geoip.dat $(1)/usr/share/daed/geoip.dat
endef

define Package/daed-geosite/install
	$(INSTALL_DIR) $(1)/usr/share/daed
	$(LN) ../v2ray/geosite.dat $(1)/usr/share/daed/geosite.dat
endef

$(eval $(call BuildPackage,daed))
$(eval $(call BuildPackage,daed-geoip))
$(eval $(call BuildPackage,daed-geosite))
