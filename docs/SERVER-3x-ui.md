# Server setup (3x-ui / Xray)

Any VLESS server works. The fastest setup for this extender is **VLESS + TCP + TLS + Vision** (`flow=xtls-rprx-vision`). Vision skips the second encryption layer for TLS traffic inside the tunnel, so the extender's CPU does about half the crypto work. Measured on this device:

| Inbound | 2 connections | 4 connections |
|---|---|---|
| VLESS + WebSocket + TLS | 107 Mbps | ~160 Mbps |
| VLESS + TCP + TLS + **Vision** | **134–141 Mbps** | ~165 Mbps |

Phone speed-test apps use about 2 connections, so Vision is the change you notice.

## Add a Vision inbound in 3x-ui

You can keep your existing inbound (for example WebSocket on 443) and add a second one on another port. These steps use 444 and reuse the certificate you already have.

1. **Inbounds → Add Inbound**:
   - Protocol `vless`, Port `444`, Transmission **TCP (RAW)**, *no* header obfuscation.
   - Security **TLS**: min version `1.3`, ALPN `http/1.1`, and your certificate (*Path* of fullchain and private key, the same files as the existing inbound).
   - Client: set **Flow** to `xtls-rprx-vision`.
2. Open port 444/tcp in your VPS firewall (`ufw allow 444/tcp`, plus your cloud provider's firewall if it has one).
3. Copy the client's link. It looks like:

```
vless://<uuid>@your.server.name:444?security=tls&type=tcp&flow=xtls-rprx-vision&sni=your.server.name#Vision
```

Paste it on the extender's `:90` page. If you use an SNI override, leave the link's `sni` as it is and set the override in the SNI card.

Equivalent Xray inbound JSON, for reference:

```json
{
  "port": 444, "protocol": "vless",
  "settings": { "clients": [ { "id": "<uuid>", "flow": "xtls-rprx-vision", "email": "router" } ], "decryption": "none" },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "minVersion": "1.3", "alpn": ["http/1.1"],
      "certificates": [ { "certificateFile": "/root/cert/your.server.name/fullchain.pem", "keyFile": "/root/cert/your.server.name/privkey.pem" } ]
    }
  }
}
```

## Server tuning: keep it simple

- **Don't switch to BBR + fq** for this client. Pacing spreads packets out, and the CPU-bound extender then merges fewer of them (GRO), so downloads got slower in our tests. Cubic with the default qdisc was faster.
- Use a VPS near you (low RTT). The ceiling here is the extender's CPU, not server bandwidth.
- ChaCha20-Poly1305 is negotiated automatically: the extender prefers it and has no AES instructions.

## Reality

`security=reality` links work too (uTLS fingerprint required by Reality). Reality uses the AES-GCM path, so expect lower throughput than TLS + Vision with ChaCha20 on this CPU.
