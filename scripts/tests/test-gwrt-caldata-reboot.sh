#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script="$root/target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gwrt-caldata-reboot.XXXXXX")
cleanup() {
	rm -f "$tmp/.fs_state" "$tmp/gwrt-caldata-rebooted" "$tmp/events" "$tmp/log"
	rmdir "$tmp"
}
trap cleanup EXIT HUP INT TERM

OVERLAY_STATE="$tmp/.fs_state"
REBOOT_MARKER="$tmp/gwrt-caldata-rebooted"
EVENTS="$tmp/events"
LOG="$tmp/log"
. "$script"

OVERLAY_STATE="$tmp/.fs_state"
REBOOT_MARKER="$tmp/gwrt-caldata-rebooted"
REBOOT_WAIT_INTERVAL=1
REBOOT_WAIT_ATTEMPTS=3
waits=0
ready_after=2

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

sleep() {
	[ "$1" = "$REBOOT_WAIT_INTERVAL" ] || fail "unexpected wait interval: $1"
	waits=$((waits + 1))
	if [ "$ready_after" -gt 0 ] && [ "$waits" -ge "$ready_after" ]; then
		ln -s 2 "$OVERLAY_STATE"
	fi
}

sync() {
	[ -f "$REBOOT_MARKER" ] || fail "reboot guard must exist before sync"
	printf 'sync\n' >>"$EVENTS"
}

reboot() {
	[ -f "$REBOOT_MARKER" ] || fail "reboot guard must exist before reboot"
	printf 'reboot\n' >>"$EVENTS"
}

logger() {
	printf '%s\n' "$*" >>"$LOG"
}

: >"$EVENTS"
: >"$LOG"
reboot_after_caldata_extract || fail "ready overlay should permit one reboot"
[ -L "$REBOOT_MARKER" ] && fail "reboot marker must be a regular file"
[ -f "$REBOOT_MARKER" ] || fail "reboot marker must persist before reboot"
[ "$(cat "$EVENTS")" = "sync
reboot" ] || fail "sync must precede reboot"

rm -f "$OVERLAY_STATE" "$REBOOT_MARKER"
: >"$EVENTS"
: >"$LOG"
waits=0
ready_after=0
REBOOT_WAIT_ATTEMPTS=2
if reboot_after_caldata_extract; then
	fail "an unready overlay must suppress reboot"
fi
[ ! -e "$REBOOT_MARKER" ] || fail "timeout must not persist a reboot marker"
[ ! -s "$EVENTS" ] || fail "timeout must not sync or reboot"
grep -q 'overlay did not become READY' "$LOG" || fail "timeout should be logged"

printf 'PASS: calibration reboot waits for persistent overlay readiness and is bounded\n'
