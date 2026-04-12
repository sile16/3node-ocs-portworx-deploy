#!/usr/bin/env bash
#
# update-etc-hosts.sh — add/remove cluster DNS entries in /etc/hosts
#
# The cluster uses the fake domain `tna.example.local` for its API and
# default ingress hostnames. Nothing on the host resolves these by default,
# so `oc` commands fail with "no such host" until you add entries.
#
# This helper adds three entries inside a labeled block so it can cleanly
# remove them later:
#
#   192.168.125.10  api.tna.example.local
#   192.168.125.11  console-openshift-console.apps.tna.example.local
#   192.168.125.11  oauth-openshift.apps.tna.example.local
#
# It's idempotent — re-running it replaces the block rather than duplicating.
#
# Usage:
#   sudo ./host-setup/update-etc-hosts.sh add        # or just `./... add` (it'll prompt)
#   sudo ./host-setup/update-etc-hosts.sh remove
#   ./host-setup/update-etc-hosts.sh show
#
# Note: if you need additional apps.tna.example.local hostnames (e.g. for a
# route you create), add them to /etc/hosts manually — /etc/hosts does not
# support wildcard entries.

set -euo pipefail

BLOCK_START="# BEGIN tna-libvirt cluster (managed by test/kvm/host-setup/update-etc-hosts.sh)"
BLOCK_END="# END tna-libvirt cluster"
API_IP="192.168.125.10"
INGRESS_IP="192.168.125.11"

cmd="${1:-show}"

case "$cmd" in
  add)
    need_sudo() {
      if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        echo "NOTE: this needs sudo — you will be prompted for your password."
      fi
    }
    need_sudo

    # Remove any prior block first
    if grep -qF "$BLOCK_START" /etc/hosts 2>/dev/null; then
      sudo sed -i "/${BLOCK_START//\//\\/}/,/${BLOCK_END//\//\\/}/d" /etc/hosts
    fi

    # Append fresh block
    sudo tee -a /etc/hosts >/dev/null <<EOF
$BLOCK_START
${API_IP}  api.tna.example.local
${INGRESS_IP}  console-openshift-console.apps.tna.example.local oauth-openshift.apps.tna.example.local
$BLOCK_END
EOF
    echo "=== /etc/hosts updated ==="
    grep -A3 "$BLOCK_START" /etc/hosts
    echo
    echo "You can now run:"
    echo "  export KUBECONFIG=\$PWD/generated/auth/kubeconfig"
    echo "  oc get nodes"
    ;;

  remove)
    if ! grep -qF "$BLOCK_START" /etc/hosts 2>/dev/null; then
      echo "  (no tna-libvirt block in /etc/hosts — nothing to remove)"
      exit 0
    fi
    sudo sed -i "/${BLOCK_START//\//\\/}/,/${BLOCK_END//\//\\/}/d" /etc/hosts
    echo "=== removed tna-libvirt block from /etc/hosts ==="
    ;;

  show)
    if grep -qF "$BLOCK_START" /etc/hosts 2>/dev/null; then
      grep -A3 "$BLOCK_START" /etc/hosts
    else
      echo "(no tna-libvirt block in /etc/hosts)"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 {add|remove|show}" >&2
    exit 2
    ;;
esac
