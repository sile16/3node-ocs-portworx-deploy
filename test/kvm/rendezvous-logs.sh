#!/usr/bin/env bash
#
# rendezvous-logs.sh — dump assisted-service container logs from the rendezvous
#
# SSHes to master-1.example.local (the rendezvous host, always 192.168.125.20), dumps the
# `service` container's log (that's the assisted-service process driving the
# install), plus `podman ps`, and saves everything under ./logs/rendezvous/.
#
# Also runs several targeted greps that have been useful for triage:
#   1. "failed to set installation disk" — rootDeviceHints mismatch
#   2. "Status:failure" — any validation in the failing state
#   3. "updated status from X to Y" — state transitions
#   4. cluster-level status changes
#
# Use this any time the install looks stuck and you want to see why.
#
# Usage:
#   ./rendezvous-logs.sh           # default: dump + common greps
#   ./rendezvous-logs.sh --tail    # just stream the live log to stdout

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RENDEZVOUS_IP="192.168.125.20"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

if [ "${1:-}" = "--tail" ]; then
  echo "Streaming service logs from $RENDEZVOUS_IP (ctrl+c to stop)..."
  exec ssh "${SSH_OPTS[@]}" "core@${RENDEZVOUS_IP}" 'sudo podman logs -f service 2>&1'
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${HERE}/logs/rendezvous/${TS}"
mkdir -p "$OUT_DIR"

echo "=== dumping rendezvous state to $OUT_DIR ==="

# 1. podman ps — what's running on the rendezvous
ssh "${SSH_OPTS[@]}" "core@${RENDEZVOUS_IP}" \
  'sudo podman ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1' \
  > "${OUT_DIR}/podman-ps.txt" 2>&1
echo "  ${OUT_DIR}/podman-ps.txt"

# 2. Full assisted-service container log
ssh "${SSH_OPTS[@]}" "core@${RENDEZVOUS_IP}" \
  'sudo podman logs service 2>&1' \
  > "${OUT_DIR}/service.log" 2>&1
echo "  ${OUT_DIR}/service.log ($(wc -l < "${OUT_DIR}/service.log") lines)"

# 3. Targeted greps — common triage patterns
{
  echo "### failed to set installation disk (rootDeviceHints mismatch?)"
  grep -E "failed to set installation disk" "${OUT_DIR}/service.log" || echo "(none)"
  echo
  echo "### any validation Status:failure"
  grep -oE '\{ID:[a-z-]+ Status:failure Message:[^}]+\}' "${OUT_DIR}/service.log" \
    | sort -u || echo "(none)"
  echo
  echo "### host state transitions"
  grep -E 'updated status from .* to ' "${OUT_DIR}/service.log" || \
    grep -oE 'has been updated with the following updates \[status [a-z-]+' "${OUT_DIR}/service.log" \
    | sort -u || echo "(none)"
  echo
  echo "### cluster state updates"
  grep -oE 'status [a-z-]+ status_info [^[]{1,80}' "${OUT_DIR}/service.log" \
    | sort -u || echo "(none)"
  echo
  echo "### error-level lines"
  grep '"level=error"' "${OUT_DIR}/service.log" \
    | sed 's/.*msg="\([^"]*\)".*/\1/' | sort -u | head -20 || echo "(none)"
} > "${OUT_DIR}/triage.txt"
echo "  ${OUT_DIR}/triage.txt"

echo
echo "=== triage summary ==="
cat "${OUT_DIR}/triage.txt"
