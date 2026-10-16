#!/bin/bash
# Build OpenWrt from source for the Netgear EX6150v2 with our kernel patches and the same
# package set / files overlay as build-image.sh. Run inside WSL as root.
# EXPERIMENTAL - only for kernel experiments. Release images use ImageBuilder (image/build-image.sh).
# Kernel patches: KDIR/9*.patch (default: this folder; the 512-ring patch here was REJECTED -
# no gain and unstable - pass KDIR=<your patch dir> for your own experiments).
# Usage: build-from-source.sh <router-files-dir> <sing-box-binary> <out-dir>
set -euo pipefail

VER=v25.12.5
FILES_SRC=$1 SB_BIN=$2 OUT=$3
KDIR=${KDIR:-$(cd "$(dirname "$0")" && pwd)}
W=$HOME/owrt-src
SRC=$W/openwrt
JOBS=$(nproc)
mkdir -p "$W" "$OUT"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext \
	git libncurses-dev libssl-dev python3-setuptools python3-dev rsync swig unzip zlib1g-dev file wget \
	zstd xz-utils >/dev/null

if [ ! -d "$SRC" ]; then
	git clone -q --depth 1 -b "$VER" https://github.com/openwrt/openwrt.git "$SRC"
fi
cd "$SRC"
./scripts/feeds update -a >/dev/null
./scripts/feeds install -a >/dev/null

# our kernel patches (applied after OpenWrt's own ipq40xx patches)
cp "$KDIR"/9*.patch target/linux/ipq40xx/patches-6.12/ 2>/dev/null || true

# config: one device, same packages as the ImageBuilder image
cat > .config <<'EOF'
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_generic=y
CONFIG_TARGET_ipq40xx_generic_DEVICE_netgear_ex6150v2=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_zram-swap=y
CONFIG_PACKAGE_kmod-tls=y
CONFIG_PACKAGE_kmod-crypto-chacha20poly1305=y
CONFIG_PACKAGE_kmod-crypto-lib-chacha20=y
CONFIG_PACKAGE_kmod-crypto-lib-poly1305=y
CONFIG_PACKAGE_luci-light=y
# CONFIG_PACKAGE_ppp is not set
# CONFIG_PACKAGE_ppp-mod-pppoe is not set
# CONFIG_PACKAGE_odhcpd-ipv6only is not set
# CONFIG_PACKAGE_odhcp6c is not set
# CONFIG_PACKAGE_kmod-usb3 is not set
# CONFIG_PACKAGE_kmod-usb-dwc3 is not set
# CONFIG_PACKAGE_kmod-usb-dwc3-qcom is not set
CONFIG_VERSIONOPT=y
CONFIG_VERSION_REPO="https://downloads.openwrt.org/releases/25.12.5"
EOF
make defconfig >/dev/null
grep -E '^CONFIG_TARGET_ipq40xx_generic_DEVICE_netgear_ex6150v2=y' .config

# files overlay: router scripts + the minimal sing-box
rm -rf files
mkdir -p files/usr/bin
cp -r "$FILES_SRC"/. files/
find files -type f -exec sed -i 's/\r$//' {} +
cp "$SB_BIN" files/usr/bin/sing-box
find files -type f \( -path '*/init.d/*' -o -path '*/libexec/*' -o -path '*/cgi-bin/*' -o -path '*/uci-defaults/*' -o -path '*/usr/bin/*' \) -exec chmod 755 {} +

echo "== download $(date +%T)"
make -j"$JOBS" download >/dev/null
echo "== build $(date +%T) with $JOBS jobs"
make -j"$JOBS" world > build.log 2>&1 || { tail -60 build.log; echo "BUILD FAILED"; exit 1; }
echo "== done $(date +%T)"

# confirm our ring patch was applied to the built kernel tree
grep -rh 'define IPQESS_RX_RING_SIZE' build_dir/target-*/linux-ipq40xx_generic/linux-*/drivers/net/ethernet/qualcomm/ipqess/ipqess.h

for f in bin/targets/ipq40xx/generic/*ex6150v2*; do
	cp "$f" "$OUT/src-$(basename "$f")"
done
ls -la "$OUT" | grep 'src-'
(cd "$OUT" && sha256sum src-*ex6150v2* > sha256-src.txt)
