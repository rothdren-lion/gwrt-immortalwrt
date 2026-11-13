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

# Earlier GWRT overlays disabled the online feature updater. The copy above
# cannot remove a withdrawn patch from an existing feed checkout.
rm -f "$top/feeds/packages/net/open-app-filter/patches/101-disable-online-feature-updates.patch"

# python-dotenv selects the setuptools PEP 517 backend. Its Makefile does not
# declare python-setuptools/host, so a parallel world build can reach it before
# setuptools is staged and fail with "Cannot import 'setuptools.build_meta'".
dotenv_mk="$top/feeds/packages/lang/python/python-dotenv/Makefile"
if [ -f "$dotenv_mk" ] && ! grep -q '^PKG_BUILD_DEPENDS:=.*python-setuptools/host' "$dotenv_mk"; then
	sed -i '/^PKG_HASH:=/a PKG_BUILD_DEPENDS:=python-setuptools/host' "$dotenv_mk"
fi

echo "GWRT feed overlays applied"
