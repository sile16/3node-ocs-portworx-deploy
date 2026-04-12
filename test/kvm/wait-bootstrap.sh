#!/usr/bin/env bash
#
# wait-bootstrap.sh — start (or restart) the background bootstrap-complete watcher
#
# Runs `openshift-install agent wait-for bootstrap-complete --dir=./generated`
# under nohup, streaming output to /tmp/agent-bootstrap.log. The wait-for
# command polls assisted-service and prints state transitions; if it ever
# exits we lose the stream, so this script makes re-starting it idempotent.
#
# Behavior:
#   - Kills any previous wait-for process owned by this user before starting
#   - Truncates /tmp/agent-bootstrap.log so you start with a clean view
#   - Prints the pid so you can `ps -fp <pid>` if you're curious
#
# Usage:
#   ./wait-bootstrap.sh                    # default: bootstrap-complete
#   ./wait-bootstrap.sh install-complete   # switch to install-complete phase
#
# Monitor the progress with:
#   tail -F /tmp/agent-bootstrap.log
#   ./status.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${HERE}/generated"
LOG="${BOOTSTRAP_LOG:-/tmp/agent-bootstrap.log}"
OPENSHIFT_INSTALL="${OPENSHIFT_INSTALL:-$(command -v openshift-install || echo "$HOME/bin/openshift-install")}"

PHASE="${1:-bootstrap-complete}"
case "$PHASE" in
  bootstrap-complete|install-complete) ;;
  *) echo "FATAL: unknown phase '$PHASE' (expected bootstrap-complete or install-complete)" >&2; exit 1 ;;
esac

[ -x "$OPENSHIFT_INSTALL" ] || {
  echo "FATAL: openshift-install not executable at $OPENSHIFT_INSTALL" >&2
  exit 1
}

[ -d "$GEN" ] || {
  echo "FATAL: working directory $GEN not found — run ./generate-iso.sh first" >&2
  exit 1
}

# kill any previous wait-for process the same user owns
PREV_PIDS="$(pgrep -f 'openshift-install agent wait-for' -u "$USER" 2>/dev/null || true)"
if [ -n "$PREV_PIDS" ]; then
  echo "killing previous wait-for processes: $PREV_PIDS"
  kill $PREV_PIDS 2>/dev/null || true
  sleep 1
fi

# truncate the log
: > "$LOG"

echo "=== launching: openshift-install agent wait-for $PHASE ==="
nohup "$OPENSHIFT_INSTALL" agent wait-for "$PHASE" --dir="$GEN" --log-level=info \
  >"$LOG" 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true

sleep 2
if kill -0 "$PID" 2>/dev/null; then
  echo "  pid $PID, logging to $LOG"
  echo "  tail -F $LOG    # stream events"
  echo "  ./status.sh     # snapshot view"
else
  echo "FATAL: wait-for exited immediately — check $LOG" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
