#!/usr/bin/env bash
# netdrop_probe.sh — sample rx_dropped & stack stats into one log
# Usage:
#   sudo ./netdrop_probe.sh                # 自動挑實體 NIC，180s 取樣
#   sudo IFACES="ens12f0np0 ens1f0np0" DURATION=300 INTERVAL=1 ./netdrop_probe.sh
#
# 產物：./netdiag_${HOSTNAME}_YYYYmmddTHHMMSS.log

set -euo pipefail

# 可用環境變數覆寫
DURATION="${DURATION:-180}"   # 總秒數
INTERVAL="${INTERVAL:-1}"     # 取樣間隔秒
OUT="netdiag_$(hostname)_$(date +%Y%m%dT%H%M%S).log"

ts() { date -Iseconds; }

# 自動挑實體 NIC（排除 lo/docker/veth/br/tun/tap/flannel/cali/kube 等）
if [[ -z "${IFACES:-}" ]]; then
  mapfile -t IFACE_LIST < <(
    ls /sys/class/net | grep -Ev '^(lo|docker.*|veth.*|br-.*|cni.*|flannel.*|cali.*|tun.*|tap.*|kube.*|virbr.*)$'
  )
else
  read -r -a IFACE_LIST <<< "${IFACES}"
fi
[[ "${#IFACE_LIST[@]}" -eq 0 ]] && { echo "No candidate interfaces"; exit 1; }

# 小工具存在就用，沒有也不中斷
has() { command -v "$1" >/dev/null 2>&1; }

# ---- Header / 靜態環境資訊 ----
{
  echo "==== NETDROP PROBE BEGIN $(ts) ===="
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo "Kernel: $(uname -a)"
  echo "Uptime: $(uptime || true)"
  echo "OS:"
  [[ -r /etc/os-release ]] && sed 's/^/  /' /etc/os-release || true
  echo

  echo "Selected IFACES: ${IFACE_LIST[*]}"
  echo

  for IF in "${IFACE_LIST[@]}"; do
    echo "---- IFACE $IF link/info ($(ts)) ----"
    ip addr show dev "$IF" || true
    ip link show dev "$IF" | sed 's/^/  /' || true
    if has ethtool; then
      echo "-- ethtool -i $IF"
      ethtool -i "$IF" 2>/dev/null || true
      echo "-- ethtool $IF (speed/duplex/link)"
      ethtool "$IF" 2>/dev/null | egrep 'Speed:|Duplex:|Link detected:' || true
      echo "-- ethtool -a $IF (flow control)"
      ethtool -a "$IF" 2>/dev/null || true
      echo "-- ethtool -g $IF (ring)"
      ethtool -g "$IF" 2>/dev/null || true
      echo "-- ethtool -l $IF (channels)"
      ethtool -l "$IF" 2>/dev/null || true
    fi
    echo
  done

  echo "---- /proc/interrupts (prefetch) ----"
  sed -n '1,20p' /proc/interrupts || true
  for IF in "${IFACE_LIST[@]}"; do
    echo "-- interrupts lines containing $IF"
    grep -i "$IF" /proc/interrupts || echo "  (no direct IRQ label for $IF)"
  done
  echo

  echo "---- nstat -az (prefetch) ----"
  has nstat && nstat -az || echo "(nstat not found)"
  echo
} | tee -a "$OUT"

# ---- 動態取樣：每秒抓一次計數器 ----
echo "==== SAMPLING $(ts) duration=${DURATION}s interval=${INTERVAL}s ====" | tee -a "$OUT"
echo "timestamp iface rx_pkts rx_drop tx_pkts tx_drop softnet_drops" | tee -a "$OUT"

for ((t=0; t< DURATION; t+=INTERVAL)); do
  # sum softnet drops across CPUs
  SOFTDROP=$(awk '{d+=strtonum("0x"$2)} END{print d+0}' /proc/net/softnet_stat 2>/dev/null || echo 0)

  for IF in "${IFACE_LIST[@]}"; do
    RX_PKTS=$(<"/sys/class/net/$IF/statistics/rx_packets")
    RX_DROP=$(<"/sys/class/net/$IF/statistics/rx_dropped")
    TX_PKTS=$(<"/sys/class/net/$IF/statistics/tx_packets")
    TX_DROP=$(<"/sys/class/net/$IF/statistics/tx_dropped")
    echo "$(ts) $IF $RX_PKTS $RX_DROP $TX_PKTS $TX_DROP $SOFTDROP" | tee -a "$OUT"
  done

  # 每 10 秒做一次深度快照（不阻塞）
  if (( (t % 10) == 0 )); then
    {
      echo
      echo "---- SNAPSHOT $(ts) ----"
      echo "-- /proc/softirqs (NET_RX rows)"
      sed -n '1p;/NET_RX/p' /proc/softirqs || true
      echo "-- /proc/interrupts (NIC related)"
      for IF in "${IFACE_LIST[@]}"; do
        echo "## IRQ for $IF"
        grep -i "$IF" /proc/interrupts || echo "  (no direct IRQ label for $IF)"
      done
      echo "-- ip -s link (per iface)"
      for IF in "${IFACE_LIST[@]}"; do
        echo "## ip -s link show dev $IF"
        ip -s link show dev "$IF" || true
      done
      if has ethtool; then
        for IF in "${IFACE_LIST[@]}"; do
          echo "## ethtool -S $IF (filtered)"
          ethtool -S "$IF" 2>/dev/null | grep -iE 'drop|discard|miss|error|buf|fifo|queue' || echo "  (no counters or no permission)"
        done
      fi
      echo "-- qdisc stats (if tc present)"
      if has tc; then
        for IF in "${IFACE_LIST[@]}"; do
          echo "## tc -s qdisc show dev $IF"
          tc -s qdisc show dev "$IF" || true
        done
      fi
      echo "-- nstat -az (stack layer)"
      has nstat && nstat -az | egrep 'IpInDiscards|IpInHdrErrors|IpInDelivers|TcpInErrs|UdpInErrors|TcpExtListenDrops|TcpExtTCPAbortOn' || true
      echo
    } | tee -a "$OUT" >/dev/null
  fi

  sleep "$INTERVAL"
done

# ---- 結束快照 ----
{
  echo
  echo "==== FINAL SNAPSHOTS $(ts) ===="
  echo "-- /proc/interrupts (tail)"
  sed -n '1,20p' /proc/interrupts || true
  for IF in "${IFACE_LIST[@]}"; do
    echo "## IRQ for $IF"
    grep -i "$IF" /proc/interrupts || echo "  (no direct IRQ label for $IF)"
  done
  echo "-- nstat -az (final)"
  has nstat && nstat -az || true
  echo
  echo "==== NETDROP PROBE END $(ts) ===="
} | tee -a "$OUT"

echo "Saved log: $OUT"
