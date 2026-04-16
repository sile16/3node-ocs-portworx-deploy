#!/usr/bin/env bash
# Stage MOK enrollment of the Portworx Secure Boot CA on every node, then
# print reboot instructions for the operator.
#
# Run on sites where firmware Secure Boot is
# ON. The script downloads the PX CA directly on each node (nodes have
# outbound internet by assumption) and runs `mokutil --import` with a
# well-known temporary password, queuing enrollment for MokManager.
#
# The user then needs to reboot each node (IPMI/iDRAC/iLO/physical console) and
# answers the MokManager prompt within ~10 s of firmware handoff:
#   Press key → Enroll MOK → View key → Continue → Yes → enter password
#
# Skip this script on sites where Secure Boot is disabled in BIOS — PX
# loads without MOK enrollment in that case. See docs/portworx-design.md
# for the full story.
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   ./98-px0-enroll-mok.sh          # stage on all nodes, print reboot list
#   ./98-px0-enroll-mok.sh --verify # post-reboot sanity: list enrolled keys

set -euo pipefail

# ── cert pin ──────────────────────────────────────────────────────────────
# Bump when Portworx rotates their signing CA (typically annual — URL path
# carries the year). Pair the bump with a startingCSV bump in
# 98-px3-subscription.yaml; verify the new fingerprint against PX release
# notes out-of-band before committing.
CERT_URL="https://mirrors.portworx.com/build-results/pxfuse/certs/v2025/portworx-public.der"
CERT_YEAR=2025
CERT_SHA256="8be7b22b17e50a34bf7dd4e6a087b4ceccd4f4dbde4ed4c06c8cd01f1b782de8"
MOK_PASS="${MOK_PASS:-portworx}"

# Soft warning if calendar year has lapped the pinned cert year.
NOW_YEAR="$(date +%Y)"
if [ "$NOW_YEAR" -gt "$CERT_YEAR" ]; then
  cat >&2 <<EOF
WARN: pinned cert is v${CERT_YEAR}, system year is ${NOW_YEAR}.
      Portworx may have rotated the CA. Check:
        https://docs.portworx.com/portworx-enterprise/platform/secure/secure-boot
      If rotated, bump CERT_URL + CERT_YEAR + CERT_SHA256 in this script
      (and verify the new fingerprint against PX release notes out-of-band).

EOF
fi

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

# Default path: fetch + stage the import on each node.
echo "=== staging MOK import on each node ==="
echo "    cert url : $CERT_URL"
echo "    sha256   : $CERT_SHA256"
echo "    passwd   : $MOK_PASS   (you'll type this at MokManager on first reboot)"
echo

for n in $NODES; do
  echo "--- $n ---"
  oc debug --quiet "node/$n" -- chroot /host bash -c "
    set -e
    tmp=\$(mktemp --suffix=-pxca.der)
    trap 'rm -f \"\$tmp\"' EXIT
    curl -fsSL -o \"\$tmp\" '$CERT_URL'
    got=\$(sha256sum \"\$tmp\" | awk '{print \$1}')
    if [ \"\$got\" != '$CERT_SHA256' ]; then
      echo \"FATAL: cert sha256 mismatch — got \$got, expected $CERT_SHA256\" >&2
      exit 1
    fi
    printf '%s\n%s\n' '$MOK_PASS' '$MOK_PASS' | mokutil --import \"\$tmp\"
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
