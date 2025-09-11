#!/usr/bin/env bash
# Usage:
#   sudo ./shape.sh set <iface> <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1] [--env noisy|noiseless]
#   sudo ./shape.sh clear <iface>
#

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  sudo $0 set <iface> <bw_mbps> <rtt_ms> [jitter_ms=3] [loss_pct=0.1] [--env noisy|noiseless]"
  echo "  sudo $0 clear <iface>"
  exit 1
}

cmd=${1:-}
iface=${2:-}
[[ -z "${cmd}" || -z "${iface}" ]] && usage

if [[ "$cmd" == "clear" ]]; then
  tc qdisc del dev "$iface" root 2>/dev/null || true
  echo "Cleared qdisc on $iface"
  exit 0
fi

[[ "$cmd" != "set" ]] && usage


argc=$#
provided_jitter=0
provided_loss=0
(( argc >= 5 )) && provided_jitter=1
(( argc >= 6 )) && provided_loss=1

bw=${3:?bw_mbps}
rtt=${4:?rtt_ms}
jitter=${5:-3}
loss=${6:-0.1}

# Parse --env (supports --env noiseless / --env noisy or --env=noiseless )
env_mode=""
if (( argc >= 7 )); then
  shift 6
  while (( $# > 0 )); do
    case "$1" in
      --env)
        env_mode=${2:-}; shift 2 ;;
      --env=*)
        env_mode="${1#--env=}"; shift 1 ;;
      *)
        echo "[WARN] Unknown arg: $1" >&2
        shift 1 ;;
    esac
  done
fi

# Set the default when jitter/loss is not explicitly provided by the user according to env_mode
if [[ -n "$env_mode" ]]; then
  case "$env_mode" in
    noiseless)
      if (( provided_jitter == 0 )); then jitter=0; fi
      if (( provided_loss   == 0 )); then loss=0; fi
      echo "[INFO] env=noiseless -> jitter=${jitter}ms loss=${loss}%"
      ;;
    noisy)
      if (( provided_jitter == 0 )); then jitter=3; fi
      if (( provided_loss   == 0 )); then loss=0.1; fi
      echo "[INFO] env=noisy -> jitter=${jitter}ms loss=${loss}%"
      ;;
    *)
      echo "[ERR] unknown env: $env_mode (use: noisy|noiseless)"; exit 1 ;;
  esac
fi
# Send qdisc
tc qdisc replace dev "$iface" root handle 1: netem delay "${rtt}ms" "${jitter}ms" loss "${loss}%"
tc qdisc replace dev "$iface" parent 1: handle 10: tbf rate "${bw}mbit" burst 64kbit latency 300ms

echo "[OK] iface=$iface bw=${bw}Mbit rtt=${rtt}ms jitter=${jitter}ms loss=${loss}%"
tc qdisc show dev "$iface"
