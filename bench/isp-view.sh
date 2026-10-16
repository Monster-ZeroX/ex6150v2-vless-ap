#!/bin/sh
# Run ON THE EXTENDER: record the WAN while the VPN reconnects and carries typical traffic,
# then list everything an observer on your line (e.g. the ISP) can see: DNS questions, TLS SNIs,
# plain HTTP Host headers, and the endpoints contacted. Needs tcpdump (apk add tcpdump).
#   scp -O bench/isp-view.sh root@<extender>:/tmp/ && ssh root@<extender> sh /tmp/isp-view.sh
command -v tcpdump >/dev/null || { echo "install tcpdump first: apk add tcpdump"; exit 1; }
. /lib/functions/network.sh
network_get_device WAN wan
network_get_ipaddr WANIP wan
ME=${SSH_CLIENT%% *}                      # leave your own SSH session out of the capture
REAL=$(sed -n 's#^vless://[^@]*@\([^:/?]*\).*#\1#p' /etc/sing-box/link.txt)
P=/tmp/isp.pcap
tcpdump -i $WAN -nn -s 800 -w $P "not arp${ME:+ and not host $ME}" 2>/dev/null &
TD=$!
sleep 2
/etc/init.d/sing-box restart            # a reconnect, as at boot or after Save & Connect
n=0; until [ -d /sys/class/net/tun0 ] || [ $n -gt 30 ]; do sleep 1; n=$((n + 1)); done; sleep 3
for h in www.wikipedia.org www.youtube.com github.com example.com; do
	nslookup -timeout=3 $h 192.168.2.1 >/dev/null 2>&1      # what Wi-Fi devices ask
	uclient-fetch -q -T 8 -O /dev/null https://$h/ 2>/dev/null
done
uclient-fetch -q -O /dev/null 'https://speed.cloudflare.com/__down?bytes=200000000' & F=$!
sleep 10; kill $F 2>/dev/null
/usr/libexec/vpn-refresh >/dev/null     # the periodic server check
sleep 2; kill $TD; wait $TD 2>/dev/null

echo "packets captured: $(tcpdump -nn -r $P 2>/dev/null | wc -l)"
echo "plaintext DNS questions (should be none):"
tcpdump -nn -r $P 'port 53' 2>/dev/null | grep -oE '(A|AAAA|HTTPS|PTR)\? [^ ]+' | sort | uniq -c | sed 's/^/  /'
echo "TLS SNIs in clear (should only be your SNI):"
tcpdump -nn -r $P -A 'tcp[((tcp[12] & 0xf0) >> 2)] = 0x16 and tcp[((tcp[12] & 0xf0) >> 2) + 5] = 1' 2>/dev/null | grep -aoE '([a-z0-9][a-z0-9-]+\.)+[a-z]{2,10}' | sort | uniq -c | sed 's/^/  /'
echo "plain HTTP Host headers (should be none):"
tcpdump -nn -r $P -A 'tcp dst port 80' 2>/dev/null | grep -aoE 'Host: [^ ]+' | sort | uniq -c | sed 's/^/  /'
[ -n "$REAL" ] && echo "real server name '$REAL' seen in clear: $(tcpdump -nn -r $P -A 2>/dev/null | grep -acF "$REAL") packets (should be 0)"
echo "endpoints contacted (new TCP connections / UDP flows):"
tcpdump -nn -r $P 'tcp[13] & 2 != 0 and tcp[13] & 16 == 0' 2>/dev/null | awk '{print "  tcp " $5}' | sed 's/\.\([0-9]*\):$/:\1/' | sort | uniq -c
tcpdump -nn -r $P "udp and src host $WANIP" 2>/dev/null | awk '{print "  udp " $5}' | sed 's/\.\([0-9]*\):$/:\1/' | sort | uniq -c
rm -f $P
