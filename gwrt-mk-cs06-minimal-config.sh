#!/bin/sh
# CS-06 authentication diagnostic image. No production plugin seed or APK restore.
set -eu
TOP=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${OUT:-${1:-$TOP/.config}}
VER=${VER:-261115-01}
case "$VER" in *[!0-9-]*|"") echo 'invalid version' >&2; exit 1 ;; esac
cat > "$OUT" <<EOF
CONFIG_TARGET_qualcommbe=y
CONFIG_TARGET_qualcommbe_ipq53xx=y
CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y
CONFIG_TARGET_MULTI_PROFILE=n
CONFIG_ALL=n
CONFIG_ALL_KMODS=n
CONFIG_ALL_NONSHARED=n
CONFIG_DEVEL=n
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="GWRT"
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_FILENAMES=y
CONFIG_PACKAGE_MAC80211_DEBUGFS=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_dropbear=y
CONFIG_PACKAGE_dnsmasq=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_odhcpd-ipv6only=y
CONFIG_PACKAGE_ppp=y
CONFIG_PACKAGE_ppp-mod-pppoe=y
CONFIG_PACKAGE_wpad-openssl=y
CONFIG_PACKAGE_iw=y
CONFIG_PACKAGE_hostapd-utils=y
CONFIG_PACKAGE_tcpdump-mini=y
CONFIG_PACKAGE_gwrt-cs06-diag-defaults=y
# CONFIG_PACKAGE_gwrt-device-defaults is not set
# CONFIG_PACKAGE_gwrt-agent is not set
# CONFIG_PACKAGE_gwrt-mesh-led is not set
# CONFIG_PACKAGE_gwrt-mesh-apmode is not set
# CONFIG_PACKAGE_luci-theme-gwrt is not set
EOF
echo "Generated CS-06 minimal diagnostic config: $OUT ($VER)"
