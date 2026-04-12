#!/usr/bin/env bash
#
# upload-iso-to-pool.sh — KVM-only: copy generated/agent.x86_64.iso into the
# default libvirt pool so create-vms.sh can boot it.
#
# Why: libvirt-qemu cannot traverse /home/sile (mode 750) to read the ISO
# from test/kvm/generated/. Rather than ACL/chmod the home path chain,
# we let libvirt own a copy inside /var/lib/libvirt/images/. teardown.sh
# deletes it via vol-delete.
#
# This script is idempotent: it removes any prior upload before re-uploading.
#
# Usage:
#   ./upload-iso-to-pool.sh          # after ./build-iso.sh has produced the ISO

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${HERE}/generated"
SRC_ISO="${GEN}/agent.x86_64.iso"

LIBVIRT_URI="qemu:///system"
POOL_NAME="default"
POOL_ISO_NAME="tna-agent.iso"

[ -f "$SRC_ISO" ] || {
  echo "FATAL: source ISO not found at $SRC_ISO" >&2
  echo "       Run ./build-iso.sh first." >&2
  exit 1
}

virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" >/dev/null 2>&1 || {
  echo "FATAL: libvirt pool '$POOL_NAME' not found. Run ./envsetup.sh first." >&2
  exit 1
}

echo "=== uploading $SRC_ISO → pool $POOL_NAME / $POOL_ISO_NAME ==="

# Refuse to clobber if a VM currently references the in-pool volume — that
# means an install is in progress and deleting the ISO would wreck it.
IN_USE=""
for vm in master-1.example.local master-2.example.local arbiter-1.example.local; do
  if virsh -c "$LIBVIRT_URI" domblklist "$vm" 2>/dev/null | awk '{print $2}' | grep -q "${POOL_ISO_NAME}$"; then
    IN_USE="$IN_USE $vm"
  fi
done
if [ -n "$IN_USE" ]; then
  echo "FATAL: pool volume '${POOL_ISO_NAME}' is currently attached to:${IN_USE}" >&2
  echo "       Run ./teardown.sh first, OR rebuild the ISO only (skip upload)." >&2
  exit 1
fi

ISO_BYTES="$(stat -c %s "$SRC_ISO")"
virsh -c "$LIBVIRT_URI" vol-delete --pool "$POOL_NAME" "$POOL_ISO_NAME" 2>/dev/null || true
virsh -c "$LIBVIRT_URI" vol-create-as "$POOL_NAME" "$POOL_ISO_NAME" "$ISO_BYTES" --format raw
virsh -c "$LIBVIRT_URI" vol-upload   --pool "$POOL_NAME" "$POOL_ISO_NAME" "$SRC_ISO"
POOL_ISO_PATH="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$POOL_NAME" "$POOL_ISO_NAME")"

printf '\n=== done — in-pool ISO: %s ===\n' "$POOL_ISO_PATH"
