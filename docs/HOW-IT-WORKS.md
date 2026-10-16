# How it works

## Network layout

| Interface | Role | Address |
|---|---|---|
| Ethernet port (`wan`) | Uplink to your home router | DHCP client. Firewall zone `wan`. |
| `br-lan` (both radios) | The VPN Wi-Fi | `192.168.2.1/24`, DHCP `.100–.250` |
| `tun0` | sing-box tunnel | `172.19.0.1/30`, firewall zone `vpn` |

The Wi-Fi network is routed, not bridged, to your home network. Its clients cannot reach the home LAN, and the home LAN sees only the extender. SSH (22), LuCI (80) and the VPN manager (90) are reachable from the `wan` side (your home network) and from the Wi-Fi.

## Traffic path

sing-box runs a `tun` inbound with **`auto_route` + `auto_redirect`**:

- **TCP** from Wi-Fi clients is redirected by nftables (`inet sing-box` table) to sing-box's redirect listener. There is no userspace TCP/IP stack, which is about 3× faster than plain tun mode on this CPU.
- **UDP** goes through `tun0` (`stack: system`).
- **DNS** queries are hijacked (`hijack-dns`) and answered by sing-box. The answer comes from `1.1.1.1` over TCP *through the VLESS tunnel*.
- **QUIC (UDP 443)** is rejected on purpose. Apps fall back to TCP, which is much faster here (TLS-over-TCP with Vision vs. UDP-in-TCP).
- Private ranges (`192.168.0.0/16` etc.) go direct.

`route_exclude_address` holds the VLESS server's IP addresses, so the tunnel's own connection never loops into itself.

## DNS without leaks

`auto_redirect` captures *client* traffic, but not packets the router sends itself. dnsmasq on the router would otherwise ask `1.1.1.1:53` in plaintext. So:

- `vpn-dns 1` sets dnsmasq `noresolv=1` and `server=172.19.0.2` (an address inside the tun subnet). Those queries enter the tunnel and are hijacked too.
- sing-box resolves the **server name** itself through **DoH** (`dns-direct`, `https://1.1.1.1`). `vpn-refresh` also resolves it over DoH (`sing-box resolve`), not with plaintext DNS.
- NTP uses Cloudflare's IP addresses (`162.159.200.1`, `.123`), so time sync needs no DNS lookup.
- Leak guards: firewall rules `vpn_leak_dns` (dest port 53 → wan: REJECT) and `vpn_leak_http` (dest port 80 → wan: REJECT). They are switched together with the kill switch.

## Kill switch

Firewall rule `vpn_killswitch` rejects forwarding from `lan` (Wi-Fi) to `wan`. Clients can only leave through the `vpn` zone. Start VPN turns it on, and Stop VPN (Bypass) turns it off together with the leak guards. If sing-box crashes or the server is down, Wi-Fi devices have no internet instead of leaking.

## TLS, SNI override and key pinning

`/etc/sing-box/sni.txt` (edited on `:90`) replaces the SNI from the link for `security=tls` links. Network observers then see that hostname in the ClientHello instead of your server's real name. Because the certificate is issued for the real name, a plain client would need `insecure`. This project uses a **public-key pin** instead:

1. `vpn-refresh` runs `sing-box pin <real-host> <port> <sni> <ip>`. It connects with the override SNI, checks the server's certificate chain against the **real** hostname with the system CA store, and prints the SHA-256 of its public key.
2. That pin goes into the config (`certificate_public_key_sha256`). Every later connection checks the server's key against it.
3. Only if the chain cannot be verified at all (for example a self-signed certificate) does it fall back to `insecure`, as V2Box and v2rayNG do with such links. The chosen mode is logged: `logread -e vpn-refresh`.

`vpn-refresh` runs at boot, after every link change, and every 6 hours from cron. It re-pins and re-resolves, and restarts sing-box only if something changed (for example a renewed certificate).

ChaCha20-Poly1305 is preferred and uTLS is not used for plain TLS. Go's TLS stack, with the ARM assembly overlay, is much faster than AES-GCM on this CPU, which has no AES instructions. Reality links keep uTLS, which Reality needs.

## Files on the router

| Path | Purpose |
|---|---|
| `/usr/bin/sing-box` | Minimal sing-box build (`run`, `check`, `version`, `pin`, `resolve`) |
| `/etc/init.d/sing-box` | procd service: `GOMEMLIMIT=48MiB`, respawn |
| `/usr/libexec/sing-box-start` | Waits for WAN and runs `vpn-refresh` (up to 30 tries), then starts sing-box |
| `/usr/libexec/vless2json` | awk: `vless://` link to full sing-box config |
| `/usr/libexec/vpn-refresh` | DoH resolve, key pin, route excludes; `--restart` on change |
| `/usr/libexec/vpn-dns` | Points dnsmasq at the tunnel (`1`) or back to normal (`0`) |
| `/etc/init.d/vpn-tune` | ath10k IRQs to CPU1, Ethernet threaded NAPI off |
| `/etc/sysctl.d/90-vpn-fast.conf` | Bigger TCP buffers, no slow-start after idle |
| `/etc/uci-defaults/90-vless-ap` | First boot and upgrade migration |
| `/www-vpn/` | `:90` manager (`index.html`, `cgi-bin/vpn`) |
| `/etc/sing-box/` | **Your settings** (kept across upgrades): `link.txt`, `sni.txt`, `admin`, `config.json` |

## The `:90` API

All POSTs need `Content-Type: application/json`, so a browser on another site cannot send them without a CORS preflight. The session cookie is `HttpOnly; SameSite=Strict`.

| Request | Auth | Body |
|---|---|---|
| `GET ?action=status` | none | Public: `app`, `setup_required`, `authed`, `configured`, `running`, `tunnel`, `enabled`. Adds `server`, `link`, `sni_override`, `wifi_ssid` and `mem_free_mb` when logged in. |
| `POST ?action=setup` | only before setup | `password`, optional `wifi_ssid`, `wifi_key`, `link`, `sni`, `ssh_key` |
| `POST ?action=login` | none | `password` (sets the cookie) |
| `POST ?action=logout` | cookie | — |
| `POST ?action=save` | cookie | `link` |
| `POST ?action=sni` | cookie | `sni` (empty = from link) |
| `POST ?action=wifi` | cookie | `ssid`, `key` |
| `POST ?action=password` | cookie | `password` (also sets root's) |
| `POST ?action=start` / `stop` / `restart` | cookie | — |
| `GET ?action=ipinfo` / `ping` | cookie | — |

The admin password is stored as `salt:sha256(salt+password)` in `/etc/sing-box/admin`. The same password is set for `root`, which LuCI and SSH use.
