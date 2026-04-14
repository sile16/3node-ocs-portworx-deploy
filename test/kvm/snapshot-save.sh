#!/usr/bin/env bash
# Save a named snapshot of every tna-* VM's disk + NVRAM. VMs must be shut off.
#
# Disk snapshots use qemu-img internal snapshots (stored inside the qcow2 file
# itself — instant, no extra disk space). NVRAM is copied to a sibling
# .snap-<name>.fd file (pre-seeded secboot VARS are small — 540 KiB each).
#
# Usage:
#   virsh shutdown master-1.example.local master-2.example.local arbiter-1.example.local
#   # wait for all "shut off"
#   ./snapshot-save.sh baseline-postinstall-nopx
#
# To list / revert / delete:
#   qemu-img snapshot -l /var/lib/libvirt/images/master-1.example.local.qcow2
#   ./snapshot-restore.sh <name>
#   qemu-img snapshot -d <name> /var/lib/libvirt/images/<vm>.qcow2   # delete

set -euo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: $0 <snapshot-name>" >&2; exit 2; }

POOL_DIR="/var/lib/libvirt/images"
NVRAM_DIR="/var/lib/libvirt/qemu/nvram"
VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)

# Refuse if any VM is still running — internal snapshots require the file
# to not have an active writer.
for vm in "${VMS[@]}"; do
  st="$(virsh -c qemu:///system domstate "$vm" 2>/dev/null || echo missing)"
  case "$st" in
    "shut off"|missing) ;;
    *) echo "FATAL: $vm is '$st' — shut it down first" >&2; exit 1 ;;
  esac
done

echo "=== snapshotting to '$NAME' ==="
for vm in "${VMS[@]}"; do
  # /var/lib/libvirt/images is typically 0711 — user can't glob without sudo.
  mapfile -t disks < <(sudo sh -c "ls '$POOL_DIR'/'${vm}'*.qcow2 2>/dev/null")
  for disk in "${disks[@]}"; do
    [ -n "$disk" ] || continue
    echo "  qemu-img snapshot -c $NAME $(basename "$disk")"
    sudo qemu-img snapshot -c "$NAME" "$disk"
  done
  nvram="$NVRAM_DIR/${vm}_VARS.fd"
  if sudo test -f "$nvram"; then
    sudo cp -a "$nvram" "${nvram%.fd}.snap-${NAME}.fd"
    echo "  nvram backup: ${vm}_VARS.snap-${NAME}.fd"
  fi
done
echo "=== done — revert with: $(dirname "$0")/snapshot-restore.sh $NAME ==="
