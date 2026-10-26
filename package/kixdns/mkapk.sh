#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# mkapk.sh —— 为「非当前构建目标」的架构单独生成 kixdns 的 .apk
#
# 为什么需要它：
#   OpenWrt 一次只能面向一个 target 出包。本树默认是 qualcommax/ipq60xx
#   (aarch64_cortex-a53)，想再要 x86_64 的包就得切 .config 重建整个
#   x86 工具链。而 kixdns 是预编译静态二进制，两种架构之间只差一个
#   asset 文件，所以这里直接复用构建树的 apk 打包器，秒级出包。
#
# 用法：
#   ./mkapk.sh                 # 默认只生成 x86_64
#   ./mkapk.sh x86_64 aarch64_cortex-a53
#   ./mkapk.sh --no-index x86_64
#
# 产物：
#   bin/packages/<arch>/base/kixdns-<ver>-r<rel>.apk   （同目录 index 会重建）
#
# 与 package/kixdns/Makefile 必须保持一致：改一个要改两个。

set -eu

PKGDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOPDIR=$(CDPATH= cd -- "$PKGDIR/../.." && pwd)

NAME=kixdns
PKG_VERSION=0.2.0
PKG_RELEASE=1
PKGVER="${PKG_VERSION}-r${PKG_RELEASE}"
PKG_LICENSE=GPL-3.0-only
PKG_MAINTAINER=GWRT
PKG_URL=https://github.com/olicesx/kixdns
DOWNLOAD_BASE="https://github.com/olicesx/kixdns/releases/download/v${PKG_VERSION}"

DESCRIPTION='KixDNS is an asynchronous, non-recursive DNS forwarder written in Rust. It accepts DNS over UDP/TCP (optionally inbound DoH), applies an ordered pipeline of matchers/actions, then forwards to UDP/TCP/DoH/DoT/DoQ upstreams, with in-memory caching, GeoIP/GeoSite routing and hot config reload. This package installs the statically linked musl binary published on the upstream GitHub releases page; no Rust toolchain is required to build it.'

APK="$TOPDIR/staging_dir/host/bin/apk"
MKHASH="$TOPDIR/staging_dir/host/bin/mkhash"
FAKEROOT="$TOPDIR/staging_dir/host/bin/fakeroot"
SIGN_KEY="$TOPDIR/private-key.pem"
DL_DIR="$TOPDIR/dl"
OUT_ROOT="$TOPDIR/bin/packages"
WORK=$(mktemp -d)

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

CONFFILES="/etc/config/$NAME
/etc/kixdns/pipeline.json"

# 架构 -> "asset 文件名 sha256 期望的 ELF 描述串"
asset_spec() {
	case "$1" in
		aarch64_cortex-a53|aarch64_generic|aarch64*)
			echo "kixdns-linux-arm64-musl 37f1bba4d8c5ba9301530b3077aef50572ae3c9a50a7ed75dcf7e13aac484ad5 aarch64";;
		x86_64)
			echo "kixdns-linux-x86_64-musl e63817b446828a5715c011bc6ee5f741942445567c0c33ad6cf6bae8e9a9bcbf x86-64";;
		*)
			return 1;;
	esac
}

die() { echo "mkapk: $*" >&2; exit 1; }

need_tools() {
	[ -x "$APK" ]      || die "缺少 $APK，请先在构建树里跑过一次 make 以生成 host 工具"
	[ -x "$MKHASH" ]   || die "缺少 $MKHASH"
	[ -x "$FAKEROOT" ] || die "缺少 $FAKEROOT（apk 需要以 root:root 记录文件属主）"
	[ -f "$TOPDIR/scripts/make-index-json.py" ] || die "缺少 scripts/make-index-json.py"
	[ -f "$PKGDIR/files/kixdns.init" ] || die "缺少 $PKGDIR/files/"
}

# 下载（或复用已有的）asset 并校验哈希
fetch_asset() {
	file="$1"; want="$2"
	mkdir -p "$DL_DIR"
	if [ ! -f "$DL_DIR/$file" ]; then
		echo "mkapk: downloading $file"
		if ! curl -fL --connect-timeout 30 --retry 3 \
			-o "$DL_DIR/$file.tmp" "$DOWNLOAD_BASE/$file"; then
			rm -f "$DL_DIR/$file.tmp"
			die "下载失败 $DOWNLOAD_BASE/$file —— 可手动下载后放到 $DL_DIR/$file 再重跑"
		fi
		mv "$DL_DIR/$file.tmp" "$DL_DIR/$file"
	fi
	got=$(sha256sum "$DL_DIR/$file" | cut -d' ' -f1)
	[ "$got" = "$want" ] || die "$file 哈希不匹配：期望 $want，实际 $got"
}

build_one() {
	arch="$1"
	spec=$(asset_spec "$arch") || die "不支持的架构: $arch（可选: x86_64, aarch64_cortex-a53）"
	set -- $spec
	asset="$1"; want="$2"; expect_elf="$3"

	fetch_asset "$asset" "$want"

	idir="$WORK/$arch.idir"
	adir="$WORK/$arch.adir"
	chk="$WORK/$arch.chk"
	rm -rf "$idir" "$adir" "$chk"
	mkdir -p "$idir" "$adir" "$chk"

	echo "mkapk: assembling $arch"

	# --- 数据文件 ---
	install -d -m0755 "$idir/usr/bin" \
	                  "$idir/etc/init.d" \
	                  "$idir/etc/config" \
	                  "$idir/etc/kixdns" \
	                  "$idir/lib/apk/packages"
	install -m0755 "$DL_DIR/$asset"              "$idir/usr/bin/$NAME"
	install -m0755 "$PKGDIR/files/kixdns.init"   "$idir/etc/init.d/$NAME"
	install -m0600 "$PKGDIR/files/kixdns.config" "$idir/etc/config/$NAME"
	install -m0644 "$PKGDIR/files/pipeline.json" "$idir/etc/kixdns/pipeline.json"

	# .list 必须先在 idir 之外生成再挪进去，否则会把 .list 自己写进去
	# （与 include/package-pack.mk 的做法一致）
	(cd "$idir" && find . -type f,l -printf "/%P\n" | sort) > "$WORK/$arch.list"
	mv "$WORK/$arch.list" "$idir/lib/apk/packages/$NAME.list"

	# .conffiles / .conffiles_static
	printf '%s\n' "$CONFFILES" | sed '/^$/d' > "$idir/lib/apk/packages/$NAME.conffiles"
	: > "$idir/lib/apk/packages/$NAME.conffiles_static"
	while IFS= read -r f; do
		[ -f "$idir$f" ] || continue
		echo "$f $($MKHASH sha256 "$idir$f")" >> "$idir/lib/apk/packages/$NAME.conffiles_static"
	done < "$idir/lib/apk/packages/$NAME.conffiles"

	# --- 维护脚本：内容照抄构建树为本包生成的三段 ---
	cat > "$adir/post-install" <<EOF
#!/bin/sh
[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. \${IPKG_INSTROOT}/lib/functions.sh
export root="\${IPKG_INSTROOT}"
export pkgname="$NAME"
add_group_and_user
default_postinst
EOF
	cat > "$adir/post-upgrade" <<EOF
#!/bin/sh
export PKG_UPGRADE=1
[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. \${IPKG_INSTROOT}/lib/functions.sh
export root="\${IPKG_INSTROOT}"
export pkgname="$NAME"
add_group_and_user
default_postinst
EOF
	cat > "$adir/pre-deinstall" <<EOF
#!/bin/sh
[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. \${IPKG_INSTROOT}/lib/functions.sh
export root="\${IPKG_INSTROOT}"
export pkgname="$NAME"
default_prerm
EOF
	chmod 0755 "$adir"/*

	# --- 打包 ---
	outdir="$OUT_ROOT/$arch/base"
	out="$outdir/$NAME-$PKGVER.apk"
	mkdir -p "$outdir"

	SIGN_ARGS=""
	if [ -f "$SIGN_KEY" ]; then SIGN_ARGS="--sign $SIGN_KEY"; fi

	SOURCE_DATE_EPOCH=0 "$FAKEROOT" "$APK" mkpkg \
		--info "name:$NAME" \
		--info "version:$PKGVER" \
		--info "tags:openwrt:section=net" \
		--info "description:$DESCRIPTION" \
		--info "arch:$arch" \
		--info "license:$PKG_LICENSE" \
		--info "origin:feeds/base/$NAME" \
		--info "url:$PKG_URL" \
		--info "maintainer:$PKG_MAINTAINER" \
		--info "provides:$NAME-any" \
		--info "depends:libc" \
		--script "post-install:$adir/post-install" \
		--script "post-upgrade:$adir/post-upgrade" \
		--script "pre-deinstall:$adir/pre-deinstall" \
		--files "$idir" \
		$SIGN_ARGS \
		--output "$out"

	# --- 自检：解出来看架构 / 配置 / 脚本齐不齐 ---
	( cd "$chk" && "$APK" extract --allow-untrusted "$out" >/dev/null )
	[ -f "$chk/usr/bin/$NAME" ] || die "$out 里没有 usr/bin/$NAME"
	file "$chk/usr/bin/$NAME" | grep -q "$expect_elf" \
		|| die "$out 内的二进制架构不对: $(file "$chk/usr/bin/$NAME")"
	[ -f "$chk/etc/init.d/$NAME" ] || die "$out 缺少 init 脚本"
	[ -f "$chk/lib/apk/packages/$NAME.list" ] || die "$out 缺少 .list"
	[ -s "$chk/lib/apk/packages/$NAME.conffiles_static" ] || die "$out 缺少 .conffiles_static"

	echo "mkapk: OK  $out"
	echo "        $(file "$chk/usr/bin/$NAME")"
	echo "        size=$(stat -c%s "$out") sha256=$(sha256sum "$out" | cut -d' ' -f1)"

	if [ "$MAKE_INDEX" = 1 ]; then
		( cd "$outdir" && ls *.apk >/dev/null 2>&1 && \
			"$APK" mkndx --root "$TOPDIR" --keys-dir "$TOPDIR" --allow-untrusted \
				$SIGN_ARGS --output packages.adb *.apk && \
			"$APK" adbdump --format json packages.adb | \
				"$TOPDIR/scripts/make-index-json.py" -f apk -a "$arch" - > index.json ) \
			|| die "重建 $outdir 索引失败"
		echo "mkapk: index -> $outdir/packages.adb"
	fi
}

MAKE_INDEX=1
ARCHS=""
for arg in "$@"; do
	case "$arg" in
		--no-index) MAKE_INDEX=0;;
		-h|--help)   sed -n '2,24p' "$0"; exit 0;;
		-*)          die "未知选项: $arg";;
		*)           ARCHS="$ARCHS $arg";;
	esac
done
[ -n "$ARCHS" ] || ARCHS="x86_64"

need_tools
for a in $ARCHS; do
	build_one "$a"
done
