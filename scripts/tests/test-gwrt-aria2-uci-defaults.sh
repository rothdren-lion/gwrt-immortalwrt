#!/bin/sh
set -eu

# The aria2 download directory is now owned by gwrt-emmc-storage (see
# test-gwrt-emmc-storage.py). The old uci-defaults writer must stay behind as a
# harmless no-op so package upgrades cannot rewrite user paths.
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script="$root/gwrt-theme-V3/theme/luci-theme-gwrt/root/etc/uci-defaults/41_gwrt-aria2-setup"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/storage/downloads"

[ -f "$script" ] || { echo "missing upgrade stub: $script" >&2; exit 1; }

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GWRT_TEST_UCI_LOG"
case "$*" in
	'-q get gwrt.storage.mount') printf '%s\n' "$GWRT_TEST_STORAGE_MOUNT" ;;
	'-q get gwrt.storage.downloads') printf '%s\n' "$GWRT_TEST_DOWNLOAD_DIR" ;;
	'-q get gwrt.downloads_dir') printf '%s\n' "$GWRT_TEST_DOWNLOAD_DIR" ;;
	'-q get aria2.main.dir') printf '%s\n' /mnt/sda1/aria2 ;;
	'-q get aria2.main.enabled') printf '%s\n' 1 ;;
	'-q get aria2.main.rpc_secret') printf '%s\n' preserved-secret ;;
	'-q get aria2.main.user') printf '%s\n' aria2 ;;
esac
EOF
chmod +x "$tmp/bin/uci"
cat >"$tmp/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/logger"

export PATH="$tmp/bin:$PATH"
export GWRT_TEST_UCI_LOG="$tmp/uci.log"
export GWRT_TEST_STORAGE_MOUNT="$tmp/storage"
export GWRT_TEST_DOWNLOAD_DIR="$tmp/storage/downloads"

child_count() {
	find "$tmp/storage/downloads" -mindepth 1 | wc -l
}

# Nothing mounted: the stub must not create directories or touch UCI.
: >"$GWRT_TEST_UCI_LOG"
sh "$script"
[ ! -s "$GWRT_TEST_UCI_LOG" ]
[ "$(child_count)" -eq 0 ]

# Mounted data partition: still no writes, gwrt-emmc-storage owns the paths.
printf '/dev/mmcblk0p27 %s ext4 rw,noatime 0 0\n' "$GWRT_TEST_STORAGE_MOUNT" >"$tmp/mounts"
export GWRT_PROC_MOUNTS="$tmp/mounts"
sh "$script"
[ ! -s "$GWRT_TEST_UCI_LOG" ]
[ "$(child_count)" -eq 0 ]
[ ! -e "$GWRT_TEST_DOWNLOAD_DIR/aria2" ]

# Custom user path stays untouched as well.
sh "$script"
[ ! -s "$GWRT_TEST_UCI_LOG" ]

printf 'PASS aria2 upgrade stub leaves paths to gwrt-emmc-storage and never rewrites user settings\n'
