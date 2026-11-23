#!/bin/sh
# SS-01 must ship the GWRT mesh stack. The 261112-01 NSS seed silently dropped
# gwrt-device-defaults / gwrt-mesh-apmode / gwrt-mesh-led, leaving gwrt-agent
# pointing at wifiroam and AP-mode helpers that were not in the image.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
seed="$root/config.ss01-261101-01-nss"
defaults="$root/target/linux/qualcommax/ipq60xx/base-files/etc/board.d/04_defaults"
wifi_defaults="$root/package/gwrt-device-defaults/files/95_gwrt-wifi-defaults"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -f "$seed" ] || fail "missing SS-01 CI seed: $seed"

for package in gwrt-device-defaults gwrt-mesh-apmode gwrt-mesh-led gwrt-agent; do
	grep -qx "CONFIG_PACKAGE_${package}=y" "$seed" ||
		fail "SS-01 seed must enable $package"
done

# uci-defaults.sh provides no ucidef_set_wireless_channel; calling it aborts
# board.json generation before the 5G defaults are flushed.
if grep -v '^[[:space:]]*#' "$defaults" | grep -q 'ucidef_set_wireless_channel'; then
	fail "04_defaults must not call the removed ucidef_set_wireless_channel helper"
fi

# SS-01 retains its deferred readiness barrier. Radio settings are generated
# before service startup, rather than written and reloaded by this barrier.
grep -q 'jdcloud,re-ss-01' "$wifi_defaults" ||
	fail "95_gwrt-wifi-defaults must retain SS-01 readiness handling"
if grep -v '^[[:space:]]*#' "$wifi_defaults" | grep -Eq 'uci .* (set|commit)|wifi reload'; then
	fail "95_gwrt-wifi-defaults must not rewrite or reload generated wireless settings"
fi
policy="$root/package/network/config/wifi-scripts/files/lib/wifi/gwrt-defaults.uc"
grep -Fq 'high ? [149, 36] : [36, 149]' "$policy" ||
	fail "integrated JDCloud 5G must prefer supported ch149"
grep -Fq 'for (let width in [80, 40, 20])' "$policy" ||
	fail "HE radio defaults must cap bandwidth at 80 MHz"
grep -Fq '+gwrt-wifi-defaults' "$root/package/gwrt-device-defaults/Makefile" ||
	fail "device defaults must install the generation policy dependency"
[ -f "$root/package/gwrt-wifi-defaults/files/wifi-defaults.json" ] ||
	fail "missing shared generation policy"

printf 'PASS: SS-01 mesh preset, board defaults and 5G policy are consistent\n'
