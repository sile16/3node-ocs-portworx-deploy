#!/usr/bin/env bash
#
# status.sh — one-shot snapshot of install progress
#
# Non-invasive. Safe to run at any time, any number of times.
# Outputs to stdout. Format is meant for eyeballs, not parsing.
#
# What it shows:
#   1. libvirt domain states (running / shut off / paused)
#   2. DHCP leases on tna-net (confirms nodes reached their reserved IPs)
#   3. CPU-time delta over 5 wall-seconds per VM (= is the vCPU busy?)
#   4. qcow2 physical footprint per VM boot disk (needs sudo)
#   5. Tail of /tmp/agent-bootstrap.log (if the wait-for watcher is running)
#   6. `sudo podman ps` on the rendezvous host (containers backing the install)
#
# If something looks stuck, run ./rendezvous-logs.sh for a deeper dig into
# the assisted-service log on the rendezvous host.

set -euo pipefail

LIBVIRT_URI="qemu:///system"
NET_NAME="tna-net"
VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)
RENDEZVOUS_IP="192.168.125.20"
BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-/tmp/agent-bootstrap.log}"
SSH_KEY="${HOME}/.ssh/id_rsa"

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

section() { printf '\n── %s ──\n' "$*"; }

section "domain states"
virsh -c "$LIBVIRT_URI" list --all | awk 'NR<=2 || /tna-/'

section "tna-net DHCP leases (reserved IPs should be present)"
virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NET_NAME" 2>/dev/null | \
  awk 'NR<=2 || /tna-/'

section "CPU-time delta over 5s (busy = install active)"
declare -A t0
for vm in "${VMS[@]}"; do
  t0[$vm]=$(virsh -c "$LIBVIRT_URI" domstats "$vm" 2>/dev/null \
            | awk -F= '/cpu.time=/{print $2; exit}')
done
sleep 5
for vm in "${VMS[@]}"; do
  t1=$(virsh -c "$LIBVIRT_URI" domstats "$vm" 2>/dev/null \
       | awk -F= '/cpu.time=/{print $2; exit}')
  if [ -z "${t0[$vm]:-}" ] || [ -z "$t1" ]; then
    printf '  %-14s <not running>\n' "$vm"
  else
    awk -v v="$vm" -v t0="${t0[$vm]}" -v t1="$t1" \
      'BEGIN{ printf "  %-14s +%.2fs cpu in 5.0s wall → %.0f%% vcpu\n", v, (t1-t0)/1e9, ((t1-t0)/1e9/5)*100 }'
  fi
done

section "qcow2 physical usage (needs sudo — sparse files; small = untouched)"
if sudo -n true 2>/dev/null; then
  sudo bash -c 'cd /var/lib/libvirt/images && du -ch tna-*.qcow2 2>/dev/null' 2>&1 | tail -10
else
  echo "  (skipping — sudo not available without prompt)"
fi

section "tail of $BOOTSTRAP_LOG"
if [ -s "$BOOTSTRAP_LOG" ]; then
  tail -10 "$BOOTSTRAP_LOG"
else
  echo "  (no log — run ./wait-bootstrap.sh to start the background watcher)"
fi

section "rendezvous podman containers ($RENDEZVOUS_IP)"
if ssh "${SSH_OPTS[@]}" "core@$RENDEZVOUS_IP" true 2>/dev/null; then
  ssh "${SSH_OPTS[@]}" "core@$RENDEZVOUS_IP" \
    'sudo podman ps --format "{{.Names}}\t{{.Status}}" 2>&1' \
    | awk 'NF>0{printf "  %s\n", $0}'
else
  echo "  (rendezvous host not reachable via SSH — it may be mid-reboot)"
fi

echo
