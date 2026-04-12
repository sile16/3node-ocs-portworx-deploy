#!/usr/bin/env bash
#
# generate-iso.sh — thin wrapper for the libvirt/KVM flow.
#
# Runs:
#   ./build-iso.sh              — builds ./generated/agent.x86_64.iso
#                                  (auto-folds in ./machineconfigs/*.yaml)
#   ./upload-iso-to-pool.sh     — copies it into the default libvirt pool
#
# For bare-metal USB install, call ./build-iso.sh directly — but first
# delete (or point elsewhere) the machineconfigs/ dir so the KVM-only
# rotational-hint MC is not folded into the ISO.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

"${HERE}/build-iso.sh"
"${HERE}/upload-iso-to-pool.sh"

echo
echo "Next: ./create-vms.sh"
