# Troubleshooting

Logs: `ssh root@<extender> 'logread -e sing-box -e vpn-refresh | tail -50'`

| Symptom | Fix |
|---|---|
| **Installer can't find the extender** | Check that it is cabled to your router (Ethernet port, not Wi-Fi). Look for `ex6150v2-vpn` in your router's device list and enter that IP. The PC must be on the same network (not on the extender's Wi-Fi during setup). |
| **No Wi-Fi network after flashing** | Expected: Wi-Fi stays off until setup on `:90`. |
| **Badge stays "Connecting…"** | Check the link: try the same link in V2Box or v2rayNG. Check `logread -e sing-box`. Look at "Ping to server": no reply means the server or port is blocked. |
| **`sing-box rejected config`** on Save | Unsupported link parameters. Supported security: `tls`, `reality`. Transports: `tcp`, `ws`, `httpupgrade`, `grpc`, `http`. |
| **Connected, but some sites don't load** | Rare MTU problems: run `uci set network.lan.mtu=1400; uci commit; reload_config`, or check the server. |
| **No internet at all on the Wi-Fi** | The kill switch is doing its job while the tunnel is down. Fix the link, or click **Stop VPN (Bypass)** to use the normal connection for now. |
| **Slow** | Use 5 GHz. Use a Vision inbound ([SERVER-3x-ui.md](SERVER-3x-ui.md)). Run `bench/streams.sh` to see whether the extender or the server is the limit. Keep the server's congestion control on cubic. |
| **SNI override: tunnel fails** | Your server must accept any SNI. Some CDNs and fronting setups reject unknown SNIs. Leave the override empty to test. |
| **Forgot the admin password** | Over SSH with your key: `rm /etc/sing-box/admin`, then open `:90` and run setup again (your link stays). Without SSH access, use failsafe mode: hold reset during boot, or see [RECOVERY.md](RECOVERY.md). |
| **LuCI login fails** | User `root` with the admin password. If you set the root password with `passwd` yourself, that password is the one LuCI accepts. |
| **Time is wrong / TLS errors after boot** | NTP uses Cloudflare by IP. Check that UDP 123 is not blocked by your network. |

## Reset everything

From SSH: `firstboot -y && reboot` (factory reset; the extender boots like a fresh flash). Or flash the sysupgrade image with `sysupgrade -n`.
