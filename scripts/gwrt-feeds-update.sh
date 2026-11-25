#!/bin/sh
# gwrt-feeds-update.sh [feeds.conf] [mirrors.conf]
#
# 1. Picks the first reachable GitHub mirror from configs/gwrt-git-mirrors.conf
#    (probed with `git ls-remote` before any feed download starts).
# 2. Rewrites every https://github.com/... src-git URL in feeds.conf to that
#    mirror, keeping the ^<commit> pin untouched.
# 3. Runs `./scripts/feeds update -a`.
# 4. If the mirror fetch still fails, restores the upstream URLs and retries once.
#
# Must be run from the source tree top directory (CI does exactly that).
set -eu

CONF="${1:-feeds.conf}"
MIRRORS="${2:-configs/gwrt-git-mirrors.conf}"
TIMEOUT="${GWRT_MIRROR_TIMEOUT:-25}"
LOG="${GWRT_MIRROR_LOG:-feeds-mirror.txt}"

[ -f "$CONF" ] || { echo "ERROR: feeds file not found: $CONF" >&2; exit 1; }
[ -f "$MIRRORS" ] || { echo "ERROR: mirror list not found: $MIRRORS" >&2; exit 1; }

mirror_list() {
	sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$MIRRORS" |
		while IFS= read -r line; do
			case "$line" in
			'' | '#'*) continue ;;
			esac
			printf '%s\n' "$line"
		done
}

# First github path in feeds.conf, used as the probe target.
probe_path() {
	awk '
		/^[[:space:]]*(src-git|src-git-full)[[:space:]]/ {
			for (i = 3; i <= NF; i++) {
				f = $i
				sub(/\^[^^]*$/, "", f)
				if (f ~ /^https:\/\/github\.com\//) {
					sub(/^https:\/\/github\.com\//, "", f)
					print f
					exit
				}
			}
		}
	' "$CONF"
}

# expand_mirror <template> <path> -> usable URL
expand_mirror() {
	printf '%s' "$1" | sed "s|{path}|$2|g"
}

reachable() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$TIMEOUT" git ls-remote --heads "$1" >/dev/null 2>&1
	else
		git ls-remote --heads "$1" >/dev/null 2>&1
	fi
}

# rewrite <template> <in> <out>
rewrite() {
	awk -v tpl="$1" '
		/^[[:space:]]*(src-git|src-git-full)[[:space:]]/ {
			out = ""
			for (i = 1; i <= NF; i++) {
				f = $i
				pin = ""
				if (match(f, /\^[^^]*$/)) {
					pin = substr(f, RSTART)
					f = substr(f, 1, RSTART - 1)
				}
				if (f ~ /^https:\/\/github\.com\//) {
					p = f
					sub(/^https:\/\/github\.com\//, "", p)
					t = tpl
					gsub(/\{path\}/, p, t)
					f = t pin
				} else if (pin != "") {
					f = f pin
				}
				out = out (i > 1 ? " " : "") f
			}
			print out
			next
		}
		{ print }
	' "$2" >"$3"
}

cp "$CONF" "$CONF.upstream"
path="$(probe_path || true)"
chosen=""
chosen_url=""
elapsed=0

if [ -n "$path" ]; then
	echo "Probing GitHub mirrors for $path ..."
	for tpl in $(mirror_list); do
		url="$(expand_mirror "$tpl" "$path")"
		start=$(date +%s)
		if reachable "$url"; then
			elapsed=$(( $(date +%s) - start ))
			chosen="$tpl"
			chosen_url="$url"
			echo "  OK   ${elapsed}s  $url"
			break
		fi
		echo "  FAIL       $url"
	done
fi

if [ -z "$chosen" ]; then
	echo "WARNING: no mirror reachable, using upstream feeds.conf URLs" >&2
	: >"$LOG"
else
	rewrite "$chosen" "$CONF.upstream" "$CONF"
	echo "Feeds rewritten to $chosen (probe ${elapsed}s)" | tee "$LOG"
	printf 'mirror_template=%s\nmirror_probe_url=%s\nmirror_probe_seconds=%s\n' \
		"$chosen" "$chosen_url" "$elapsed" >>"$LOG"
fi

update_feeds() {
	./scripts/feeds update -a
}

if update_feeds; then
	echo "Feeds update succeeded." | tee -a "$LOG"
else
	echo "WARNING: feeds update failed with the mirror, retrying upstream URLs" >&2
	cp "$CONF.upstream" "$CONF"
	rm -rf feeds/*/
	if ! update_feeds; then
		echo "ERROR: feeds update failed with both mirror and upstream URLs" >&2
		exit 1
	fi
	echo "upstream_fallback=1" >>"$LOG"
fi

for feed in feeds/*; do
	[ -d "$feed/.git" ] || continue
	printf '%s %s\n' "$feed" "$(git -C "$feed" rev-parse HEAD)"
done >feeds-revisions.txt
cat "$LOG" 2>/dev/null || true
