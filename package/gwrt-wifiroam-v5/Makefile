#
# GWRT wifiroam v5 覆盖层（不改动预置 apk 包，装到私有目录）
#
# 内容：
#   - wifiroamd.uc   上游 0.1.0-r47 守护进程 + GWRT 补丁（SSID 下发保护 / 子AP 上报地址）
#   - views/*.js     上游 v5 四个页面（已去“打赏”）
#   - res/           页面资源（oui/wifiroam.css/机型图等），首次启动由 97 默认值拷入
#   - menu.json      中文菜单
#   - acl.json       新版 ubus 方法授权
#   - *.lmo          中文翻译（上游 0.261115.10098）
#   - wifiroam-dpi   由 src/wifiroam-dpi.c 重新编译的 DPI 旁路（NFQUEUE + HTTPS SNI）
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gwrt-wifiroam-v5
PKG_VERSION:=0.261115
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gwrt-wifiroam-v5
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GWRT wifiroam v5 overlay (daemon + UI + SNI DPI helper)
  DEPENDS:=+gwrt-device-defaults +gwrt-mesh-apmode +kmod-nfnetlink-queue +libnetfilter-queue +libmnl +libnfnetlink
endef

define Package/gwrt-wifiroam-v5/description
  Upstream wifiroam 0.1.0-r47 daemon and LuCI pages with GWRT patches,
  installed to /usr/share/gwrt/wifiroam-v5 and activated by the first-boot
  script 97_gwrt-wifiroam-defaults. Also ships wifiroam-dpi rebuilt from the
  reconstructed C source (application blocking / QUIC bypass detection).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS) \
		-std=c99 -O2 -Wall -o $(PKG_BUILD_DIR)/wifiroam-dpi \
		$(PKG_BUILD_DIR)/wifiroam-dpi.c -lnetfilter_queue -lnfnetlink -lmnl
endef

define Package/gwrt-wifiroam-v5/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/wifiroam-dpi $(1)/usr/sbin/wifiroam-dpi

	$(INSTALL_DIR) $(1)/usr/share/gwrt/wifiroam-v5/views
	$(INSTALL_DATA) ./files/usr/share/gwrt/wifiroam-v5/wifiroamd.uc $(1)/usr/share/gwrt/wifiroam-v5/
	$(INSTALL_DATA) ./files/usr/share/gwrt/wifiroam-v5/menu.json $(1)/usr/share/gwrt/wifiroam-v5/
	$(INSTALL_DATA) ./files/usr/share/gwrt/wifiroam-v5/acl.json $(1)/usr/share/gwrt/wifiroam-v5/
	$(INSTALL_DATA) ./files/usr/share/gwrt/wifiroam-v5/wifiroam.zh-cn.lmo $(1)/usr/share/gwrt/wifiroam-v5/
	$(INSTALL_DATA) ./files/usr/share/gwrt/wifiroam-v5/views/*.js $(1)/usr/share/gwrt/wifiroam-v5/views/
	$(CP) -r ./files/usr/share/gwrt/wifiroam-v5/res $(1)/usr/share/gwrt/wifiroam-v5/
endef

$(eval $(call BuildPackage,gwrt-wifiroam-v5))
