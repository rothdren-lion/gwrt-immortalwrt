#!/bin/sh
set -eu

top=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
overlay="$top/gwrt-overlays/feeds"
[ -d "$overlay" ] || { echo "GWRT feed overlays missing: $overlay" >&2; exit 1; }

for package in packages/net/daed packages/net/aria2 packages/net/open-app-filter luci/applications/luci-app-daed luci/applications/luci-app-aria2; do
	[ -f "$top/feeds/$package/Makefile" ] || {
		echo "Feed package is missing: $package; run scripts/feeds update -a first" >&2
		exit 1
	}
done

cd "$overlay"
find . -type f | LC_ALL=C sort | while IFS= read -r file; do
	destination="$top/feeds/${file#./}"
	mkdir -p "$(dirname "$destination")"
	cp "$file" "$destination"
	case "$file" in
		*.init) chmod 755 "$destination" ;;
		*) chmod 644 "$destination" ;;
	esac
done
echo "GWRT feed overlays applied"
