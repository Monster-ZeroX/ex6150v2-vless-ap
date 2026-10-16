#!/bin/bash
# Build the lean EX6150v2 VLESS AP image with OpenWrt ImageBuilder (run inside WSL/Linux).
# Usage: build-image.sh <openwrt-version> <router-files-dir> <sing-box-binary> <out-dir>
set -euo pipefail

VER=$1 FILES_SRC=$(realpath "$2") SB_BIN=$(realpath "$3") OUT=$4
mkdir -p "$OUT"; OUT=$(realpath "$OUT")
BASE=https://downloads.openwrt.org/releases/$VER/targets/ipq40xx/generic
IB=openwrt-imagebuilder-$VER-ipq40xx-generic.Linux-x86_64
WORK=$HOME/owrt-ib
mkdir -p "$WORK" "$OUT"
cd "$WORK"

if [ ! -d "$IB" ]; then
	wget -q "$BASE/$IB.tar.zst" -O "$IB.tar.zst"
	wget -q "$BASE/sha256sums" -O "sha256sums-$VER"
	grep " \*\?$IB.tar.zst\$" "sha256sums-$VER" | sed 's/ \*/  /' | sha256sum -c -
	tar --zstd -xf "$IB.tar.zst"
	rm "$IB.tar.zst"
fi

# files overlay: our scripts + the minimal sing-box binary
rm -rf "files-$VER"
mkdir -p "files-$VER/usr/bin"
cp -r "$FILES_SRC"/. "files-$VER/"
cp "$SB_BIN" "files-$VER/usr/bin/sing-box"
find "files-$VER" -type f \( -path '*/init.d/*' -o -path '*/libexec/*' -o -path '*/cgi-bin/*' -o -path '*/uci-defaults/*' -o -path '*/usr/bin/*' \) -exec chmod 755 {} +
find "files-$VER" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
# sed would corrupt the binary: restore it after line-ending normalisation
cp "$SB_BIN" "files-$VER/usr/bin/sing-box"; chmod 755 "files-$VER/usr/bin/sing-box"

# LuCI dashboard on :80 by default (costs <3 % throughput); LUCI=0 builds the leanest image
LUCI_PKGS="luci-light -luci-ssl"
[ "${LUCI:-1}" = 0 ] && LUCI_PKGS="-luci -luci-ssl"
PKGS="$LUCI_PKGS -ppp -ppp-mod-pppoe -odhcpd-ipv6only -odhcp6c \
	-kmod-usb3 -kmod-usb-dwc3 -kmod-usb-dwc3-qcom \
	kmod-tun jq uhttpd zram-swap \
	kmod-tls kmod-crypto-chacha20poly1305 kmod-crypto-lib-chacha20 kmod-crypto-lib-poly1305"

cd "$IB"
rm -f bin/targets/ipq40xx/generic/*ex6150v2*   # no stale images from earlier runs
make -s image PROFILE=netgear_ex6150v2 PACKAGES="$PKGS" FILES="$WORK/files-$VER" EXTRA_IMAGE_NAME=${IMAGE_NAME:-vless-ap} 2>&1 | tail -20
for f in bin/targets/ipq40xx/generic/*ex6150v2*; do
	cp "$f" "$OUT/"
done
ls -la "$OUT" | grep "$VER"
(cd "$OUT" && sha256sum *"$VER"*ex6150v2* > "sha256-$VER.txt")
