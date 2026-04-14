#!/usr/bin/env bash
# Seed a per-VM OVMF_VARS file so the guest boots with Secure Boot ON and
# Portworx's module-signing cert pre-enrolled in the UEFI db. Matches what
# a bare-metal operator achieves by running `mokutil --import` + rebooting
# on first boot — here we do it at VM-define time so the KVM harness can
# validate PX 3.6.0's signed px.ko under SB without any MOK prompt.
#
# Usage: ./px-secboot-vars.sh <output-path>
#
# Output file is a 540672-byte OVMF_VARS image with:
#   - MS KEK + MS UEFI CA (baseline — shim is signed by this chain)
#   - Portworx Secure Boot CA @2025 appended to db

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CERT="${HERE}/portworx-public.der"
BASE="${OVMF_VARS_BASE:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}"

OUT="${1:-}"
[ -n "$OUT" ] || { echo "usage: $0 <output-path>" >&2; exit 2; }

[ -f "$CERT" ] || {
  echo "FATAL: PX cert not found at $CERT" >&2
  echo "  Download: curl -sSLo $CERT https://mirrors.portworx.com/build-results/pxfuse/certs/v2025/portworx-public.der" >&2
  exit 1
}
[ -f "$BASE" ] || { echo "FATAL: OVMF VARS base not found at $BASE" >&2; exit 1; }
command -v virt-fw-vars >/dev/null || { echo "FATAL: virt-fw-vars not in PATH (apt install python3-virt-firmware)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# Deterministic GUID for the Portworx owner record in db; no meaning beyond
# grouping all PX-signed entries under a stable identifier.
PX_GUID="50555258-0000-0000-0000-000050585856"   # "PURX\0\0\0\0\0\0PXXV" — mnemonic

virt-fw-vars \
  --input  "$BASE" \
  --output "$OUT" \
  --add-db  "$PX_GUID" "$CERT" \
  --add-mok "$PX_GUID" "$CERT" \
  --secure-boot

# Two writes on purpose: UEFI db enrolls for the kernel's .platform keyring
# (module load check); MOK enrolls for shim/userspace tools (`mokutil --list-
# enrolled`) that PX 3.6.0's px-runc pre-flight queries at startup. Dropping
# either makes px-cluster stay Initializing with SecureBootCertNotEnrolled.
