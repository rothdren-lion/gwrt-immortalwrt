include $(TOPDIR)/rules.mk

# athena-led —— 京东云 AX6600 (Athena / JDCloud RE-CS-02) LED 点阵屏核心守护进程
#
# 上游: https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller
#
# 本地化说明（与上游的两点差异）:
#   1) 上游用 Rust 源码 + Docker 交叉编译产出 aarch64-unknown-linux-musl
#      静态二进制。这里不引入 Rust 工具链（bootstrap 要 1~3 小时，见
#      BUILD-NOTES 里 "rust 无底洞" 那条），直接把上游 Release v2.4.0 的
#      预编译二进制 vendor 进 files/。
#   2) 上游 Makefile 写的是 PKG_HASH:=skip —— 本树 download.pl 只在
#      file_hash 长度是 32/64 时才启用校验，"skip" 会导致每次都重新下载
#      （见 BUILD-NOTES 里 open-app-filter 的下载死锁）。这里改成真实 sha256。
#
# 二进制来源:
#   https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller/releases/download/v2.4.0/athena-led-aarch64-unknown-linux-musl-v2.4.0.tar.gz
#   tarball sha256 = 243560a5e6bb52e5a493f7efa528771a6ab26e325a69b6e1d9d89647eaac5f3f
#   内含 athena-led (aarch64 musl 静态 ELF, stripped)

PKG_NAME:=athena-led
PKG_VERSION:=2.4.0
PKG_RELEASE:=1

PKG_MAINTAINER:=GWRT <https://github.com/unraveloop>
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=JDCloud AX6600 (Athena) LED matrix screen daemon
	URL:=https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller
	DEPENDS:=@(aarch64||arm)
endef

define Package/$(PKG_NAME)/description
Rust daemon driving the JDCloud AX6600 (Athena / RE-CS-02) LED matrix screen.
v2.4.0: dual GPIO backend (character device /dev/gpiochipN with sysfs
fallback), temperature alerting, MQTT control port, night dimming.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/athena_led
endef

define Package/$(PKG_NAME)/install
	# 1. 主程序（上游 Release 预编译的 aarch64-musl 静态 ELF）
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/athena-led $(1)/usr/bin/

	# 2. 物理按键探测脚本 (去掉 .sh 后缀)
	$(INSTALL_BIN) ./files/find_button.sh $(1)/usr/bin/find_button

	# 3. init.d 守护脚本
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/athena_led.init $(1)/etc/init.d/athena_led

	# 4. UCI 配置文件
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/athena_led.config $(1)/etc/config/athena_led

	# 5. 预置动画 (.bin)
	$(INSTALL_DIR) $(1)/etc/athena_led/anim
	$(CP) ./files/anim/*.bin $(1)/etc/athena_led/anim/ 2>/dev/null || true
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# apk / opkg 升级时的配置文件接管
	if [ -f /etc/config/athena_led.apk-new ]; then
		mv /etc/config/athena_led /etc/config/athena_led.v1_bak 2>/dev/null
		mv /etc/config/athena_led.apk-new /etc/config/athena_led
	fi
	if [ -f /etc/config/athena_led-opkg ]; then
		mv /etc/config/athena_led /etc/config/athena_led.v1_bak 2>/dev/null
		mv /etc/config/athena_led-opkg /etc/config/athena_led
	fi
	/etc/init.d/athena_led enable 2>/dev/null
	/etc/init.d/athena_led restart >/dev/null 2>&1
fi
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/athena_led stop >/dev/null 2>&1
	/etc/init.d/athena_led disable 2>/dev/null
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
