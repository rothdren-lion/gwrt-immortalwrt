#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script="$root/gwrt-theme-V3/theme/luci-theme-gwrt/root/etc/uci-defaults/41_gwrt-aria2-setup"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/storage/downloads"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get gwrt.downloads_dir') printf '%s\n' "$GWRT_TEST_DOWNLOAD_DIR" ;;
	'-q get gwrt.storage_mount') printf '%s\n' "$GWRT_TEST_STORAGE_MOUNT" ;;
	'-q get aria2.main.dir') printf '%s\n' "$GWRT_TEST_ARIA_DIR" ;;
	'-q get aria2.main.enabled') printf '%s\n' 1 ;;
	'-q get aria2.main.rpc_secret') printf '%s\n' preserved-secret ;;
	'-q get aria2.main.user') printf '%s\n' aria2 ;;
	'-q set aria2.main.dir='*) printf '%s\n' "$*" >>"$GWRT_TEST_UCI_LOG" ;;
	'-q commit aria2') printf '%s\n' "$*" >>"$GWRT_TEST_UCI_LOG" ;;
esac
EOF
chmod +x "$tmp/bin/uci"
cat >"$tmp/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/logger"

export PATH="$tmp/bin:$PATH"
export GWRT_PROC_MOUNTS="$tmp/mounts"
export GWRT_TEST_UCI_LOG="$tmp/uci.log"
export GWRT_TEST_STORAGE_MOUNT="$tmp/storage"
export GWRT_TEST_DOWNLOAD_DIR="$tmp/storage/downloads"
export GWRT_TEST_ARIA_DIR=/mnt/sda1/aria2

: >"$GWRT_PROC_MOUNTS"
: >"$GWRT_TEST_UCI_LOG"
sh "$script"
[ ! -s "$GWRT_TEST_UCI_LOG" ]
[ ! -e "$GWRT_TEST_DOWNLOAD_DIR/aria2" ]

printf '/dev/mmcblk0p27 %s ext4 rw,noatime 0 0\n' "$GWRT_TEST_STORAGE_MOUNT" >"$GWRT_PROC_MOUNTS"
sh "$script"
[ -d "$GWRT_TEST_DOWNLOAD_DIR/aria2" ]
[ "$(wc -l <"$GWRT_TEST_UCI_LOG")" -eq 2 ]
grep -Fq "aria2.main.dir=$GWRT_TEST_DOWNLOAD_DIR/aria2" "$GWRT_TEST_UCI_LOG"
! grep -E 'enabled|rpc_secret|user' "$GWRT_TEST_UCI_LOG"

: >"$GWRT_TEST_UCI_LOG"
GWRT_TEST_ARIA_DIR=/data/custom-downloads sh "$script"
[ ! -s "$GWRT_TEST_UCI_LOG" ]
printf 'PASS aria2 defaults wait for a mounted data partition and preserve service/auth/custom-path settings\n'
