#!/bin/sh
set -eu
init=${1:?usage: test-gwrt-aria2-mount.sh /path/to/aria2.init}

bash -s "$init" <<'SH'
set -eu
. "$1"
config_load() { :; }
procd_add_reload_trigger() { :; }
procd_add_validation() { :; }
config_foreach() { "$1" main; }
config_get_bool() { enabled=${test_enabled:-1}; }
config_get() { dir='/mnt/gwrt disk/downloads'; }
procd_add_restart_mount_trigger() { triggered=$1; }
triggered=
service_triggers
[ "$triggered" = '/mnt/gwrt disk/downloads' ] || {
	echo 'aria2 does not retry when its configured storage mount becomes available' >&2
	exit 1
}
test_enabled=0
triggered=
service_triggers
[ -z "$triggered" ] || {
	echo 'aria2 registered a mount restart for a disabled instance' >&2
	exit 1
}
echo 'ok: enabled aria2 follows the configured mount; disabled aria2 stays stopped'
SH
