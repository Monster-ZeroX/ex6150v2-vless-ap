# Privacy: what an observer on your line can see

With the VPN on, someone watching the extender's uplink (your ISP, or anyone on the network between you and your server) sees:

| Visible | Details |
|---|---|
| Your VPN server's **IP address** and port | Unavoidable for any VPN |
| **One TLS hostname (SNI)** | The link's `sni`, or the **SNI override** you set on `:90` |
| One DoH connection to `1.1.1.1:443` | Resolving your server's name. No hostname in clear (IP-only TLS). |
| NTP to `162.159.200.1` / `.123` | Time sync by IP address |
| Traffic volume and timing | Unavoidable |

It does **not** see: DNS questions from your devices, the websites you visit, plain HTTP, or your server's real hostname (with an SNI override).

## SNI override: hide your server name from network observers

A TLS ClientHello carries the server name in clear. With an override, the extender sends a hostname of your choice instead, and verifies your server's certificate against its **real** name (public-key pinning, see [HOW-IT-WORKS.md](HOW-IT-WORKS.md)). Observers see only the override name. Your server must accept the connection whatever the SNI (Xray/3x-ui TLS inbounds do by default with a single certificate).

Choose a hostname that is plausible for your traffic pattern, and use it only where that is allowed.

## Checks that run automatically

- The kill switch blocks Wi-Fi devices from leaving outside the tunnel.
- Leak guards block the router itself from sending plaintext DNS (port 53) or HTTP (port 80) out of the WAN while the VPN is on.
- dnsmasq resolves only through the tunnel (`vpn-dns`).

## Check it yourself

On the extender (needs `tcpdump`: `apk add tcpdump`):

```bash
scp -O bench/isp-view.sh root@<extender>:/tmp/
ssh root@<extender> sh /tmp/isp-view.sh
```

It records the WAN during a VPN reconnect, some browsing, a download and a key-pin check, then lists every plaintext DNS question, TLS SNI, HTTP Host header and endpoint. Expected output: no DNS questions, your SNI only, no Host headers, your server's real name seen 0 times.

From a device on the VPN Wi-Fi: <https://ipinfo.io> shows your server's location, and a DNS leak test (for example dnsleaktest.com) shows only Cloudflare resolvers near your server.

IPv6 is not routed on the VPN Wi-Fi (no IPv6 address is handed out), so nothing leaks over IPv6.
