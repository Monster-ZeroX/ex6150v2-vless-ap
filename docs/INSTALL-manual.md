# Manual installation

## 1. Get the firmware

Download from the [latest release](../../../releases/latest) and check the files against `SHA256SUMS` (`sha256sum -c SHA256SUMS --ignore-missing`):

| File | Use when |
|---|---|
| `openwrt-…-netgear_ex6150v2-squashfs-factory.img` | The extender runs **Netgear's firmware** |
| `openwrt-…-netgear_ex6150v2-squashfs-sysupgrade.bin` | The extender already runs **OpenWrt** |

Only the **EX6150 v2** is supported. The v1 is different hardware: check the label under the device.

## 2a. From Netgear firmware

1. Connect to the extender. Open `http://mywifiext.net` or its IP address and log in.
2. Go to **Settings → Firmware Update** (on some versions **Maintenance → Firmware Update**), choose the `factory.img` and upload it.
3. Wait about 5 minutes. The power LED settles when OpenWrt has booted.

If the web UI refuses the file, use nmrpflash (see [RECOVERY.md](RECOVERY.md)). It flashes the same `factory.img`.

## 2b. From OpenWrt

```bash
scp -O openwrt-*-sysupgrade.bin root@<extender>:/tmp/fw.bin
ssh root@<extender> 'sysupgrade -T /tmp/fw.bin && sysupgrade -n /tmp/fw.bin'
```

`-n` discards the old settings, which you want when coming from another OpenWrt setup. When upgrading **this** project, leave out `-n` to keep your link, SNI, Wi-Fi and passwords. Everything in `/etc/sing-box/` plus OpenWrt's own config is kept.

## 3. First boot

After a fresh flash:

- The **Ethernet port is the uplink**. Plug it into your home router. It takes an address by DHCP, so it never conflicts with your router. Find the address in your router's device list under the hostname `ex6150v2-vpn`.
- The **Wi-Fi is off** until setup.
- `root` has **no password yet**, so SSH and LuCI stay closed to your home network until setup sets one. Only the `:90` setup page is reachable.

If there is no cable to your router, connect a PC directly to the Ethernet port with a static address in your router's subnet. It is easier to use the router.

## 4. Setup

Open `http://<extender-ip>:90` and fill in:

| Field | Notes |
|---|---|
| Admin password | Min. 8 characters. Logs in to `:90`, and also LuCI and SSH as `root`. |
| Wi-Fi name / password | The same name on 2.4 and 5 GHz, WPA2-PSK |
| VLESS link | `vless://…`, as exported by 3x-ui, Xray panels, V2Box, v2rayNG |
| SNI override | Optional. See [PRIVACY.md](PRIVACY.md). |

Or use the API, which is what the installers do:

```bash
curl -H 'Content-Type: application/json' http://<ip>:90/cgi-bin/vpn?action=setup \
  --data '{"password":"…","wifi_ssid":"MyVPN","wifi_key":"…","link":"vless://…","sni":"","ssh_key":"ssh-ed25519 AAAA… me@pc"}'
```

## 5. Daily use

- **`http://<ip>:90`**: VPN manager. Swap the link when your server changes, start/stop (Bypass) the VPN, change the SNI or Wi-Fi.
- **`http://<ip>`**: LuCI, the full OpenWrt UI. The **VPN Manager** menu entry opens `:90`.
- **SSH:** `ssh root@<ip>` with your admin password, or the key you gave at setup.

## Fixed IP (optional)

In LuCI go to **Network → Interfaces → wan → Edit**: protocol *Static address*, your IP, netmask, gateway (your router) and DNS `1.1.1.1`. Or reserve the extender's MAC address in your router's DHCP settings, which is easier.

## Country / channels

For the best 5 GHz channels, set your country in LuCI (**Network → Wireless → Edit → Advanced → Country Code**).
