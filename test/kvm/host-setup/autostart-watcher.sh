#!/usr/bin/env bash
#
# autostart-watcher.sh — belt-and-braces auto-restart for tna-* libvirt VMs
#
# Why this exists:
#   virt-install with --cdrom forces on_reboot=destroy (so it can "rebuild"
#   the domain without the cdrom on reboot) and refuses to let us override
#   that to on_reboot=restart. On top of that, libvirt's default on_poweroff
#   is destroy. The OCP agent-based installer calls `poweroff` (not reboot)
#   after write-to-disk to force a clean cold boot — so the first time a VM
#   transitions from "agent ISO" to "installed RHCOS" it powers off and
#   libvirt immediately destroys the domain, stalling the install forever.
#
#   This watcher polls `virsh domstate` every 2s and brings shut-off VMs
#   back up within a second or two of the destroy. Without it, test/kvm
#   installs reliably stall mid-flight. (See feedback_libvirt_on_poweroff.md
#   in the memory store for the full post-mortem.)
#
# What it watches: the three fixed VM names master-1.example.local, master-2.example.local, arbiter-1.example.local.
# PID file:       /tmp/tna-autorestart.pid
# Log file:       /tmp/tna-autorestart.log
#
# Usage:
#   ./host-setup/autostart-watcher.sh start        # spawn in background (idempotent)
#   ./host-setup/autostart-watcher.sh stop         # terminate
#   ./host-setup/autostart-watcher.sh status       # is it running?
#   ./host-setup/autostart-watcher.sh logs         # tail -f the log

set -euo pipefail

LIBVIRT_URI="qemu:///system"
VMS=(master-1.example.local master-2.example.local arbiter-1.example.local)
INTERVAL_SEC=2
PID_FILE="/tmp/tna-autorestart.pid"
LOG_FILE="/tmp/tna-autorestart.log"

cmd="${1:-start}"

is_running() {
  [ -f "$PID_FILE" ] && pid=$(cat "$PID_FILE") && kill -0 "$pid" 2>/dev/null
}

case "$cmd" in
  start)
    if is_running; then
      pid=$(cat "$PID_FILE")
      echo "already running (pid $pid) — tail $LOG_FILE"
      exit 0
    fi

    : > "$LOG_FILE"

    # Use setsid so the loop survives the parent shell exiting, and redirect
    # stdin/stdout/stderr to the log file. Quote the inner script carefully —
    # we export variables so the subshell can see them without argv.
    export LIBVIRT_URI LOG_FILE INTERVAL_SEC
    export VMS_JOINED="${VMS[*]}"

    setsid bash -c '
      IFS=" " read -r -a VMS <<< "$VMS_JOINED"
      echo "$(date +%FT%T) watcher starting (uri=$LIBVIRT_URI interval=${INTERVAL_SEC}s vms=${VMS[*]})"
      while true; do
        for vm in "${VMS[@]}"; do
          state=$(virsh -c "$LIBVIRT_URI" domstate "$vm" 2>/dev/null || echo "missing")
          if [ "$state" = "shut off" ]; then
            echo "$(date +%H:%M:%S) auto-restarting shut-off $vm"
            virsh -c "$LIBVIRT_URI" start "$vm" 2>&1
          fi
        done
        sleep "$INTERVAL_SEC"
      done
    ' </dev/null >>"$LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PID_FILE"
    disown "$pid" 2>/dev/null || true
    sleep 0.5
    if is_running; then
      echo "started pid $pid (log: $LOG_FILE)"
    else
      echo "FATAL: watcher died immediately — check $LOG_FILE" >&2
      tail -20 "$LOG_FILE" >&2
      rm -f "$PID_FILE"
      exit 1
    fi
    ;;

  stop)
    if ! is_running; then
      echo "not running"
      rm -f "$PID_FILE"
      exit 0
    fi
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    # the setsid'd child may have its own process group; kill the group too
    kill -- "-$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "stopped pid $pid"
    ;;

  status)
    if is_running; then
      pid=$(cat "$PID_FILE")
      echo "running (pid $pid)"
      echo "recent events:"
      tail -5 "$LOG_FILE" | sed 's/^/  /'
    else
      echo "not running"
      exit 1
    fi
    ;;

  logs)
    exec tail -F "$LOG_FILE"
    ;;

  *)
    echo "Usage: $0 {start|stop|status|logs}" >&2
    exit 2
    ;;
esac
