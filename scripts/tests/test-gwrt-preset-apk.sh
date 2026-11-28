#!/bin/sh
# Regression test for the offline wifiroam APK installer.
# The bundled APKs are built for aarch64_cortex-a53; targets reporting
# aarch64_cortex-a55 (e.g. TYFZA1) must still install them via the
# --arch fallback, otherwise Mesh/wifiroam never gets installed.
set -eu

top=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script="$top/package/gwrt-device-defaults/files/96_gwrt-preset-apk"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/apk" "$tmp/etc/gwrt" "$tmp/apkdb" "$tmp/sysinfo"
echo 'aarch64-test-board' > "$tmp/sysinfo/board_name"
: > "$tmp/apk/wifiroam-0.1.0-r1.apk"
: > "$tmp/calls"

# Fake apk: a plain "add" fails (simulating the a55 rejecting an a53 APK),
# while "add --arch aarch64_cortex-a53" succeeds. "info" always succeeds so
# the script's post-install verification passes.
cat > "$tmp/bin/apk" <<'APK'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$1" in
  info) exit 0 ;;
  add)
    for arg in "$@"; do
      [ "$arg" = "--arch" ] && exit 0
    done
    echo "ERROR: unable to select packages: uninstallable arch aarch64_cortex-a53" >&2
    exit 1 ;;
esac
exit 0
APK
chmod 755 "$tmp/bin/apk"

set +e
PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" \
GWRT_APK_DIR="$tmp/apk" GWRT_APK_MARK="$tmp/etc/gwrt/wifiroam-apk.done" \
GWRT_APK_LOG="$tmp/gwrt-wifiroam-apk.log" GWRT_APK_DB="$tmp/apkdb" \
sh "$script" >/dev/null 2>&1
rc=$?
set -e

# The installer must succeed via the fallback and mark the preset done.
[ "$rc" -eq 0 ] || { echo "FAIL: installer exited $rc" >&2; cat "$tmp/gwrt-wifiroam-apk.log" >&2; exit 1; }
[ -f "$tmp/etc/gwrt/wifiroam-apk.done" ] || { echo 'FAIL: no done marker' >&2; exit 1; }
grep -q -- '--arch aarch64_cortex-a53' "$tmp/calls" || {
  echo 'FAIL: installer never used the --arch aarch64_cortex-a53 fallback' >&2
  echo 'calls:' >&2; cat "$tmp/calls" >&2; exit 1
}

echo 'PASS: preset APK installer falls back to compatible APK arch'
