#!/bin/sh
# Build the DAED runtime repair from a staged dae-wing checkout and its frontend.
set -eu

if [ "$#" -ne 2 ]; then
	printf 'Usage: %s <dae-wing-source> <output-binary>\n' "$0" >&2
	exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wing_dir=$(CDPATH= cd -- "$1" && pwd)
output=$(realpath -m -- "$2")
runtime_patch="$script_dir/patches/daed-runtime-overview-active-plane.patch"
go_cmd=${GWRT_GO:-go}
clang_cmd=${BPF_CLANG:-clang}
strip_cmd=${BPF_STRIP:-llvm-strip}

for required in dae/runtime.go dae-core/control/control.go dae-core/control/kern/headers/bpf_helpers.h; do
	[ -f "$wing_dir/$required" ] || {
		printf 'Missing source dependency: %s\n' "$required" >&2
		exit 1
	}
done
if [ ! -f "$wing_dir/webrender/web/index.html" ] && [ ! -f "$wing_dir/webrender/web/index.html.gz" ]; then
	echo 'Stage the matching DAED frontend under webrender/web first.' >&2
	exit 1
fi

cd "$wing_dir"
if patch -p1 --batch --forward --dry-run -s < "$runtime_patch" >/dev/null 2>&1; then
	patch -p1 --batch --forward -s < "$runtime_patch"
elif ! patch -p1 --batch -R --dry-run -s < "$runtime_patch" >/dev/null 2>&1; then
	echo 'Runtime patch does not match this dae-wing source.' >&2
	exit 1
fi

# Generators run on the build host; only the final binary targets the router.
unset GOOS GOARCH GOARM GOARM64
export CGO_ENABLED=0
export BPF_CLANG="$clang_cmd"
export BPF_STRIP_FLAG="-strip=$(command -v "$strip_cmd")"
export BPF_CFLAGS='-O2 -g -DMAX_MATCH_SET_LEN=1024'
export BPF_TARGET=bpfel
export BPF_TRACE_TARGET=arm64
(
	cd dae-core
	"$go_cmd" generate ./control/control.go
	"$go_cmd" generate ./trace/trace.go
	"$go_cmd" test -p 4 -tags dae_stub_ebpf ./control \
		-run 'Test(GlobalRuntimeStats|ControlPlaneRuntimeStats|RelayTCPRecordsRuntimeTraffic)' -count=1
)
"$go_cmd" generate ./graphql/service/config/global
mkdir -p "$(dirname -- "$output")"
GOOS=linux GOARCH=arm64 "$go_cmd" build -p 4 -mod=mod \
	-tags=embedallowed,trace -trimpath \
	-ldflags '-s -w -X github.com/daeuniverse/dae-wing/db.AppName=daed -X github.com/daeuniverse/dae-wing/db.AppVersion=daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1' \
	-o "$output" .
sha256sum "$output"
