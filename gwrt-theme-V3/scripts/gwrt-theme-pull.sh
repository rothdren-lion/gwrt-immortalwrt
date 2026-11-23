#!/bin/sh
# gwrt-theme-pull.sh — 从另一棵 ImmortalWrt 源码树「按需」拉取主题改动
#
# AN7581 系列主题是独立线（见 SERIES / README）。MT7981 树的主题不能整目录
# 覆盖过来，否则会丢掉 PPE / 动态 WAN / PON / 固件版本。这里只做对比和
# 单文件搬运，由人决定拉哪些。
#
# 用法:
#   ./scripts/gwrt-theme-pull.sh --from /path/to/other/tree            # 列出差异
#   ./scripts/gwrt-theme-pull.sh --from DIR --diff <相对路径>          # 看单个文件差异
#   ./scripts/gwrt-theme-pull.sh --from DIR --apply <相对路径> [...]   # 拉取指定文件
#
# 说明:
#   - 相对路径相对于 theme/luci-theme-gwrt
#   - VERSION / SERIES 永远不覆盖（AN7581 自己维护）
#   - --apply 之后请运行 ./scripts/integrate.sh 重新生成 package 副本
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
OURS="$PROJECT_DIR/theme/luci-theme-gwrt"

FROM=""
MODE=list
APPLY_LIST=""

usage() {
	cat <<'EOF'
Usage: gwrt-theme-pull.sh --from DIR [--list | --diff PATH | --apply PATH...]

  --from DIR    另一棵源码树（含 gwrt-theme-V3 或 package/gwrt-theme）
  --list        只列出差异（默认）
  --diff PATH   显示单个文件的 unified diff
  --apply PATH  从对方复制这些文件到本树规范源（可多个）
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--from) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; FROM="$2"; shift 2 ;;
		--list) MODE=list; shift ;;
		--diff) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MODE=diff; APPLY_LIST="$2"; shift 2 ;;
		--apply) MODE=apply; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) usage >&2; exit 2 ;;
		*) APPLY_LIST="$APPLY_LIST $1"; shift ;;
	esac
done

[ -n "$FROM" ] || { usage >&2; exit 2; }
[ -d "$OURS" ] || { echo "错误: 找不到本树规范源 $OURS" >&2; exit 1; }

if [ -d "$FROM/gwrt-theme-V3/theme/luci-theme-gwrt" ]; then
	OTHER="$FROM/gwrt-theme-V3/theme/luci-theme-gwrt"
elif [ -d "$FROM/package/gwrt-theme/luci-theme-gwrt/root" ]; then
	OTHER="$FROM/package/gwrt-theme/luci-theme-gwrt"
elif [ -d "$FROM/theme/luci-theme-gwrt" ]; then
	OTHER="$FROM/theme/luci-theme-gwrt"
else
	echo "错误: $FROM 里找不到 luci-theme-gwrt 主题源" >&2
	exit 1
fi

OTHER_VER="$(cat "$(dirname "$OTHER")/../VERSION" 2>/dev/null || echo '?')"
OUR_VER="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo '?')"
echo "本树(AN7581) : $OURS  [$OUR_VER]"
echo "对比源       : $OTHER  [$OTHER_VER]"
echo

protected() {
	case "$1" in
		VERSION|SERIES) return 0 ;;
		*) return 1 ;;
	esac
}

file_list() {
	( cd "$1" && find . -type f ! -path './.git/*' | sed 's|^\./||' | sort )
}

case "$MODE" in
list)
	tmp_o="$(mktemp)"; tmp_t="$(mktemp)"
	trap 'rm -f "$tmp_o" "$tmp_t"' EXIT
	file_list "$OURS" > "$tmp_o"
	file_list "$OTHER" > "$tmp_t"

	echo "== 对方有、本树没有（可能是新功能）=="
	comm -13 "$tmp_o" "$tmp_t" | sed 's/^/  + /' || true
	echo
	echo "== 两边都有但内容不同 =="
	comm -12 "$tmp_o" "$tmp_t" | while IFS= read -r f; do
		cmp -s "$OURS/$f" "$OTHER/$f" || {
			if protected "$f"; then
				printf '  %-58s (本树保留)\n' "$f"
			else
				printf '  %-58s %s\n' "$f" "$(wc -c < "$OTHER/$f" | tr -d ' ')B"
			fi
		}
	done
	echo
	echo "== 本树独有（AN7581 专属，别被覆盖）=="
	comm -23 "$tmp_o" "$tmp_t" | sed 's/^/  ! /' || true
	echo
	echo "拉取单个文件: $0 --from $FROM --apply <路径>"
	;;
diff)
	[ -n "$APPLY_LIST" ] || { echo "缺少文件路径" >&2; exit 2; }
	for f in $APPLY_LIST; do
		if [ ! -f "$OTHER/$f" ]; then echo "对方没有: $f" >&2; continue; fi
		if [ ! -f "$OURS/$f" ]; then echo "(本树没有 $f，整文件为新增)"; fi
		diff -u "$OURS/$f" "$OTHER/$f" || true
	done
	;;
apply)
	[ -n "$APPLY_LIST" ] || { echo "缺少文件路径" >&2; exit 2; }
	for f in $APPLY_LIST; do
		if protected "$f"; then echo "跳过受保护文件: $f"; continue; fi
		if [ ! -f "$OTHER/$f" ]; then echo "对方没有: $f" >&2; continue; fi
		mkdir -p "$OURS/$(dirname "$f")"
		cp -f "$OTHER/$f" "$OURS/$f"
		echo "  pulled $f"
	done
	echo
	echo "下一步: cd $PROJECT_DIR && ./scripts/integrate.sh --no-defconfig"
	;;
esac
