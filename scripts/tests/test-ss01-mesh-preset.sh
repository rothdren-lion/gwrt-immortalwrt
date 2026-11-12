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

# SS-01 has only the integrated 5G radio and must stay on 5.8GHz / 80MHz.
grep -q 'jdcloud,re-ss-01)' "$wifi_defaults" ||
	fail "95_gwrt-wifi-defaults must special-case SS-01"
grep -q 'wireless.\$radio.channel=149' "$wifi_defaults" ||
	fail "SS-01 first boot must pin integrated 5G to ch149"
grep -q 'wireless.\$radio.htmode=HE80' "$wifi_defaults" ||
	fail "SS-01 first boot must cap integrated 5G at HE80"

printf 'PASS: SS-01 mesh preset, board defaults and 5G policy are consistent\n'
