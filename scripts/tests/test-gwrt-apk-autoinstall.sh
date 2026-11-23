#!/bin/bash
set -euo pipefail

helper="${1:?usage: test-apk-autoinstall.sh /path/to/gwrt-apk-autoinstall}"
[ -x "$helper" ] || {
	printf 'APK recovery helper is not executable: %s\n' "$helper" >&2
	exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$mock_bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$mock_bin/reload_config" <<'EOF'
#!/bin/sh
printf 'reload_config\n' >> "$GWRT_APK_TEST_ROOT/calls"
exit 0
EOF

cat > "$mock_bin/ubus" <<'EOF'
#!/bin/sh
printf 'ubus %s\n' "$*" >> "$GWRT_APK_TEST_ROOT/calls"
exit 0
EOF

cat > "$mock_bin/wifi" <<'EOF'
#!/bin/sh
printf 'wifi %s\n' "$*" >> "$GWRT_APK_TEST_ROOT/calls"
exit 0
EOF

cat > "$mock_bin/reboot" <<'EOF'
#!/bin/sh
printf 'reboot-called\n' >> "$GWRT_APK_TEST_ROOT/calls"
touch "$GWRT_APK_TEST_ROOT/reboot-called"
exit 99
EOF

cat > "$mock_bin/uci" <<'EOF'
#!/bin/sh
set -u
while [ "${1:-}" = -q ]; do shift; done
op="${1:-}"
[ "$#" -eq 0 ] || shift
case "$op" in
	get)
		key="${1:-}"
		awk -F= -v key="$key" '$1 == key { value=substr($0, index($0, "=") + 1) } END { if (value != "") print value; else exit 1 }' \
			"$GWRT_APK_TEST_ROOT/uci.db" 2>/dev/null
		;;
	set)
		printf '%s\n' "${1:-}" >> "$GWRT_APK_TEST_ROOT/uci.db"
		printf 'uci set %s\n' "${1:-}" >> "$GWRT_APK_TEST_ROOT/calls"
		;;
	commit)
		printf 'uci commit %s\n' "${1:-}" >> "$GWRT_APK_TEST_ROOT/calls"
		;;
	show)
		if [ "${1:-}" = wireless ]; then
			printf 'wireless.default_radio0=wifi-iface\n'
			exit 0
		fi
		exit 0
		;;
	*) exit 1 ;;
esac
EOF

cat > "$mock_bin/apk" <<'EOF'
#!/bin/sh
set -u
args=" $* "
case "$args" in
	*' adbdump '*)
		printf 'name: demo\nversion: 1.0-r1\n'
		exit 0
		;;
	*' verify '*) exit 0 ;;
	*' query '*)
		[ -f "$GWRT_APK_TEST_ROOT/installed" ] || exit 1
		printf 'Version: 1.0-r1\n'
		exit 0
		;;
	*' version -t '*) printf '=\n'; exit 0 ;;
	*' info --exists --installed '*) [ -f "$GWRT_APK_TEST_ROOT/installed" ]; exit $? ;;
	*' --simulate '*)
		case "$args:$GWRT_APK_TEST_OFFLINE" in
			*' --no-network '*:fail) exit 1 ;;
		esac
		exit 0
		;;
	*' update '*)
		printf 'apk update\n' >> "$GWRT_APK_TEST_ROOT/calls"
		touch "$GWRT_APK_TEST_ROOT/updated"
		exit 0
		;;
	*' add '*)
		printf 'apk add\n' >> "$GWRT_APK_TEST_ROOT/calls"
		touch "$GWRT_APK_TEST_ROOT/installed"
		exit 0
		;;
esac
exit 1
EOF

cat > "$test_root/init-script" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$GWRT_APK_TEST_ROOT/calls"
exit 0
EOF

chmod 0755 "$mock_bin"/* "$test_root/init-script"

run_helper() {
	local scenario="$1"
	shift
	mkdir -p "$scenario/state" "$scenario/lock-parent" "$scenario/tmp" "$scenario/www" "$scenario/mnt/APK"
	[ -e "$scenario/calls" ] || : > "$scenario/calls"
	[ -e "$scenario/uci.db" ] || : > "$scenario/uci.db"
	printf "%s\n" \
		"DISTRIB_RELEASE='test'" \
		"DISTRIB_REVISION='test-r1'" \
		"DISTRIB_TARGET='qualcommax/ipq60xx'" > "$scenario/openwrt_release"
	env \
		PATH="$mock_bin:/usr/bin:/bin" \
		GWRT_APK_TEST_ROOT="$scenario" \
		GWRT_APK_TEST_OFFLINE="${GWRT_APK_TEST_OFFLINE:-pass}" \
		GWRT_APK_MOUNT="$scenario/mnt" \
		GWRT_APK_STATE_DIR="$scenario/state" \
		GWRT_APK_LOCK_DIR="$scenario/lock-parent/lock" \
		GWRT_APK_TMP_DIR="$scenario/tmp" \
		GWRT_APK_WWW_DIR="$scenario/www" \
		GWRT_APK_MOUNT_WAIT=0 \
		GWRT_APK_RELEASE_FILE="$scenario/openwrt_release" \
		GWRT_APK_INIT_SCRIPT="$test_root/init-script" \
		"$helper" "$@"
}

if grep -Eq '(^|[;&|[:space:]])(/sbin/)?reboot([;&|[:space:]]|$)' "$helper"; then
	printf 'APK recovery helper contains an executable reboot command\n' >&2
	exit 1
fi

config_case="$test_root/config-case"
mkdir -p "$config_case/mnt/APK"
sentinel="$config_case/config-was-executed"
printf '%s\n' \
	'lan_ip=192.168.77.1' \
	'wan_proto=dhcp' \
	"unsupported_key=\$(touch $sentinel)" > "$config_case/mnt/APK/ax6600.conf"
run_helper "$config_case"

[ -f "$config_case/state/apk-autoinstall.once" ]
grep -qx 'status=done' "$config_case/state/apk-autoinstall.once"
grep -qx 'reboot=disabled' "$config_case/state/apk-autoinstall.status"
grep -qx 'activation=reloaded' "$config_case/state/apk-autoinstall.status"
grep -qx 'init disable' "$config_case/calls"
[ ! -e "$sentinel" ]
first_calls="$(sed '/^init disable$/d' "$config_case/calls" | sha256sum | awk '{print $1}')"
run_helper "$config_case"
second_calls="$(sed '/^init disable$/d' "$config_case/calls" | sha256sum | awk '{print $1}')"
[ "$first_calls" = "$second_calls" ]

run_helper "$config_case" --force
grep -qx 'mode=manual-force' "$config_case/state/apk-autoinstall.once"
[ "$(grep -c '^init disable$' "$config_case/calls")" -eq 2 ]
[ ! -e "$sentinel" ]
[ ! -e "$config_case/reboot-called" ]

failed_case="$test_root/failed-case"
mkdir -p "$failed_case/mnt/APK"
printf 'this is not a key value line\n' > "$failed_case/mnt/APK/ax6600.conf"
run_helper "$failed_case"
grep -qx 'status=failed' "$failed_case/state/apk-autoinstall.once"
failed_once="$(sha256sum "$failed_case/state/apk-autoinstall.once" | awk '{print $1}')"
printf 'lan_ip=192.168.88.1\n' > "$failed_case/mnt/APK/ax6600.conf"
run_helper "$failed_case"
failed_twice="$(sha256sum "$failed_case/state/apk-autoinstall.once" | awk '{print $1}')"
[ "$failed_once" = "$failed_twice" ]
run_helper "$failed_case" --force
grep -qx 'status=done' "$failed_case/state/apk-autoinstall.once"
grep -qx 'mode=manual-force' "$failed_case/state/apk-autoinstall.once"

offline_case="$test_root/offline-case"
mkdir -p "$offline_case/mnt/APK"
printf 'apk payload\n' > "$offline_case/mnt/APK/demo.apk"
GWRT_APK_TEST_OFFLINE=pass run_helper "$offline_case"
grep -qx 'dependency_check=pass-offline' "$offline_case/state/apk-autoinstall.status"
grep -qx 'apk_installed=1' "$offline_case/state/apk-autoinstall.status"
[ ! -e "$offline_case/updated" ]

online_case="$test_root/online-case"
mkdir -p "$online_case/mnt/APK"
printf 'apk payload\n' > "$online_case/mnt/APK/demo.apk"
GWRT_APK_TEST_OFFLINE=fail run_helper "$online_case"
grep -qx 'dependency_check=pass-online' "$online_case/state/apk-autoinstall.status"
grep -qx 'apk_installed=1' "$online_case/state/apk-autoinstall.status"
[ -e "$online_case/updated" ]

if find "$test_root" -name reboot-called -print -quit | grep -q .; then
	printf 'APK recovery invoked reboot during an isolated scenario\n' >&2
	exit 1
fi

printf 'APK first-boot recovery tests passed\n'
