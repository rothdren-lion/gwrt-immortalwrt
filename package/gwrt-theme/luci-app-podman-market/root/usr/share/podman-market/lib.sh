# podman-market shared shell library (POSIX sh)
# Sourced by /usr/libexec/rpcd/podmanmarket and by background deploy jobs.

CATALOG="/usr/share/podman-market/catalog.json"
RUNDIR="/tmp/podman-market"
DATAROOT_DEFAULT="/opt/podman-market"

json_get() { # json_get <file> <expr>
	jsonfilter -q -i "$1" -e "$2" 2>/dev/null
}

have_podman() {
	command -v podman >/dev/null 2>&1
}

podman_version() {
	have_podman || return 1
	local version
	version=$(podman --version 2>/dev/null | awk '{print $NF}')
	[ -n "$version" ] || return 1
	printf '%s\n' "$version"
}

sanitize() {
	printf '%s' "$1" | tr -cd 'A-Za-z0-9._:/=-'
}

valid_id() {
	local id="$1" idx
	case "$id" in *[!a-z0-9-]*|"") return 1 ;; esac
	idx=$(catalog_index "$id") && [ -n "$idx" ]
}

# find catalog array index (0-based) of app id by walking the id list
catalog_index() {
	local want="$1" idx=0 x
	for x in $(json_get "$CATALOG" '$[*].id'); do
		if [ "$x" = "$want" ]; then
			echo "$idx"
			return 0
		fi
		idx=$((idx + 1))
	done
	return 1
}

app_meta() { # app_meta <id> <key>
	local idx
	idx=$(catalog_index "$1") || return 1
	json_get "$CATALOG" "\$[$idx].$2"
}

# number of elements in an app's array field
arr_len() { # arr_len <id> <key>
	local idx
	idx=$(catalog_index "$1") || { echo 0; return; }
	json_get "$CATALOG" "\$[$idx].$2[*]" | wc -l
}

arr_item() { # arr_item <id> <key> <i> [subkey]
	local idx sub="${4:-}"
	idx=$(catalog_index "$1") || return 1
	json_get "$CATALOG" "\$[$idx].$2[$3]$sub"
}

container_exists() {
	podman ps -qa --filter "name=^$1\$" 2>/dev/null | grep -q .
}

job_running() {
	local pid
	pid=$(cat "$RUNDIR/$1.pid" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

job_state() {
	local ex="$RUNDIR/$1.exit"
	if job_running "$1"; then echo running; return; fi
	if [ -f "$ex" ]; then
		[ "$(cat "$ex")" = "0" ] && { echo done; return; }
		echo failed; return
	fi
	echo idle
}

start_job() { # start_job <id> <command...>
	local id="$1"; shift
	mkdir -p "$RUNDIR"
	: > "$RUNDIR/$id.log"
	rm -f "$RUNDIR/$id.exit"
	(
		"$@" >> "$RUNDIR/$id.log" 2>&1
		echo $? > "$RUNDIR/$id.exit"
	) &
	echo $! > "$RUNDIR/$id.pid"
}

do_deploy() { # do_deploy <id> <primary-port|''> <data-root|''> <autostart 0|1>
	local id="$1" port="$2" dataroot="$3" autostart="${4:-1}"
	local image name vol spec dst DATA i n first_done rc
	local h c pr v envline extra pre

	image=$(app_meta "$id" image) || { echo "unknown app id: $id"; return 1; }

	DATA=$(sanitize "${dataroot:-$DATAROOT_DEFAULT/$id}")
	case "$DATA" in /*) ;; *) DATA="$DATAROOT_DEFAULT/$id" ;; esac
	port=$(sanitize "$port")
	name="$id"

	mkdir -p "$DATA"

	# per-app preparation hooks
	n=$(arr_len "$id" pre)
	i=0
	while [ "$i" -lt "$n" ]; do
		pre=$(arr_item "$id" pre "$i")
		[ -n "$pre" ] && DATA="$DATA" sh -c "$pre"
		i=$((i + 1))
	done

	podman rm -f "$name" >/dev/null 2>&1

	set -- run -d --name "$name" --restart on-failure:5 --label podman-market="$id"

	# port mappings; the first host side can be overridden
	n=$(arr_len "$id" ports)
	i=0
	first_done=0
	while [ "$i" -lt "$n" ]; do
		h=$(arr_item "$id" ports "$i" ".h")
		c=$(arr_item "$id" ports "$i" ".c")
		pr=$(arr_item "$id" ports "$i" ".proto")
		if [ "$first_done" = "0" ] && [ -n "$port" ]; then h="$port"; fi
		first_done=1
		[ -n "$h" ] && set -- "$@" -p "$h:$c/$pr"
		i=$((i + 1))
	done

	# volumes relative to data root
	n=$(arr_len "$id" volumes)
	i=0
	while [ "$i" -lt "$n" ]; do
		vol=$(arr_item "$id" volumes "$i")
		spec=${vol%%:*}
		dst=${vol#*:}
		mkdir -p "$DATA/$spec"
		set -- "$@" -v "$DATA/$spec:$dst"
		i=$((i + 1))
	done

	# environment variables
	n=$(arr_len "$id" env)
	i=0
	while [ "$i" -lt "$n" ]; do
		envline=$(arr_item "$id" env "$i")
		[ -n "$envline" ] && set -- "$@" -e "$envline"
		i=$((i + 1))
	done

	# static run flags (--network host, --privileged ...)
	n=$(arr_len "$id" extra)
	i=0
	while [ "$i" -lt "$n" ]; do
		extra=$(arr_item "$id" extra "$i")
		[ -n "$extra" ] && set -- "$@" "$extra"
		i=$((i + 1))
	done

	set -- "$@" "$image"

	# image-embedded command words (redis-server args, minio server ...)
	n=$(arr_len "$id" cmd)
	i=0
	while [ "$i" -lt "$n" ]; do
		extra=$(arr_item "$id" cmd "$i")
		[ -n "$extra" ] && set -- "$@" "$extra"
		i=$((i + 1))
	done

	echo "__PULL_START__ $(date +%s)"
	echo "+ podman pull $image"
	podman pull "$image" || return 1
	echo "__PULL_DONE__ $(date +%s)"
	echo "+ podman $*"
	podman "$@"
	rc=$?
	echo "__RUN_DONE__ rc=$rc date=$(date +%s)"
	[ "$rc" -eq 0 ] || return "$rc"

	uci -q delete "podman-market.$id"
	uci set "podman-market.$id=app"
	uci set "podman-market.$id.port=$port"
	uci set "podman-market.$id.data=$DATA"
	uci set "podman-market.$id.autostart=$autostart"
	uci commit podman-market
	echo "deployed $name"
	return 0
}

redeploy_stored() {
	local id="$1" port data autostart
	port=$(uci -q get "podman-market.$id.port")
	data=$(uci -q get "podman-market.$id.data")
	autostart=$(uci -q get "podman-market.$id.autostart")
	do_deploy "$id" "$port" "$data" "$autostart"
}
