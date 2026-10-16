#!/bin/bash
# Build the minimal, ARM-optimised sing-box for the EX6150v2 (armv7, Cortex-A7).
#
#   singbox/build.sh [out-dir]          -> out-dir/sing-box  and  out-dir/cryptobench
#
# Needs: git, Go 1.26.x (the crypto overlay replaces files of Go's vendored x/crypto, so the
# Go minor version matters), diff/patch. Works on Linux, macOS and Git Bash/WSL on Windows.
set -euo pipefail

SINGBOX_TAG=v1.14.3
SING_VER=v0.9.7-0.20260929150544-0ad23b637bd4
SINGTUN_VER=v0.9.7-0.20261009020158-bca4bf029237
VERSION_STRING=${VERSION_STRING:-1.14.3-ex6150v2}
GO_WANT=go1.26

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${1:-$HERE/../dist}" && cd "${1:-$HERE/../dist}" && pwd)
WORK=${WORK:-$HERE/.work}

gov=$(go env GOVERSION)
case "$gov" in $GO_WANT|$GO_WANT.*) ;; *) echo "need $GO_WANT.x, found $gov" >&2; exit 1 ;; esac

mkdir -p "$WORK"
cd "$WORK"

# 1. upstream sing-box at the pinned tag
if [ ! -d sing-box ]; then
	git clone -q --depth 1 -b "$SINGBOX_TAG" https://github.com/SagerNet/sing-box.git sing-box
fi
git -C sing-box checkout -q -- . && git -C sing-box clean -qfd

# 2. patched copies of sing and sing-tun (exact versions sing-box pins)
modcopy() { # module version dest
	local dir ver
	ver=$(cd sing-box && go list -m -f '{{.Version}}' "$1")
	[ "$ver" = "$2" ] || { echo "$1: sing-box pins $ver, patches are for $2" >&2; exit 1; }
	(cd sing-box && go mod download "$1")
	dir=$(cd sing-box && go list -m -f '{{.Dir}}' "$1")
	rm -rf "$3"; cp -r "$dir" "$3"; chmod -R u+w "$3"
}
modcopy github.com/sagernet/sing "$SING_VER" sing-patched
modcopy github.com/sagernet/sing-tun "$SINGTUN_VER" sing-tun-patched
patch -s -d sing-patched -p1 < "$HERE/patches/sing-pipelined-copy.patch"
patch -s -d sing-tun-patched -p1 < "$HERE/patches/sing-tun-eexist.patch"

# 3. trimmed registry, minimal CLI and the crypto test tool
cp "$HERE/patches/registry.go" sing-box/include/registry.go
mkdir -p sing-box/cmd/sbmini sing-box/cmd/cryptobench
cp "$HERE/patches/sbmini/main.go" sing-box/cmd/sbmini/main.go
cp -r "$HERE/cryptobench/." sing-box/cmd/cryptobench/
(cd sing-box && go mod edit -replace github.com/sagernet/sing=../sing-patched \
	-replace github.com/sagernet/sing-tun=../sing-tun-patched)

# 4. crypto overlay: ARM assembly for ChaCha20 and a 26-bit-limb Poly1305 inside Go's
#    vendored golang.org/x/crypto (the copy crypto/tls uses)
for f in poly26_arm.s poly26_arm.go; do cmp -s "$HERE/overlay/$f" "$HERE/cryptobench/poly26/$f" || { echo "overlay/$f differs from the tested copy" >&2; exit 1; }; done
for f in chacha_arm.s chacha_arm.go; do cmp -s "$HERE/overlay/$f" "$HERE/cryptobench/chacha20arm/$f" || { echo "overlay/$f differs from the tested copy" >&2; exit 1; }; done
GOROOT_DIR=$(go env GOROOT)
V=$GOROOT_DIR/src/vendor/golang.org/x/crypto
[ -f "$V/internal/poly1305/sum_generic.go" ] && [ -f "$V/chacha20/chacha_noasm.go" ] || { echo "unexpected Go source layout in $GOROOT_DIR" >&2; exit 1; }
O=$HERE/overlay
if command -v cygpath >/dev/null 2>&1; then V=$(cygpath -m "$V"); O=$(cygpath -m "$O"); fi
cat > overlay.json <<EOF
{
 "Replace": {
  "$V/internal/poly1305/sum_generic.go": "$O/sum_generic.go",
  "$V/internal/poly1305/poly26_arm.go": "$O/poly26_arm.go",
  "$V/internal/poly1305/poly26_arm.s": "$O/poly26_arm.s",
  "$V/internal/poly1305/poly26_generic.go": "$O/poly26_generic.go",
  "$V/chacha20/chacha_noasm.go": "$O/chacha_noasm.go",
  "$V/chacha20/chacha_arm.go": "$O/chacha_arm.go",
  "$V/chacha20/chacha_arm.s": "$O/chacha_arm.s"
 }
}
EOF
OVERLAY=$WORK/overlay.json
command -v cygpath >/dev/null 2>&1 && OVERLAY=$(cygpath -m "$OVERLAY")

# 5. cross-build for armv7
cd sing-box
export GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0
LDF="-X 'github.com/sagernet/sing-box/constant.Version=$VERSION_STRING' $(cat release/LDFLAGS) -s -w -buildid="
go build -overlay "$OVERLAY" -trimpath -tags "with_utls,badlinkname,tfogo_checklinkname0" -ldflags "$LDF" -o "$OUT/sing-box" ./cmd/sbmini
go build -trimpath -ldflags "-s -w -buildid=" -o "$OUT/cryptobench" ./cmd/cryptobench

ls -l "$OUT/sing-box" "$OUT/cryptobench"
echo "Test the crypto before shipping:  qemu-arm $OUT/cryptobench verify   (or run it on the router)"
