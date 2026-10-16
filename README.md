# ex6150v2-vless-ap

Turn a **Netgear EX6150v2** into a fast, private **VLESS Wi-Fi access point**: lean OpenWrt, ARM-optimized sing-box (2.4× faster ChaCha20-Poly1305), a one-click web manager, a kill switch and no DNS leaks.

Plug the extender into your home router with a cable. Every phone, TV or console that joins its Wi-Fi then goes through your VLESS server, with no VPN app on any device.

```
 Internet ── home router ──(Ethernet, DHCP)── EX6150v2 ══(VLESS + TLS)══> your VLESS server
                                                 │
                                    Wi-Fi 2.4 + 5 GHz "your VPN network"
                                    (192.168.2.0/24, VPN-only, kill switch)
```

## What you get

| | |
|---|---|
| **Speed** | 140+ Mbps through the VPN on 2–4 connections (VLESS + Vision). Browser speed tests up to about 240 Mbps on 5 GHz. Measurements are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md). |
| **VPN manager on `:90`** | Paste a VLESS link, start or stop the VPN, set the visible hostname (SNI), change Wi-Fi. Shows the exit IP, ISP and ping. |
| **LuCI on `:80`** | Full OpenWrt dashboard, with a **VPN Manager** entry in the menu. |
| **Kill switch** | While the VPN is on, Wi-Fi devices can only reach the internet through the tunnel. |
| **No leaks** | DNS goes through the tunnel and is reached over DoH. The router never sends plaintext DNS or HTTP out of the WAN. Time sync uses IP addresses. |
| **Hidden server name** | An optional SNI override shows observers a hostname of your choice instead of your server's. The server's certificate is still verified against its real name (key pinning). |
| **Lean** | 16 MB flash and 256 MB RAM are enough. sing-box is cut down to what this device needs (about 18 MB, in squashfs). Wi-Fi interrupts are tuned, and zram is on. |

Supported links: `vless://` with `security=tls` (plain TLS, or `flow=xtls-rprx-vision`) or `security=reality`. Transports: `tcp`, `ws`, `httpupgrade`, `grpc`, `http`.

## Quick start (non-technical)

You need a Windows, macOS or Linux computer on the same home network, an Ethernet cable, and your VLESS link.

1. Download the installer from the [latest release](../../releases/latest):
   - **Windows:** `installer.zip`. Extract it and double-click **`install-windows.bat`**.
   - **macOS / Linux:** `installer.zip`. Extract it and run `bash install.sh` in a terminal.
2. Answer the questions. The installer will:
   - download the firmware and check its SHA-256;
   - show you exactly which file to upload in the Netgear **Firmware Update** page;
   - find the extender on your network;
   - ask for an admin password, a Wi-Fi name and password, and your VLESS link;
   - wait until the VPN is connected.
3. Join the new Wi-Fi network. Open <https://ipinfo.io>; it should show your VPN server's location.

The installer never asks for your Netgear password. You type it into the Netgear page yourself.

You can also skip the installer: flash the `factory.img` from the release in the Netgear web UI, connect the extender by cable, find its IP in your router's device list (`ex6150v2-vpn`), and open `http://<ip>:90`. The setup page asks for the same things.

## For technical users

| Guide | Contents |
|---|---|
| [docs/INSTALL-manual.md](docs/INSTALL-manual.md) | Manual flashing (stock and OpenWrt), first-boot layout, SSH, setup API |
| [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) | Architecture: auto_redirect, DNS path, kill switch, key pinning, files on the router |
| [docs/SERVER-3x-ui.md](docs/SERVER-3x-ui.md) | Fastest server setup: a VLESS + Vision inbound in 3x-ui / Xray |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Every optimisation with numbers, including the ones that failed (kTLS leak, BBR, bigger rings) |
| [docs/PRIVACY.md](docs/PRIVACY.md) | What an observer on your line can see, and how to check it yourself |
| [docs/BUILD.md](docs/BUILD.md) | Building sing-box (patches, crypto overlay) and the image from source |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common problems |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Un-bricking with nmrpflash / TFTP, going back to Netgear firmware |

### Repository layout

```
router/      files baked into the image (init scripts, VPN scripts, :90 web manager, LuCI menu entry)
singbox/     sing-box patches, ARM crypto overlay, build.sh, cryptobench (correctness + speed test)
image/       OpenWrt ImageBuilder script
installer/   Windows (.bat + PowerShell) and Linux/macOS installers
bench/       on-router speed and privacy checks
tools/       building OpenWrt from source, make-public.sh
docs/        guides
```

## Safety

- Flashing third-party firmware can brick a device, and you do it at your own risk. Recovery is almost always possible; see [docs/RECOVERY.md](docs/RECOVERY.md).
- The web manager, LuCI and SSH accept connections from the home-network side (the extender's WAN) and its own Wi-Fi. Use a strong admin password.
- Use this only with servers you are allowed to use, and follow the laws and network rules that apply to you.

## License

GPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). This project is not affiliated with Netgear, OpenWrt, SagerNet / sing-box, or Project X.
