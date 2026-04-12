#!/usr/bin/env bash
#
# snapshot-consoles.sh — dump each tna-* VM's framebuffer to a PNG
#
# Uses `virsh screenshot` which grabs the current VNC framebuffer from
# whatever text-mode or graphical console the guest is currently showing.
# Works for the RHCOS agent ISO login prompt, the installed-OS login prompt,
# kernel panics, BIOS screens, etc.
#
# Output: ./logs/screenshots/<timestamp>/<vm>.png  (relative to this script)
# Prints the full path of each PNG on stdout so you can read them back with
# your image viewer of choice.
#
# Usage:
#   ./snapshot-consoles.sh              # snapshot all 3
#   ./snapshot-consoles.sh master-1.example.local   # snapshot a specific one

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBVIRT_URI="qemu:///system"
DEFAULT_VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)

if [ "$#" -gt 0 ]; then
  VMS=("$@")
else
  VMS=("${DEFAULT_VMS[@]}")
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${HERE}/logs/screenshots/${TS}"
mkdir -p "$OUT_DIR"

for vm in "${VMS[@]}"; do
  state="$(virsh -c "$LIBVIRT_URI" domstate "$vm" 2>/dev/null || echo 'missing')"
  if [ "$state" != "running" ]; then
    printf '  %-14s %s — skipping (no framebuffer)\n' "$vm" "$state"
    continue
  fi
  out="${OUT_DIR}/${vm}.png"
  if virsh -c "$LIBVIRT_URI" screenshot "$vm" "$out" >/dev/null 2>&1; then
    printf '  %-14s → %s\n' "$vm" "$out"
  else
    printf '  %-14s FAILED — is --graphics vnc set?\n' "$vm"
  fi
done

echo
echo "All screenshots in: $OUT_DIR"
