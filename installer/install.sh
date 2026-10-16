#!/usr/bin/env bash
# ex6150v2-vless-ap installer for Linux and macOS.
#   bash install.sh             (guided: download, flash, find the extender, set it up)
#   bash install.sh --setup     (skip flashing: only find the extender and set it up)
# Your Netgear and router passwords are never asked for or stored by this script: you type them
# into the Netgear web page or into ssh yourself.
set -euo pipefail

REPO=${REPO:-Monster-ZeroX/ex6150v2-vless-ap}
KEY=$HOME/.ssh/ex6150v2_vpn
DL=${DL:-$HOME/Downloads/ex6150v2-vless-ap}

b=$(tput bold 2>/dev/null || true); n=$(tput sgr0 2>/dev/null || true)
say()  { printf '\n%s==> %s%s\n' "$b" "$*" "$n"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 " a; printf '%s' "$a"; }
yes()  { local a; read -r -p "$1 [y/N] " a; [[ $a == [yY]* ]]; }
secret() { local a; read -r -s -p "$1 " a; echo >&2; printf '%s' "$a"; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required. Install it and run again."; }
need curl; need ssh; need ssh-keygen
if command -v sha256sum >/dev/null; then SHA="sha256sum"; else need shasum; SHA="shasum -a 256"; fi

json_str() { # JSON string literal; rejects control characters
	local s=$1
	[[ $s == *[$'\x01'-$'\x1f']* ]] && die "input contains control characters"
	s=${s//\\/\\\\}; s=${s//\"/\\\"}
	printf '"%s"' "$s"
}
jget() { sed -n "s/.*\"$1\":\([a-z]*\).*/\1/p"; } # boolean field of a flat JSON reply

# ------------------------------------------------------------------------------------------
download() {
	say "Downloading the latest firmware from github.com/$REPO"
	mkdir -p "$DL"
	local rel urls u
	rel=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") || die "cannot reach GitHub"
	TAG=$(printf '%s' "$rel" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
	urls=$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"/\1/')
	for u in $urls; do
		case "$u" in *factory.img|*sysupgrade.bin|*SHA256SUMS) curl -fL --progress-bar -o "$DL/${u##*/}" "$u" ;; esac
	done
	FACTORY=$(ls "$DL"/*ex6150v2*factory.img 2>/dev/null | head -n1)
	SYSUP=$(ls "$DL"/*ex6150v2*sysupgrade.bin 2>/dev/null | head -n1)
	[ -n "$FACTORY" ] && [ -n "$SYSUP" ] && [ -f "$DL/SHA256SUMS" ] || die "release $TAG is missing files"
	(cd "$DL" && grep -E "(${FACTORY##*/}|${SYSUP##*/})\$" SHA256SUMS | $SHA -c -) || die "checksum mismatch - delete $DL and try again"
	echo "Release $TAG verified (SHA-256 OK) in $DL"
}

flash_stock() {
	say "Flash from the Netgear firmware"
	cat <<EOF
1. Connect your computer to the extender (its Wi-Fi or Ethernet) and open
      http://mywifiext.net   (or the extender's IP address)
   and log in with your Netgear admin password.
2. Go to  Settings -> Firmware Update  (on some versions: Maintenance -> Firmware Update).
3. Choose this file and click Upload:
      $FACTORY
4. Wait about 5 minutes. Do NOT unplug the extender while it flashes.
5. Plug an Ethernet cable from the extender into your home router (or a switch on it).
   The extender gets an address from your router automatically. Its Wi-Fi stays OFF until setup.
EOF
	read -r -p "Press Enter when the extender has rebooted and is connected by cable... " _
}

flash_openwrt() {
	say "Upgrade an extender that already runs OpenWrt"
	local ip; ip=$(ask "Extender IP address:")
	echo "ssh may ask for the extender's root password (type it there; this script never sees it)."
	scp -O -o StrictHostKeyChecking=accept-new "$SYSUP" "root@$ip:/tmp/fw.bin" || scp -o StrictHostKeyChecking=accept-new "$SYSUP" "root@$ip:/tmp/fw.bin"
	ssh -o StrictHostKeyChecking=accept-new "root@$ip" 'sysupgrade -T /tmp/fw.bin && echo IMAGE-OK' | grep -q IMAGE-OK || die "the extender rejected the image"
	if yes "Does it already run ex6150v2-vless-ap (keep its settings)?"; then
		ssh "root@$ip" 'sysupgrade /tmp/fw.bin' || true
		EXT=$ip
	else
		echo "Flashing WITHOUT old settings. Afterwards plug the extender's Ethernet into your home router."
		ssh "root@$ip" 'sysupgrade -n /tmp/fw.bin' || true
	fi
	echo "Flashing. Waiting 3 minutes for the reboot..."
	sleep 180
}

# ------------------------------------------------------------------------------------------
local_prefix() {
	local ip=
	if command -v ip >/dev/null; then
		ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	else
		local ifc; ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
		[ -n "$ifc" ] && ip=$(ipconfig getifaddr "$ifc" 2>/dev/null || true)
	fi
	[ -n "$ip" ] && echo "${ip%.*}"
}

probe() { curl -fs -m 2 "http://$1:90/cgi-bin/vpn?action=status" 2>/dev/null | grep -q '"app":"ex6150v2-vless-ap"'; }

find_extender() {
	if [ -n "${EXT:-}" ] && probe "$EXT"; then return; fi
	say "Looking for the extender on your network"
	local pre; pre=$(local_prefix) || true
	if [ -n "$pre" ]; then
		echo "Scanning $pre.1-254 ..."
		EXT=$(seq 1 254 | xargs -P 64 -I{} sh -c "curl -fs -m 2 'http://$pre.{}:90/cgi-bin/vpn?action=status' 2>/dev/null | grep -q '\"app\":\"ex6150v2-vless-ap\"' && echo $pre.{}" | head -n1)
	fi
	if [ -z "${EXT:-}" ]; then
		echo "Not found automatically. Look up the extender in your router's list of connected devices"
		echo "(name: ex6150v2-vpn)."
		EXT=$(ask "Extender IP address:")
		probe "$EXT" || die "no VPN manager answers on http://$EXT:90"
	fi
	echo "Found the extender at $EXT"
}

setup() {
	local st; st=$(curl -fs -m 5 "http://$EXT:90/cgi-bin/vpn?action=status")
	if [ "$(printf '%s' "$st" | jget setup_required)" != true ]; then
		say "This extender is already set up"
		echo "Manage it at http://$EXT:90 (log in with your admin password)."
		return
	fi
	say "Set up your VPN access point"
	local pw pw2 ssid wkey link sni pub body
	while :; do
		pw=$(secret "Admin password (min. 8 characters; also the LuCI/SSH root password):")
		pw2=$(secret "Repeat it:")
		[ "$pw" = "$pw2" ] && [ ${#pw} -ge 8 ] && break
		echo "Passwords differ or are shorter than 8 characters."
	done
	while :; do ssid=$(ask "Wi-Fi name for the VPN network:"); [ -n "$ssid" ] && [ ${#ssid} -le 32 ] && break; done
	while :; do wkey=$(secret "Wi-Fi password (8-63 characters):"); [ ${#wkey} -ge 8 ] && [ ${#wkey} -le 63 ] && break; done
	while :; do link=$(ask "Paste your VLESS link (vless://...):"); [[ $link == vless://* ]] && break; done
	sni=$(ask "SNI override - hostname shown on the network instead of your server's (Enter = none):")
	if [ ! -f "$KEY" ]; then ssh-keygen -q -t ed25519 -N '' -C "ex6150v2-vpn" -f "$KEY"; fi
	pub=$(cat "$KEY.pub")
	body="{\"password\":$(json_str "$pw"),\"wifi_ssid\":$(json_str "$ssid"),\"wifi_key\":$(json_str "$wkey"),\"link\":$(json_str "$link"),\"sni\":$(json_str "$sni"),\"ssh_key\":$(json_str "$pub")}"
	local r; r=$(curl -s -m 60 -H 'Content-Type: application/json' --data-binary @- "http://$EXT:90/cgi-bin/vpn?action=setup" <<<"$body")
	[ "$(printf '%s' "$r" | jget ok)" = true ] || die "setup failed: $r"
	echo "Setup saved. SSH key: $KEY  (ssh -i $KEY root@$EXT)"
}

verify() {
	say "Waiting for the VPN tunnel"
	local i st
	for i in $(seq 1 30); do
		st=$(curl -fs -m 3 "http://$EXT:90/cgi-bin/vpn?action=status" || true)
		if [ "$(printf '%s' "$st" | jget tunnel)" = true ]; then
			cat <<EOF

${b}Done! The VPN is connected.${n}
  - Join the Wi-Fi network you just named. Everything on it goes through your VLESS server.
  - Manage the VPN:   http://$EXT:90
  - Router dashboard: http://$EXT   (LuCI, user root, your admin password)
  - Check it: on a phone on that Wi-Fi, open https://ipinfo.io - it should show your server's location.
EOF
			return
		fi
		sleep 3
	done
	echo "The tunnel is not up yet. Open http://$EXT:90 and check the link (see docs/TROUBLESHOOTING.md)."
}

# ------------------------------------------------------------------------------------------
echo "${b}EX6150v2 VLESS access point installer${n}"
if [ "${1:-}" != --setup ]; then
	echo "What is on your extender now?"
	echo "  1) Netgear's original firmware"
	echo "  2) OpenWrt (this project or another OpenWrt build)"
	echo "  3) Already flashed - only set it up"
	c=$(ask "Choose 1, 2 or 3:")
	case "$c" in
	1) download; flash_stock ;;
	2) download; flash_openwrt ;;
	3) ;;
	*) die "please choose 1, 2 or 3" ;;
	esac
fi
find_extender
setup
verify
