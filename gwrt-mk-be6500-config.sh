#!/bin/sh
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${OUT:-$top/config.be6500-${VER:-261107-02}}
OUT="$out" sh "$top/gwrt-mk-cs06-config.sh"
sed -i \
	-e 's/^CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y$/# CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06 is not set/' \
	-e 's/^CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-06"$/CONFIG_TARGET_PROFILE="DEVICE_xiaomi_be6500"/' \
	-e '/^CONFIG_PACKAGE_ipq-wifi-jdcloud_re-cs-06=/d' \
	-e '/^CONFIG_DEFAULT_ipq-wifi-jdcloud_re-cs-06=/d' \
	-e '/^# CONFIG_PACKAGE_ipq-wifi-xiaomi_be6500 is not set$/d' \
	"$out"
printf '%s\n' 'CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_xiaomi_be6500=y' >> "$out"
echo "generated Xiaomi BE6500 with its own device defaults: $out"
