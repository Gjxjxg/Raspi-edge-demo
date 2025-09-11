#!/usr/bin/env bash
set -euo pipefail

# Namespaces & veth
NS_DEV="ns_dev"
NS_BRK="ns_broker"
NS_EDGE="ns_edge"

VETH_DB_A="veth_dev_a"   # dev <-> brk
VETH_DB_B="veth_brk_a"
VETH_BE_A="veth_brk_b"   # brk <-> edge
VETH_BE_B="veth_edge_b"

# IPs
DEV_IP="10.10.0.2/24"
BRK_DB_IP="10.10.0.1/24"
BRK_BE_IP="10.20.0.1/24"
EDGE_IP="10.20.0.2/24"

usage() {
cat <<'EOF'
Usage:
  sudo ./netem_param.sh up
  sudo ./netem_param.sh down
  sudo ./netem_param.sh status
  sudo ./netem_param.sh clear-qdisc

  # Parameterized settings (defaults: small jitter & tiny loss; override if needed)
  # 1) Set device <-> broker (both directions)
  sudo ./netem_param.sh set-db <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1]
  # 2) Set broker <-> edge (both directions)
  sudo ./netem_param.sh set-be <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1]
  # 3) Per-interface (for asymmetric conditions)
  sudo ./netem_param.sh set-if <ns> <ifname> <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1]

  # Background noise traffic (optional)
  sudo ./netem_param.sh noise-start <link>{db|be} <proto>{tcp|udp} <rate_mbps>
  sudo ./netem_param.sh noise-stop

  # Helpers
  sudo ./netem_param.sh mtu <ifname> <mtu>
  sudo ./netem_param.sh tcp-cc <algo>{cubic|bbr|...}

Notes:
- set-db applies to both ends of the device<->broker link: veth_dev_a and veth_brk_a (so both directions are shaped).
- set-be applies to both ends of the broker<->edge link: veth_brk_b and veth_edge_b.
- set-if shapes only the egress of the specified interface (useful for asymmetric paths).
- Suggested workflow: up → set-* → run your apps. When switching conditions, consider clear-qdisc → set-*.

EOF
}

ensure_ns() {
  ip netns list | grep -q "^${1}\b" || ip netns add "$1"
}

link_add() {
  ip link add ${VETH_DB_A} type veth peer name ${VETH_DB_B}
  ip link add ${VETH_BE_A} type veth peer name ${VETH_BE_B}
  ip link set ${VETH_DB_A} netns ${NS_DEV}
  ip link set ${VETH_DB_B} netns ${NS_BRK}
  ip link set ${VETH_BE_A} netns ${NS_BRK}
  ip link set ${VETH_BE_B} netns ${NS_EDGE}
}

addr_up() {
  for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do ip netns exec $ns ip link set lo up; done
  ip netns exec ${NS_DEV}   ip addr add ${DEV_IP}    dev ${VETH_DB_A}
  ip netns exec ${NS_BRK}   ip addr add ${BRK_DB_IP} dev ${VETH_DB_B}
  ip netns exec ${NS_BRK}   ip addr add ${BRK_BE_IP} dev ${VETH_BE_A}
  ip netns exec ${NS_EDGE}  ip addr add ${EDGE_IP}   dev ${VETH_BE_B}
  ip netns exec ${NS_DEV}   ip link set ${VETH_DB_A} up
  ip netns exec ${NS_BRK}   ip link set ${VETH_DB_B} up
  ip netns exec ${NS_BRK}   ip link set ${VETH_BE_A} up
  ip netns exec ${NS_EDGE}  ip link set ${VETH_BE_B} up
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

show_status() {
  for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do
    echo "=== $ns ==="
    ip netns exec $ns ip -br addr
    ip netns exec $ns tc qdisc show || true
    echo
  done
}

clear_qdisc_all() {
  for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do
    for ifc in $(ip netns exec "$ns" ip -o link show \
                  | awk -F': ' '{print $2}' \
                  | cut -d'@' -f1 \
                  | grep -v '^lo$'); do
      ip netns exec "$ns" tc qdisc del dev "$ifc" root 2>/dev/null || true
    done
  done
}


# Core: First root netem (handle 1:), then use tbf as a child queue (parent 1:)
apply_netem_tbf() {
  local ns=$1 ifc=$2 bw_mbps=$3 rtt_ms=$4 jitter_ms=${5:-3} loss_pct=${6:-0.1}
  local rate="${bw_mbps}mbit"
  local delay="${rtt_ms}ms ${jitter_ms}ms"
  # netem: RTT and small jitter/small packet loss
  ip netns exec $ns tc qdisc replace dev $ifc root handle 1: netem delay $delay loss ${loss_pct}%
  # tbf: bandwidth and queue (burst and queue delay limits can be adjusted on demand)
  ip netns exec $ns tc qdisc replace dev $ifc parent 1: handle 10: tbf rate $rate burst 64kbit latency 300ms
}

set_pair() {
  # Set the same settings for both the left and right interfaces of a link (consistent in both directions)
  local if1_ns=$1 if1=$2 if2_ns=$3 if2=$4 bw=$5 rtt=$6 jitter=${7:-3} loss=${8:-0.1}
  apply_netem_tbf $if1_ns $if1 $bw $rtt $jitter $loss
  apply_netem_tbf $if2_ns $if2 $bw $rtt $jitter $loss
}

noise_start() {
  local link=$1 proto=$2 rate=$3
 # First stop any iperf3 that may be running
  for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do ip netns exec $ns pkill -f "iperf3" 2>/dev/null || true; done
  case "$link" in
    db)
      ip netns exec ${NS_BRK} bash -lc "nohup iperf3 -s >/dev/null 2>&1 &"; sleep 0.2
      if [[ "$proto" == "udp" ]]; then
        ip netns exec ${NS_DEV}  bash -lc "nohup iperf3 -u -b ${rate}M -c 10.10.0.1 >/dev/null 2>&1 &"
      else
        ip netns exec ${NS_DEV}  bash -lc "nohup iperf3 -c 10.10.0.1 >/dev/null 2>&1 &"
      fi
      ;;
    be)
      ip netns exec ${NS_EDGE} bash -lc "nohup iperf3 -s >/dev/null 2>&1 &"; sleep 0.2
      if [[ "$proto" == "udp" ]]; then
        ip netns exec ${NS_BRK} bash -lc "nohup iperf3 -u -b ${rate}M -c 10.20.0.2 >/dev/null 2>&1 &"
      else
        ip netns exec ${NS_BRK} bash -lc "nohup iperf3 -c 10.20.0.2 >/dev/null 2>&1 &"
      fi
      ;;
    *) echo "link must be db or be"; exit 1;;
  esac
  echo "Noise started on $link ($proto, target ${rate}Mbps)."
}

case "${1:-}" in
  up)
    ensure_ns ${NS_DEV}; ensure_ns ${NS_BRK}; ensure_ns ${NS_EDGE}
    link_add; addr_up; show_status
    ;;
  down)
    for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do ip netns del $ns 2>/dev/null || true; done
    # If the remaining veth is still on the host, delete it as well
    ip link del ${VETH_DB_A} 2>/dev/null || true
    ip link del ${VETH_DB_B} 2>/dev/null || true
    ip link del ${VETH_BE_A} 2>/dev/null || true
    ip link del ${VETH_BE_B} 2>/dev/null || true
    echo "All cleaned."
    ;;
  status) show_status ;;
  clear-qdisc) clear_qdisc_all ;;
  set-db)
    bw=${2:?bw_mbps}; rtt=${3:?rtt_ms}; jitter=${4:-3}; loss=${5:-0.1}
    set_pair ${NS_DEV} ${VETH_DB_A} ${NS_BRK} ${VETH_DB_B} $bw $rtt $jitter $loss
    show_status
    ;;
  set-be)
    bw=${2:?bw_mbps}; rtt=${3:?rtt_ms}; jitter=${4:-3}; loss=${5:-0.1}
    set_pair ${NS_BRK} ${VETH_BE_A} ${NS_EDGE} ${VETH_BE_B} $bw $rtt $jitter $loss
    show_status
    ;;
  set-if)
    ns=${2:?ns}; ifc=${3:?ifname}; bw=${4:?bw_mbps}; rtt=${5:?rtt_ms}; jitter=${6:-3}; loss=${7:-0.1}
    apply_netem_tbf $ns $ifc $bw $rtt $jitter $loss
    show_status
    ;;
  noise-start)
    noise_start ${2:?db|be} ${3:?tcp|udp} ${4:?rate_mbps}
    ;;
  noise-stop)
    for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do ip netns exec $ns pkill -f "iperf3" 2>/dev/null || true; done
    echo "Noise stopped."
    ;;
  mtu)
    ifc=${2:?ifname}; mtu=${3:?mtu}
    for ns in ${NS_DEV} ${NS_BRK} ${NS_EDGE}; do
      if ip netns exec $ns ip link show $ifc >/dev/null 2>&1; then
        ip netns exec $ns ip link set $ifc mtu $mtu
        echo "Set MTU $mtu on $ns:$ifc"; exit 0
      fi
    done
    echo "Interface $ifc not found in namespaces"; exit 1
    ;;
  tcp-cc)
    algo=${2:-cubic}; sysctl -w net.ipv4.tcp_congestion_control=$algo
    ;;
  *) usage; exit 1 ;;
esac
