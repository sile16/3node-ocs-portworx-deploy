#!/usr/bin/env bash
#
# teardown.sh — libvirt cleanup
#
# Idempotent. Safe to re-run if the cluster is half-built, fully built, or
# already torn down.
#
# What it deletes:
#   - The 3 VMs (virsh destroy + undefine, including NVRAM)
#   - The qcow2 volumes in the default storage pool whose names start with
#     master-1.example.local-, master-2.example.local-, arbiter-1.example.local-
#   - The generated/ working directory (ISO, rendered install-config, auth/,
#     .openshift_install_state.json, etc.)
#
# What it deliberately leaves alone:
#   - The tna-net libvirt network. It's cheap to keep and gets reused on the
#     next create-vms.sh run. Delete manually with:
#         virsh -c qemu:///system net-destroy tna-net
#         virsh -c qemu:///system net-undefine tna-net
#   - The logs/ directory. Previous runs' collected artifacts stay around
#     for comparison.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBVIRT_URI="qemu:///system"
POOL_NAME="default"

VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)

# Stop the autostart-watcher BEFORE destroying any domains. Otherwise the
# watcher races teardown: it sees a domain go "shut off" between our
# destroy and undefine, starts it again, leaves us with a transient
# running domain whose disk files no longer exist.
WATCHER="${HERE}/host-setup/autostart-watcher.sh"
if [ -x "$WATCHER" ] && "$WATCHER" status >/dev/null 2>&1; then
  echo "=== stopping autostart-watcher (to avoid race with teardown) ==="
  "$WATCHER" stop 2>&1 | sed 's/^/  /'
fi

destroy_vm() {
  local name="$1"
  if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    echo "=== destroying VM $name ==="
    virsh -c "$LIBVIRT_URI" destroy  "$name" 2>/dev/null || true
    # --nvram removes the UEFI varstore libvirt created alongside the domain
    virsh -c "$LIBVIRT_URI" undefine "$name" --nvram 2>/dev/null \
      || virsh -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null \
      || true
  else
    echo "=== VM $name already gone ==="
  fi
}

delete_vm_volumes() {
  local name="$1"
  # Match anything in the default pool whose name starts with the VM name.
  # virt-install's pool=default,size=N naming is: <vmname>.qcow2 or
  # <vmname>-1.qcow2 for the second disk. Be generous with the prefix match.
  local vols
  vols="$(virsh -c "$LIBVIRT_URI" vol-list "$POOL_NAME" --details 2>/dev/null \
            | awk -v n="$name" '$1 ~ "^"n {print $1}' || true)"
  if [ -z "$vols" ]; then
    echo "    (no volumes matching $name in pool $POOL_NAME)"
    return
  fi
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    echo "    deleting volume $v"
    virsh -c "$LIBVIRT_URI" vol-delete --pool "$POOL_NAME" "$v" 2>/dev/null || true
  done <<< "$vols"
}

for vm in "${VMS[@]}"; do
  destroy_vm "$vm"
  delete_vm_volumes "$vm"
done

# ── drop the ISO volume generate-iso.sh uploaded ──────────────────────────
if virsh -c "$LIBVIRT_URI" vol-info --pool "$POOL_NAME" tna-agent.iso >/dev/null 2>&1; then
  echo "=== deleting pool volume tna-agent.iso ==="
  virsh -c "$LIBVIRT_URI" vol-delete --pool "$POOL_NAME" tna-agent.iso 2>/dev/null || true
fi

# ── wipe the generated/ working directory ─────────────────────────────────
if [ -d "${HERE}/generated" ]; then
  echo "=== removing ${HERE}/generated ==="
  rm -rf "${HERE}/generated"
else
  echo "=== ${HERE}/generated already gone ==="
fi

echo
echo "Done. tna-net libvirt network intentionally left in place (cheap + reusable)."
echo "To delete it too:"
echo "  virsh -c $LIBVIRT_URI net-destroy tna-net"
echo "  virsh -c $LIBVIRT_URI net-undefine tna-net"
