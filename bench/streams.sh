#!/bin/sh
# Run ON THE EXTENDER: download throughput through the VPN with 1-4 parallel connections,
# total CPU use, and the busiest sing-box threads.
#   scp -O bench/streams.sh root@<extender>:/tmp/ && ssh root@<extender> sh /tmp/streams.sh [url]
# Pick a large test file near your VPN server (the default is Cloudflare's speed test).
U=${1:-https://speed.cloudflare.com/__down?bytes=1000000000}
T=12
. /lib/functions/network.sh
network_get_device DEV wan               # encrypted bytes arriving on the Ethernet port
rx() { cat /sys/class/net/$DEV/statistics/rx_bytes; }
cpu() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }
thr() { P=$(pidof sing-box); for t in /proc/$P/task/*; do awk '{print $1, $14 + $15}' $t/stat 2>/dev/null; done; }
HZ=100
pidof sing-box >/dev/null || { echo "sing-box is not running"; exit 1; }
for n in 1 2 3 4; do
	i=0 pids=
	while [ $i -lt $n ]; do uclient-fetch -q -O /dev/null "$U" 2>/dev/null & pids="$pids $!"; i=$((i + 1)); done
	sleep 3
	b0=$(rx); c0=$(cpu); thr > /tmp/th.a
	sleep $T
	b1=$(rx); c1=$(cpu); thr > /tmp/th.b
	kill $pids 2>/dev/null; wait $pids 2>/dev/null; sleep 3
	top3=$(awk -v t=$T -v hz=$HZ 'NR==FNR {a[$1]=$2; next} ($1 in a) {printf "%d\n", ($2-a[$1])*100/(t*hz)}' /tmp/th.a /tmp/th.b | sort -rn | head -3 | tr '\n' ' ')
	echo "$n conn: $(echo "$b0 $b1" | awk -v t=$T '{printf "%5.1f", ($2-$1)*8/t/1e6}') Mbps | total cpu $(echo "$c0 $c1" | awk '{printf "%d%%", 100*($3-$1)/(($3-$1)+($4-$2))}') | busiest sing-box threads (% of one core): $top3"
done
rm -f /tmp/th.a /tmp/th.b
