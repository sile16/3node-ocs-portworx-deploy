#!/usr/bin/env bash
# Stage MOK enrollment of the Portworx Secure Boot CA on every node, then
# print reboot instructions for the operator.
#
# Run this BEFORE 98-px1-prepare.sh on sites where firmware Secure Boot is
# ON. The cert itself is already on-disk (dropped by the 98-machineconfig-*
# MachineConfigs at install time, at /etc/pki/mok/portworx-public.der). All
# this script does is `mokutil --import` with a well-known temporary password,
# which queues the import for MokManager to pick up on the NEXT reboot.
#
# The operator then reboots each node (IPMI/iDRAC/iLO/physical console) and
# answers the MokManager prompt within ~10 s of firmware handoff:
#   Press key → Enroll MOK → View key → Continue → Yes → enter password
#
# Temporary password is printed below. It is a one-shot secret; MokManager
# wipes the import request after successful enrollment.
#
# Skip this script on sites where Secure Boot is disabled in BIOS — PX
# loads without MOK enrollment in that case (but see docs/portworx-design.md
# for the security-vs-ops tradeoff).
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   ./98-px0-enroll-mok.sh          # stage on all nodes, print reboot list
#   ./98-px0-enroll-mok.sh --verify # post-reboot sanity: list enrolled keys

set -euo pipefail

MOK_PASS="${MOK_PASS:-portworx}"   # temporary MokManager password
CERT_PATH="/etc/pki/mok/portworx-public.der"

command -v oc >/dev/null || { echo "FATAL: oc not in PATH" >&2; exit 1; }
[ -n "${KUBECONFIG:-}" ] || { echo "FATAL: export KUBECONFIG first" >&2; exit 1; }

NODES="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
[ -n "$NODES" ] || { echo "FATAL: no nodes visible with current kubeconfig" >&2; exit 1; }

# --verify: post-reboot sanity check.
if [ "${1:-}" = "--verify" ]; then
  echo "=== verifying Portworx cert enrolled in MOK on each node ==="
  ok=0; fail=0
  for n in $NODES; do
    printf "  %-30s " "$n"
    out="$(oc debug --quiet "node/$n" -- chroot /host bash -c \
           'mokutil --list-enrolled 2>/dev/null | grep -c "Portworx Secure Boot CA" || true' 2>/dev/null || echo 0)"
    if [ "${out//[^0-9]/}" -ge 1 ] 2>/dev/null; then
      echo "OK (Portworx CA enrolled)"; ok=$((ok+1))
    else
      echo "MISSING — reboot node and enroll via MokManager"; fail=$((fail+1))
    fi
  done
  echo "summary: $ok enrolled, $fail missing"
  [ "$fail" -eq 0 ]
  exit $?
fi

# Default path: stage the import on each node.
echo "=== staging MOK import on each node ==="
echo "    cert   : $CERT_PATH (dropped by 98-machineconfig-*)"
echo "    passwd : $MOK_PASS   (you'll type this at MokManager on first reboot)"
echo

for n in $NODES; do
  echo "--- $n ---"
  # `mokutil --import` prompts for password twice. Feed it via stdin.
  oc debug --quiet "node/$n" -- chroot /host bash -c "
    set -e
    [ -f $CERT_PATH ] || { echo 'FATAL: $CERT_PATH not found — 98-machineconfig-* applied?' >&2; exit 1; }
    printf '%s\n%s\n' '$MOK_PASS' '$MOK_PASS' | mokutil --import $CERT_PATH
    mokutil --list-new | head -20
  "
done

cat <<EOF

=== NEXT STEPS (per-node, one-time) ===
For each node, via console / IPMI / iDRAC / iLO:
  1. Reboot the node.
  2. Within ~10 s of firmware handoff, MokManager appears.
     Press any key to enter MOK management.
  3. Enroll MOK → View key 0 (Portworx Secure Boot CA) → Continue.
  4. When asked "Enroll the key(s)?": Yes.
  5. Enter the password shown above: $MOK_PASS
  6. Reboot.

After all nodes have rebooted and enrolled:
  ./98-px0-enroll-mok.sh --verify

Then proceed with ./98-px1-prepare.sh and the rest of the Portworx bring-up.
EOF
