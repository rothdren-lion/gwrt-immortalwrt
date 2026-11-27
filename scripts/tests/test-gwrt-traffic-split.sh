#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
theme_dir=${GWRT_TEST_THEME:-$repo_dir/gwrt-theme-V3/theme/luci-theme-gwrt}
TZ=UTC
export TZ
exec "${GWRT_TEST_UCODE:-ucode}" -L "${GWRT_TEST_UCODE_LIB:-/usr/lib/ucode}" -L "$theme_dir/root/usr/share/ucode" "$repo_dir/scripts/tests/test-gwrt-traffic-split.uc"
