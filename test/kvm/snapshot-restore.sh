#!/usr/bin/env bash
# Revert every tna-* VM's disk + NVRAM to a previously saved snapshot.
# VMs must be shut off.
#
# Usage:
#   virsh shutdown master-1.example.local master-2.example.local arbiter-1.example.local
#   # wait for all "shut off"
#   ./snapshot-restore.sh baseline-postinstall-nopx
#   virsh start master-1.example.local master-2.example.local arbiter-1.example.local

set -euo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: $0 <snapshot-name>" >&2; exit 2; }

POOL_DIR="/var/lib/libvirt/images"
NVRAM_DIR="/var/lib/libvirt/qemu/nvram"
VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)

for vm in "${VMS[@]}"; do
  st="$(virsh -c qemu:///system domstate "$vm" 2>/dev/null || echo missing)"
  case "$st" in
    "shut off"|missing) ;;
    *) echo "FATAL: $vm is '$st' — shut it down first" >&2; exit 1 ;;
  esac
done

echo "=== reverting to '$NAME' ==="
for vm in "${VMS[@]}"; do
  mapfile -t disks < <(sudo sh -c "ls '$POOL_DIR'/'${vm}'*.qcow2 2>/dev/null")
  for disk in "${disks[@]}"; do
    [ -n "$disk" ] || continue
    echo "  qemu-img snapshot -a $NAME $(basename "$disk")"
    sudo qemu-img snapshot -a "$NAME" "$disk"
  done
  snap_nvram="$NVRAM_DIR/${vm}_VARS.snap-${NAME}.fd"
  live_nvram="$NVRAM_DIR/${vm}_VARS.fd"
  if sudo test -f "$snap_nvram"; then
    sudo cp -a "$snap_nvram" "$live_nvram"
    sudo chown libvirt-qemu:kvm "$live_nvram"
    sudo chmod 600 "$live_nvram"
    echo "  nvram restored: ${vm}_VARS.fd"
  fi
done
echo "=== done — start VMs with: virsh start <vm> ==="
