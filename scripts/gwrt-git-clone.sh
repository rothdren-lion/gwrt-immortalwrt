#!/bin/sh
# gwrt-git-clone.sh <github-url> <dest> [git clone args...]
#
# Clones a GitHub repository through the first mirror that works
# (configs/gwrt-git-mirrors.conf), falling back to the upstream URL.
# Example:
#   sh scripts/gwrt-git-clone.sh https://github.com/daeuniverse/honk.git \
#       "$RUNNER_TEMP/honk-source" --depth 1 --branch v0.1.0-beta.6
set -eu

URL="${1:?usage: gwrt-git-clone.sh <github-url> <dest> [git clone args...]}"
DEST="${2:?usage: gwrt-git-clone.sh <github-url> <dest> [git clone args...]}"
shift 2
MIRRORS="${GWRT_GIT_MIRRORS:-configs/gwrt-git-mirrors.conf}"

case "$URL" in
https://github.com/*) path="${URL#https://github.com/}" ;;
*)
	git clone "$@" "$URL" "$DEST"
	exit 0
	;;
esac

mirror_list() {
	sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$MIRRORS" |
		while IFS= read -r line; do
			case "$line" in
			'' | '#'*) continue ;;
			esac
			printf '%s\n' "$line"
		done
}

if [ -f "$MIRRORS" ]; then
	candidates="$(mirror_list | sed "s|{path}|$path|g")"
else
	candidates="$URL"
fi

for candidate in $candidates; do
	rm -rf "$DEST"
	printf '==> git clone %s %s\n' "$candidate" "$*"
	if git clone "$@" "$candidate" "$DEST"; then
		echo "clone_source=$candidate" >&2
		exit 0
	fi
done

echo "ERROR: every mirror failed for $URL" >&2
exit 1
