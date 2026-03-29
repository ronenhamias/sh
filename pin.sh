#!/usr/bin/env bash

set -euo pipefail

#
# isolate.sh
#
# Graviton/ARM64-friendly NIC IRQ/RPS/XPS isolation helper
#
# What it does:
# - validates CPU sets against the current host
# - computes CPU masks dynamically
# - disables irqbalance
# - pins NIC IRQs to NIC_CPUS
# - configures RPS/XPS for all queues on the NIC
# - stores previous values for rollback
# - supports --dry-run and --restore
#
# What it does NOT do:
# - kernel boot isolation (isolcpus/nohz_full/rcu_nocbs)
# - process pinning for Java/Aeron
#

OS_CPUS="${OS_CPUS:-0-4}"
GENERIC_CPUS="${GENERIC_CPUS:-5-6}"
NIC_CPUS="${NIC_CPUS:-7-8}"
AERON_CPUS="${AERON_CPUS:-9-13}"
DEV="${DEV:-ens5}"
RPS_FLOW_CNT="${RPS_FLOW_CNT:-4096}"
STATE_DIR="${STATE_DIR:-/var/tmp/isolate-state}"
DRY_RUN=0
RESTORE_FILE=""

usage() {
  cat <<EOF
Usage:
  sudo DEV=ens5 $0
  sudo DEV=ens5 NIC_CPUS=7-8 AERON_CPUS=9-13 $0
  sudo $0 --dry-run
  sudo $0 --restore /var/tmp/isolate-state/ens5-YYYYMMDDHHMMSS.state

Environment:
  DEV            NIC device name, default: ens5
  OS_CPUS        housekeeping CPUs, default: 0-4
  GENERIC_CPUS   generic JVM/helper CPUs, default: 5-6
  NIC_CPUS       NIC IRQ/RPS/XPS CPUs, default: 7-8
  AERON_CPUS     Aeron CPUs, default: 9-13
  RPS_FLOW_CNT   per RX queue rps_flow_cnt, default: 4096
  STATE_DIR      rollback state dir, default: /var/tmp/isolate-state
EOF
}

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

write_value() {
  local value="$1"
  local file="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] echo '$value' > '$file'"
  else
    printf '%s' "$value" > "$file"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --restore)
        [[ $# -ge 2 ]] || die "--restore requires a file path"
        RESTORE_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

require_nic() {
  [[ -d "/sys/class/net/$DEV" ]] || {
    ip link || true
    die "NIC $DEV not found"
  }
}

expand_cpu_list() {
  local input="$1"
  local result=()
  local part start end i

  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${part%-*}"
      end="${part#*-}"
      (( start <= end )) || die "Invalid CPU range: $part"
      for ((i=start; i<=end; i++)); do
        result+=("$i")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      result+=("$part")
    else
      die "Invalid CPU list token: $part"
    fi
  done

  printf '%s\n' "${result[@]}" | awk '!seen[$0]++'
}

max_online_cpu() {
  local cpus
  cpus="$(getconf _NPROCESSORS_ONLN)"
  (( cpus > 0 )) || die "Failed to detect online CPUs"
  echo $((cpus - 1))
}

validate_cpu_list() {
  local name="$1"
  local list="$2"
  local max_cpu
  max_cpu="$(max_online_cpu)"

  while IFS= read -r cpu; do
    [[ "$cpu" =~ ^[0-9]+$ ]] || die "$name contains invalid CPU: $cpu"
    (( cpu >= 0 && cpu <= max_cpu )) || die "$name CPU $cpu is outside online CPU range 0-$max_cpu"
    [[ -d "/sys/devices/system/cpu/cpu${cpu}" ]] || die "$name CPU $cpu not present in sysfs"
    if [[ -f "/sys/devices/system/cpu/cpu${cpu}/online" ]]; then
      [[ "$(cat "/sys/devices/system/cpu/cpu${cpu}/online")" == "1" ]] || die "$name CPU $cpu is offline"
    fi
  done < <(expand_cpu_list "$list")
}

check_overlap() {
  local name_a="$1"
  local list_a="$2"
  local name_b="$3"
  local list_b="$4"

  local overlap
  overlap="$(
    comm -12 \
      <(expand_cpu_list "$list_a" | sort -n) \
      <(expand_cpu_list "$list_b" | sort -n)
  )"

  if [[ -n "$overlap" ]]; then
    die "CPU sets overlap: $name_a and $name_b share CPUs: $(echo "$overlap" | xargs)"
  fi
}

cpu_list_to_hex_mask() {
  local list="$1"
  local -a cpus=()
  local cpu
  local -a words=(0)

  while IFS= read -r cpu; do
    cpus+=("$cpu")
  done < <(expand_cpu_list "$list")

  for cpu in "${cpus[@]}"; do
    local word_index=$((cpu / 32))
    local bit_index=$((cpu % 32))
    while (( ${#words[@]} <= word_index )); do
      words+=(0)
    done
    words[$word_index]=$(( words[$word_index] | (1 << bit_index) ))
  done

  local out=""
  local i
  for ((i=${#words[@]}-1; i>=0; i--)); do
    if [[ -z "$out" ]]; then
      out="$(printf '%x' "${words[$i]}")"
    else
      out="${out},$(printf '%08x' "${words[$i]}")"
    fi
  done

  echo "$out"
}

get_nic_irqs() {
  awk -v dev="$DEV" '
    $0 ~ dev {
      gsub(":", "", $1)
      gsub(/[[:space:]]/, "", $1)
      print $1
    }
  ' /proc/interrupts
}

get_nic_numa_node() {
  local f="/sys/class/net/$DEV/device/numa_node"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "-1"
  fi
}

get_cpu_numa_node() {
  local cpu="$1"
  local node
  node="$(find "/sys/devices/system/cpu/cpu${cpu}" -maxdepth 1 -type l -name 'node*' 2>/dev/null | sed 's#.*/node##' | head -n1 || true)"
  if [[ -n "$node" ]]; then
    echo "$node"
  else
    echo "-1"
  fi
}

check_numa_alignment() {
  local nic_node first_cpu cpu_node
  nic_node="$(get_nic_numa_node)"
  first_cpu="$(expand_cpu_list "$NIC_CPUS" | head -n1)"
  cpu_node="$(get_cpu_numa_node "$first_cpu")"

  if [[ "$nic_node" == "-1" || "$cpu_node" == "-1" ]]; then
    warn "NUMA information unavailable or not exposed. Skipping NUMA alignment check."
    return
  fi

  if [[ "$nic_node" != "$cpu_node" ]]; then
    warn "NIC $DEV is on NUMA node $nic_node but NIC_CPUS starts on NUMA node $cpu_node"
  else
    log "NUMA alignment looks good: NIC $DEV and NIC_CPUS both on node $nic_node"
  fi
}

check_topology() {
  log "Topology"
  echo "  OS_CPUS      : $OS_CPUS"
  echo "  GENERIC_CPUS : $GENERIC_CPUS"
  echo "  NIC_CPUS     : $NIC_CPUS"
  echo "  AERON_CPUS   : $AERON_CPUS"
  echo "  DEV          : $DEV"

  validate_cpu_list "OS_CPUS" "$OS_CPUS"
  validate_cpu_list "GENERIC_CPUS" "$GENERIC_CPUS"
  validate_cpu_list "NIC_CPUS" "$NIC_CPUS"
  validate_cpu_list "AERON_CPUS" "$AERON_CPUS"

  check_overlap "OS_CPUS" "$OS_CPUS" "GENERIC_CPUS" "$GENERIC_CPUS"
  check_overlap "OS_CPUS" "$OS_CPUS" "NIC_CPUS" "$NIC_CPUS"
  check_overlap "OS_CPUS" "$OS_CPUS" "AERON_CPUS" "$AERON_CPUS"
  check_overlap "GENERIC_CPUS" "$GENERIC_CPUS" "NIC_CPUS" "$NIC_CPUS"
  check_overlap "GENERIC_CPUS" "$GENERIC_CPUS" "AERON_CPUS" "$AERON_CPUS"
  check_overlap "NIC_CPUS" "$NIC_CPUS" "AERON_CPUS" "$AERON_CPUS"

  if command -v lscpu >/dev/null 2>&1; then
    log "lscpu summary"
    lscpu | egrep 'Architecture|CPU\(s\)|On-line CPU|Thread|Core|Socket|NUMA' || true
  fi

  check_numa_alignment
}

save_state() {
  mkdir -p "$STATE_DIR"
  local ts state_file
  ts="$(date +%Y%m%d%H%M%S)"
  state_file="$STATE_DIR/${DEV}-${ts}.state"

  {
    echo "DEV='$DEV'"
    echo "RPS_FLOW_CNT='$RPS_FLOW_CNT'"

    local irq
    for irq in $(get_nic_irqs); do
      if [[ -f "/proc/irq/$irq/smp_affinity_list" ]]; then
        printf "IRQ:%s:%s\n" "$irq" "$(cat "/proc/irq/$irq/smp_affinity_list")"
      fi
    done

    local q
    for q in /sys/class/net/"$DEV"/queues/rx-*; do
      [[ -e "$q" ]] || continue
      [[ -f "$q/rps_cpus" ]] && printf "FILE:%s:%s\n" "$q/rps_cpus" "$(cat "$q/rps_cpus")"
      [[ -f "$q/rps_flow_cnt" ]] && printf "FILE:%s:%s\n" "$q/rps_flow_cnt" "$(cat "$q/rps_flow_cnt")"
    done

    for q in /sys/class/net/"$DEV"/queues/tx-*; do
      [[ -e "$q" ]] || continue
      [[ -f "$q/xps_cpus" ]] && printf "FILE:%s:%s\n" "$q/xps_cpus" "$(cat "$q/xps_cpus")"
    done

    if [[ -f /proc/sys/net/core/rps_sock_flow_entries ]]; then
      printf "FILE:%s:%s\n" "/proc/sys/net/core/rps_sock_flow_entries" "$(cat /proc/sys/net/core/rps_sock_flow_entries)"
    fi
  } > "$state_file"

  log "Saved rollback state to $state_file"
  SAVED_STATE_FILE="$state_file"
}

restore_state() {
  [[ -f "$RESTORE_FILE" ]] || die "Restore file not found: $RESTORE_FILE"

  log "Restoring state from $RESTORE_FILE"

  while IFS= read -r line; do
    case "$line" in
      IRQ:*)
        local irq value
        irq="$(echo "$line" | cut -d: -f2)"
        value="$(echo "$line" | cut -d: -f3-)"
        [[ -f "/proc/irq/$irq/smp_affinity_list" ]] && write_value "$value" "/proc/irq/$irq/smp_affinity_list"
        ;;
      FILE:*)
        local file value
        file="$(echo "$line" | cut -d: -f2)"
        value="$(echo "$line" | cut -d: -f3-)"
        [[ -f "$file" ]] && write_value "$value" "$file"
        ;;
    esac
  done < "$RESTORE_FILE"

  log "Restore complete"
}

disable_irqbalance() {
  log "[1] Disable irqbalance"
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd "systemctl stop irqbalance 2>/dev/null || true"
    run_cmd "systemctl disable irqbalance 2>/dev/null || true"
  else
    warn "systemctl not found, skipping irqbalance disable"
  fi
}

pin_irqs() {
  local irqs
  irqs="$(get_nic_irqs)"
  [[ -n "$irqs" ]] || {
    grep -iE 'eth|ens|ena' /proc/interrupts || true
    die "No IRQs found for $DEV"
  }

  log "[2] NIC IRQs"
  echo "$irqs" | xargs echo "  IRQs:"

  log "[3] Pin IRQs to CPUs $NIC_CPUS"
  local irq
  for irq in $irqs; do
    write_value "$NIC_CPUS" "/proc/irq/$irq/smp_affinity_list"
  done
}

configure_rps_xps() {
  local nic_mask
  nic_mask="$(cpu_list_to_hex_mask "$NIC_CPUS")"
  log "Computed NIC CPU hex mask: $nic_mask"

  log "[4] Configure RPS on RX queues to CPUs $NIC_CPUS"
  local rxq_count=0
  local q
  for q in /sys/class/net/"$DEV"/queues/rx-*; do
    [[ -e "$q" ]] || continue
    ((rxq_count+=1))
    [[ -f "$q/rps_cpus" ]] && write_value "$nic_mask" "$q/rps_cpus"
    [[ -f "$q/rps_flow_cnt" ]] && write_value "$RPS_FLOW_CNT" "$q/rps_flow_cnt"
  done
  (( rxq_count > 0 )) || warn "No RX queues found for $DEV"

  if [[ -f /proc/sys/net/core/rps_sock_flow_entries ]]; then
    local total_entries=$(( rxq_count > 0 ? rxq_count * RPS_FLOW_CNT : RPS_FLOW_CNT ))
    log "Setting global rps_sock_flow_entries to $total_entries"
    write_value "$total_entries" /proc/sys/net/core/rps_sock_flow_entries
  else
    warn "/proc/sys/net/core/rps_sock_flow_entries not present, skipping"
  fi

  log "[5] Configure XPS on TX queues to CPUs $NIC_CPUS"
  local txq_count=0
  for q in /sys/class/net/"$DEV"/queues/tx-*; do
    [[ -e "$q" ]] || continue
    ((txq_count+=1))
    [[ -f "$q/xps_cpus" ]] && write_value "$nic_mask" "$q/xps_cpus"
  done
  (( txq_count > 0 )) || warn "No TX queues found for $DEV"
}

verify() {
  local irqs
  irqs="$(get_nic_irqs)"

  log "[6] Verification"
  echo "--- IRQ affinity ---"
  local irq
  for irq in $irqs; do
    [[ -f "/proc/irq/$irq/smp_affinity_list" ]] || continue
    echo "IRQ $irq -> $(cat "/proc/irq/$irq/smp_affinity_list")"
  done

  echo
  echo "--- Interrupt counters ---"
  grep "$DEV" /proc/interrupts || true

  echo
  echo "--- Softirq counters ---"
  grep -E '^NET_RX|^NET_TX' /proc/softirqs || true

  echo
  echo "--- Queue config ---"
  local q
  for q in /sys/class/net/"$DEV"/queues/rx-*; do
    [[ -e "$q" ]] || continue
    [[ -f "$q/rps_cpus" ]] && echo "$(basename "$q") rps_cpus=$(cat "$q/rps_cpus")"
    [[ -f "$q/rps_flow_cnt" ]] && echo "$(basename "$q") rps_flow_cnt=$(cat "$q/rps_flow_cnt")"
  done
  for q in /sys/class/net/"$DEV"/queues/tx-*; do
    [[ -e "$q" ]] || continue
    [[ -f "$q/xps_cpus" ]] && echo "$(basename "$q") xps_cpus=$(cat "$q/xps_cpus")"
  done

  echo
  echo "Reminder:"
  echo "  CPUs $GENERIC_CPUS -> Java/JVM helpers, logging, metrics, misc"
  echo "  CPUs $AERON_CPUS   -> Aeron hot threads"
  echo
  echo "This script does not pin application processes by itself."
}

main() {
  parse_args "$@"
  require_root

  if [[ -n "$RESTORE_FILE" ]]; then
    restore_state
    exit 0
  fi

  require_nic
  check_topology
  save_state
  disable_irqbalance
  pin_irqs
  configure_rps_xps
  verify
}

main "$@"
