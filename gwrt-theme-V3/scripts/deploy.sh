#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TREE="$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)"

HOST="${GWRT_ROUTER_HOST:-192.168.1.1}"
USER="${GWRT_ROUTER_USER:-root}"
REMOTE_DIR="${GWRT_REMOTE_DIR:-/tmp}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
SCP_OPTS="-O"
IMAGE=""
BL2=""
FIP=""
FLASH=0
BOOT=0
ASSUME_YES=0
KEEP_REMOTE=0
TARGET="airoha"
SUBTARGET="an7581"

usage() {
	cat <<'EOF'
Usage: deploy.sh [options]

Upload a built ImmortalWrt image to the router with scp.  The image is
verified with sha256 before it is optionally written with sysupgrade.

Options:
  --image FILE       sysupgrade image (default: newest in bin/targets)
  --host ADDRESS     router address (default: 192.168.1.1)
  --user USER        ssh user (default: root)
  --remote-dir DIR   remote staging directory (default: /tmp)
  --flash            run "sysupgrade -v" after a successful upload
  --bl2 FILE         upload a preloader.bin (BL2 FIP) for a later boot flash
  --fip FILE         upload a bl31-uboot.fip for a later boot flash
  --boot             upload the bootloader files without touching flash
  --yes              do not ask before --flash / --boot
  --keep             keep the uploaded files in the remote staging dir
  --tree DIR         ImmortalWrt source tree (default: project parent)
  -h, --help         show this help

Environment:
  GWRT_ROUTER_HOST, GWRT_ROUTER_USER, GWRT_REMOTE_DIR

Bootloader files are only uploaded.  Writing them requires a deliberate
U-Boot or Linux mtd/UBI step; this script never rewrites BL2/FIP implicitly.
EOF
}

die() {
	echo "deploy: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tree)
			[ "$#" -ge 2 ] || die "--tree requires a directory"
			TREE="$2"
			shift 2
			;;
		--image)
			[ "$#" -ge 2 ] || die "--image requires a file"
			IMAGE="$2"
			shift 2
			;;
		--host)
			[ "$#" -ge 2 ] || die "--host requires an address"
			HOST="$2"
			shift 2
			;;
		--user)
			[ "$#" -ge 2 ] || die "--user requires a name"
			USER="$2"
			shift 2
			;;
		--remote-dir)
			[ "$#" -ge 2 ] || die "--remote-dir requires a directory"
			REMOTE_DIR="$2"
			shift 2
			;;
		--bl2)
			[ "$#" -ge 2 ] || die "--bl2 requires a file"
			BL2="$2"
			shift 2
			;;
		--fip)
			[ "$#" -ge 2 ] || die "--fip requires a file"
			FIP="$2"
			shift 2
			;;
		--flash)
			FLASH=1
			shift
			;;
		--boot)
			BOOT=1
			shift
			;;
		--yes)
			ASSUME_YES=1
			shift
			;;
		--keep)
			KEEP_REMOTE=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

TREE="$(CDPATH= cd -- "$TREE" && pwd)"
[ -d "$TREE" ] || die "source tree not found: $TREE"
[ -n "$HOST" ] || die "empty router address"
[ -n "$USER" ] || die "empty ssh user"

latest_image() {
	set -- "$TREE"/bin/targets/"$TARGET"/"$SUBTARGET"/*-sysupgrade.itb
	[ -f "$1" ] || return 1
	ls -t "$@" | head -n 1
}

if [ -z "$IMAGE" ]; then
	IMAGE="$(latest_image || true)"
fi
[ -n "$IMAGE" ] || die "no sysupgrade image found; pass --image FILE"
[ -f "$IMAGE" ] || die "image not found: $IMAGE"

if [ "$BOOT" -eq 1 ] && [ -z "$BL2" ] && [ -z "$FIP" ]; then
	die "--boot needs --bl2 FILE and/or --fip FILE"
fi
if [ -n "$BL2" ] && [ ! -f "$BL2" ]; then
	die "BL2 file not found: $BL2"
fi
if [ -n "$FIP" ] && [ ! -f "$FIP" ]; then
	die "FIP file not found: $FIP"
fi

SSH="ssh $SSH_OPTS $USER@$HOST"
SCP="scp $SCP_OPTS $SSH_OPTS"
REMOTE_DIR="${REMOTE_DIR%/}"

remote_mkdir() {
	# shellcheck disable=SC2086
	$SSH "mkdir -p '$REMOTE_DIR'" >/dev/null
}

upload_file() {
	file="$1"
	base="$(basename -- "$file")"
	local_sum="$(sha256sum "$file" | awk '{print $1}')"

	# -O is needed by older Dropbear builds that do not implement SFTP.
	# shellcheck disable=SC2086
	if ! $SCP "$file" "$USER@$HOST:$REMOTE_DIR/$base"; then
		# Dropbear with SFTP support: retry without the legacy flag.
		# shellcheck disable=SC2086
		scp $SSH_OPTS "$file" "$USER@$HOST:$REMOTE_DIR/$base" ||
			die "scp failed for $file"
	fi

	# shellcheck disable=SC2086
	remote_sum="$($SSH "sha256sum '$REMOTE_DIR/$base'" | awk '{print $1}')"
	[ "$remote_sum" = "$local_sum" ] ||
		die "sha256 mismatch for $base (local $local_sum, remote $remote_sum)"

	printf '%s  %s\n' "$local_sum" "$base"
}

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r answer
	case "$answer" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

printf 'deploy: %s@%s:%s\n' "$USER" "$HOST" "$REMOTE_DIR"
remote_mkdir

[ -n "$IMAGE" ] && upload_file "$IMAGE"
[ -n "$BL2" ] && upload_file "$BL2"
[ -n "$FIP" ] && upload_file "$FIP"

if [ "$BOOT" -eq 1 ]; then
	echo
	echo "Bootloader files uploaded.  They have NOT been written to flash."
	echo "For a U-Boot recovery boot, use the existing TFTP/write commands."
	echo "For a deliberate Linux-side update, use the verified files and"
	echo "the mtd/UBI procedure appropriate for this board."
fi

if [ "$FLASH" -eq 1 ]; then
	image_base="$(basename -- "$IMAGE")"
	confirm "Write $image_base with sysupgrade?" ||
		die "sysupgrade cancelled; image remains at $REMOTE_DIR/$image_base"
	# shellcheck disable=SC2086
	$SSH "sysupgrade -v '$REMOTE_DIR/$image_base'"
	echo "deploy: sysupgrade started; the ssh session will disconnect"
	exit 0
fi

if [ "$KEEP_REMOTE" -eq 0 ]; then
	# Remove only the files this run uploaded, never anything pre-existing.
	[ -n "$IMAGE" ] && $SSH "rm -f '$REMOTE_DIR/$(basename -- "$IMAGE")'" >/dev/null || true
	[ -n "$BL2" ] && $SSH "rm -f '$REMOTE_DIR/$(basename -- "$BL2")'" >/dev/null || true
	[ -n "$FIP" ] && $SSH "rm -f '$REMOTE_DIR/$(basename -- "$FIP")'" >/dev/null || true
fi

echo "deploy: upload complete; pass --flash to install the image"
