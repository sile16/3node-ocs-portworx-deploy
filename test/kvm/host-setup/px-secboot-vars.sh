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

# SEED_PX_CERT env var toggle:
#   yes (default)  — seed PX CA in both UEFI db + MOK (kernel loads px.ko AND
#                    px-runc pre-flight `mokutil --list-enrolled` succeeds).
#                    This is the standard regression path.
#   no             — MS baseline only; Secure Boot still ON but no PX trust.
#                    Simulates a real physical node straight out of install.
#                    px-runc will emit `SecureBootCertNotEnrolled` and refuse
#                    to start px.ko. Useful for reproducing the bare-metal
#                    first-boot failure in KVM.
SEED_PX_CERT="${SEED_PX_CERT:-yes}"

case "$SEED_PX_CERT" in
  yes|1|true)
    virt-fw-vars \
      --input  "$BASE" \
      --output "$OUT" \
      --add-db  "$PX_GUID" "$CERT" \
      --add-mok "$PX_GUID" "$CERT" \
      --secure-boot
    ;;
  no|0|false)
    virt-fw-vars \
      --input  "$BASE" \
      --output "$OUT" \
      --secure-boot
    ;;
  *)
    echo "FATAL: SEED_PX_CERT must be yes/no (got: $SEED_PX_CERT)" >&2
    exit 2
    ;;
esac
