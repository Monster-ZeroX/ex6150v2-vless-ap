# Performance

The EX6150v2 has a Qualcomm IPQ4018: 4× Cortex-A7 at 717 MHz, NEON, **no AES or SHA instructions**, and 256 MB RAM. A VPN on it is CPU-bound: every byte is decrypted in software, and Wi-Fi transmit has no scatter-gather offload.

All numbers are download Mbps through the VPN. "Router-local" means `bench/streams.sh` on the extender; "phone" means a 5 GHz phone running a speed-test app.

## What made it fast

| Step | Effect |
|---|---|
| Lean image + minimal sing-box in squashfs (instead of the 73 MB official binary in RAM) | Stopped swap thrash. The base for everything else. |
| `auto_redirect` (nftables redirect for TCP) instead of the gVisor/system stack | ~33 → ~90 Mbps |
| ChaCha20-Poly1305 without uTLS (Go TLS picks ChaCha20 on CPUs without AES), instead of AES-GCM | ~2× vs AES-GCM |
| **ARM assembly ChaCha20** (Go overlay) | 19.5 → 35 MB/s per core |
| **26-bit-limb Poly1305 with ARM `UMLAL`** (Go overlay) | 17.7 → 57 MB/s per core |
| Combined AEAD (`cryptobench`) | **2.4×** |
| Wi-Fi (ath10k) IRQs on CPU1, away from Ethernet on CPU0 (`vpn-tune`) | Phone best of 3 placements: 107 down / 200 up |
| Ethernet threaded NAPI off | Stopped switch RX overflow drops under load |
| Bigger TCP buffers, no slow-start after idle (`sysctl`) | Steadier ramps |
| **Pipelined copy** in sing (reader goroutine + 4-deep FIFO for bulk copies after 512 KB) | 2 conns router-local 94 → 113 Mbps |
| **Vision** flow on the server | 2 conns 107 → 134–141 Mbps |

Result: phone speed-test apps above 100 Mbps; speedtest.net in a phone browser about 240 Mbps; a TV with many connections 250+ Mbps.

### Why upload is faster than download

Upload: the phone sends over Wi-Fi, and the extender receives, encrypts and sends on Ethernet, which has good offloads. Download: the extender decrypts and then must **transmit over Wi-Fi**. ath10k on this chip has no TX scatter-gather or GSO (`ethtool -k` shows `[fixed] off`), so every packet is copied and sent one by one on the CPU that also decrypts. Single-connection download is therefore lower than upload. More connections spread the work over more cores.

## LuCI cost

The LuCI dashboard on `:80` was measured before it was put back:

| | 2 conns | 3 conns | 4 conns |
|---|---|---|---|
| No LuCI | 117–119 | 154–159 | 160–164 |
| LuCI installed, idle | 114–115 | 160–165 | 163–164 |
| LuCI Status page open (polling) | 113–114 | 159 | 160 |

Within about 3 %, so it is on by default. Build with `LUCI=0` for the leanest image.

## Tried and rejected

| Idea | Result |
|---|---|
| **kTLS RX** (`kernel_rx`) | 117–130 Mbps, but **leaks kernel memory** (SUnreclaim grows until OOM) on Linux 6.6 and 6.12. Not used. |
| **BBR + fq** on the server | Slower: pacing reduces GRO merging on the CPU-bound client |
| Custom kernel with a 512-entry IPQESS RX ring | No gain, and it rebooted under 3-stream load |
| Ethernet pause frames | No clear gain |
| `taskset` sing-box off CPU0 | ~10 Mbps slower |
| `notrack` for server traffic | Breaks `auto_redirect` |
| Larger MTU on the tunnel | Helped only router-local tests, not real clients |
| uTLS Chrome fingerprint for TLS | Forces AES-GCM, so about half the speed |

## Measure it yourself

```bash
scp -O bench/streams.sh root@<extender>:/tmp/
ssh root@<extender> sh /tmp/streams.sh            # 1–4 connections, CPU, busiest threads
```

Use a large test file near your server as the argument for realistic numbers.
