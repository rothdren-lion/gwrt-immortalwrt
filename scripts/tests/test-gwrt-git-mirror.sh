#!/bin/sh
# Offline regression for scripts/gwrt-feeds-update.sh and scripts/gwrt-git-clone.sh.
# Uses a fake `git` and a fake `scripts/feeds` so no network is needed.
set -eu

HERE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- fake git -------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<'EOF'
#!/bin/sh
url=""
for arg in "$@"; do
	case "$arg" in
	http*) url="$arg" ;;
	esac
done
[ -n "${FAKE_GIT_CALLS:-}" ] && [ -n "$url" ] && printf '%s %s\n' "$1" "$url" >>"$FAKE_GIT_CALLS"
case "$1" in
ls-remote)
	[ -n "$url" ] || exit 1
	grep -qxF "$url" "$FAKE_GIT_OK" 2>/dev/null || exit 1
	exit 0
	;;
clone)
	[ -n "$url" ] || exit 1
	grep -qxF "$url" "$FAKE_GIT_OK" 2>/dev/null || exit 1
	# last argument is the destination
	for arg in "$@"; do dest="$arg"; done
	mkdir -p "$dest/.git"
	exit 0
	;;
rev-parse)
	echo "0123456789abcdef0123456789abcdef01234567"
	exit 0
	;;
esac
exit 0
EOF
chmod +x "$WORK/bin/git"

# --- fake tree ------------------------------------------------------------
mkdir -p "$WORK/tree/scripts" "$WORK/tree/configs" "$WORK/tree/feeds"
cat >"$WORK/tree/scripts/feeds" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_FEEDS_LOG"
if [ -f "$FAKE_FEEDS_FAIL" ]; then
	rm -f "$FAKE_FEEDS_FAIL"
	exit 1
fi
exit 0
EOF
chmod +x "$WORK/tree/scripts/feeds"
cp "$HERE/scripts/gwrt-feeds-update.sh" "$HERE/scripts/gwrt-git-clone.sh" "$WORK/tree/scripts/"
cp "$HERE/configs/gwrt-git-mirrors.conf" "$WORK/tree/configs/"

cat >"$WORK/tree/feeds.conf" <<'EOF'
# test feeds
src-git packages https://github.com/immortalwrt/packages.git^decf94639ffd6ddd26591c190b547c6b7eea150b
src-git luci https://github.com/immortalwrt/luci.git^ad75cde88e694b511100576bfbe0a280e5efe6ef
src-git local /srv/local-feed
EOF
cp "$WORK/tree/feeds.conf" "$WORK/feeds.conf.orig"

export PATH="$WORK/bin:$PATH"
export FAKE_GIT_OK="$WORK/ok.txt"
export FAKE_FEEDS_LOG="$WORK/feeds.log"
export FAKE_FEEDS_FAIL="$WORK/fail.flag"
export FAKE_GIT_CALLS="$WORK/git.log"
: >"$FAKE_GIT_CALLS"

# --- case 1: first mirror (ghfast) down, second (gh-proxy) up -------------
cat >"$FAKE_GIT_OK" <<'EOF'
https://gh-proxy.com/https://github.com/immortalwrt/packages.git
EOF
cd "$WORK/tree"
sh scripts/gwrt-feeds-update.sh feeds.conf >"$WORK/out1.txt" 2>&1 || fail "case1: update script exited non-zero"
grep -q 'mirror_template=https://gh-proxy.com/https://github.com/{path}' feeds-mirror.txt ||
	fail "case1: wrong mirror recorded"
grep -qxF 'src-git packages https://gh-proxy.com/https://github.com/immortalwrt/packages.git^decf94639ffd6ddd26591c190b547c6b7eea150b' feeds.conf ||
	fail "case1: packages line not rewritten with pin"
grep -qxF 'src-git luci https://gh-proxy.com/https://github.com/immortalwrt/luci.git^ad75cde88e694b511100576bfbe0a280e5efe6ef' feeds.conf ||
	fail "case1: luci line not rewritten"
grep -qxF 'src-git local /srv/local-feed' feeds.conf || fail "case1: non-github line altered"
grep -q '^#' feeds.conf || fail "case1: comment dropped"
cmp -s "$WORK/feeds.conf.orig" feeds.conf.upstream || fail "case1: upstream backup mutated"
grep -q 'update -a' "$FAKE_FEEDS_LOG" || fail "case1: scripts/feeds not invoked"

# --- case 2: no mirror reachable -> upstream kept -------------------------
: >"$FAKE_GIT_OK"
cp "$WORK/feeds.conf.orig" feeds.conf
sh scripts/gwrt-feeds-update.sh feeds.conf >"$WORK/out2.txt" 2>&1 || fail "case2: exited non-zero"
cmp -s "$WORK/feeds.conf.orig" feeds.conf || fail "case2: feeds.conf rewritten without a mirror"
grep -q 'no mirror reachable' "$WORK/out2.txt" || fail "case2: missing warning"

# --- case 3: mirror fetch fails -> upstream retry, fallback logged --------
cat >"$FAKE_GIT_OK" <<'EOF'
https://gh-proxy.com/https://github.com/immortalwrt/packages.git
EOF
cp "$WORK/feeds.conf.orig" feeds.conf
touch "$FAKE_FEEDS_FAIL"
: >"$FAKE_FEEDS_LOG"
sh scripts/gwrt-feeds-update.sh feeds.conf >"$WORK/out3.txt" 2>&1 || fail "case3: fallback path exited non-zero"
cmp -s "$WORK/feeds.conf.orig" feeds.conf || fail "case3: upstream URLs not restored"
grep -q 'upstream_fallback=1' feeds-mirror.txt || fail "case3: fallback not logged"
[ "$(grep -c 'update -a' "$FAKE_FEEDS_LOG")" = "2" ] || fail "case3: expected two feeds update attempts"

# --- case 4: git-clone helper skips dead mirrors --------------------------
cat >"$FAKE_GIT_OK" <<'EOF'
https://ghfast.top/https://github.com/daeuniverse/honk.git
EOF
cd "$WORK/tree"
sh scripts/gwrt-git-clone.sh https://github.com/daeuniverse/honk.git "$WORK/honk" \
	--depth 1 --branch v0.1.0-beta.6 >"$WORK/out4.txt" 2>&1 || fail "case4: clone helper failed"
[ -d "$WORK/honk/.git" ] || fail "case4: destination not created"
grep -q 'clone_source=https://ghfast.top/https://github.com/daeuniverse/honk.git' "$WORK/out4.txt" ||
	fail "case4: wrong clone source reported"

# --- case 5: non-github URL cloned directly -------------------------------
if sh scripts/gwrt-git-clone.sh https://example.invalid/repo.git "$WORK/other" >"$WORK/out5.txt" 2>&1; then
	fail "case5: unreachable direct clone should have failed"
fi
grep -q 'clone https://example.invalid/repo.git' "$FAKE_GIT_CALLS" ||
	fail "case5: direct URL not attempted"
[ ! -d "$WORK/other/.git" ] || fail "case5: destination should not exist"

echo "PASS: gwrt git mirror helpers (5 cases)"
