#!/usr/bin/env bash
# Usage：sudo ./shape.sh set <iface> <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1]
#       sudo ./shape.sh clear <iface>
set -euo pipefail

cmd=${1:?set|clear}
iface=${2:?iface}

if [[ "$cmd" == "clear" ]]; then
  tc qdisc del dev "$iface" root 2>/dev/null || true
  echo "Cleared qdisc on $iface"
  exit 0
fi

bw=${3:?bw_mbps}
rtt=${4:?rtt_ms}
jitter=${5:-3}
loss=${6:-0.1}

# root hang netem (latency/jitter/packet loss), subqueue tbf (rate limit)
tc qdisc replace dev "$iface" root handle 1: netem delay ${rtt}ms ${jitter}ms loss ${loss}%
tc qdisc replace dev "$iface" parent 1: handle 10: tbf rate ${bw}mbit burst 64kbit latency 300ms

tc qdisc show dev "$iface"
