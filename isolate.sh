#!/usr/bin/env bash
set -euo pipefail

# Topology
OS_CPUS="0-4"
GENERIC_CPUS="5-6"
NIC_CPUS="7-8"
AERON_CPUS="9-13"

# NIC device, override like: DEV=ens5 ./pin.sh
DEV="${DEV:-ens5}"

# Hex mask for CPUs 7-8:
# (1<<7) + (1<<8) = 128 + 256 = 384 = 0x180
NIC_MASK="180"

echo "Applying topology"
echo "  OS/housekeeping : $OS_CPUS"
echo "  Generic/Java    : $GENERIC_CPUS"
echo "  NIC IRQ/softirq : $NIC_CPUS"
echo "  Aeron           : $AERON_CPUS"
echo "  NIC device      : $DEV"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

if [[ ! -d /sys/class/net/$DEV ]]; then
  echo "NIC $DEV not found"
  ip link
  exit 1
fi

echo
echo "[1] Disable irqbalance"
systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

echo
echo "[2] Find NIC IRQs"
IRQS="$(grep "$DEV" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')"
if [[ -z "$IRQS" ]]; then
  echo "No IRQs found for $DEV"
  grep -iE 'eth|ens|ena' /proc/interrupts || true
  exit 1
fi
echo "IRQs: $IRQS"

echo
echo "[3] Pin IRQs to CPUs $NIC_CPUS"
for irq in $IRQS; do
  echo "$NIC_CPUS" > "/proc/irq/$irq/smp_affinity_list"
done

echo
echo "[4] Configure RPS on RX queues to CPUs $NIC_CPUS"
for q in /sys/class/net/$DEV/queues/rx-*; do
  [[ -e "$q/rps_cpus" ]] || continue
  echo "$NIC_MASK" > "$q/rps_cpus"
  [[ -e "$q/rps_flow_cnt" ]] && echo 4096 > "$q/rps_flow_cnt"
done

echo
echo "[5] Configure XPS on TX queues to CPUs $NIC_CPUS"
for q in /sys/class/net/$DEV/queues/tx-*; do
  [[ -e "$q/xps_cpus" ]] || continue
  echo "$NIC_MASK" > "$q/xps_cpus"
done

echo
echo "[6] Verification"
echo "--- IRQ affinity ---"
for irq in $IRQS; do
  echo "IRQ $irq -> $(cat /proc/irq/$irq/smp_affinity_list)"
done

echo
echo "--- Interrupt counters ---"
grep "$DEV" /proc/interrupts || true

echo
echo "--- Softirq counters ---"
grep -E '^NET_RX|^NET_TX' /proc/softirqs || true

echo
echo "Done."
echo
echo "Reminder:"
echo "  CPUs $GENERIC_CPUS -> Java/JVM helpers, logging, metrics, misc"
echo "  CPUs $AERON_CPUS   -> Aeron hot threads"
