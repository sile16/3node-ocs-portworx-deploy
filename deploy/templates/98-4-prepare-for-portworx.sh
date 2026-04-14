#!/usr/bin/env bash
# Prep nodes for Portworx.
#
# Two jobs:
#   1. Label masters / arbiter so 98-6-'s placement nodeAffinity matches.
#   2. Resolve /dev/disk/by-partlabel/px-metadata → the actual raw device
#      on each node (e.g. /dev/vda5 on libvirt, /dev/sda5 or
#      /dev/nvme0n1p5 on bare metal) and generate
#      98-6-portworx-storagecluster.yaml from the adjacent .yaml.template
#      template.
#
# Must run AFTER the cluster is installed (MCs rolled so the
# px-metadata partition exists) and BEFORE applying 98-6-.
# Rerunning is safe: .yaml.template is read-only input; .yaml is regenerated
# from it each run, so changed device mappings pick up cleanly.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG:?KUBECONFIG not set}"

# Per-site node names — baked in at render time from sites.csv.
MASTER1_HOST="${MASTER1_HOST}"
MASTER2_HOST="${MASTER2_HOST}"
ARBITER_HOST="${ARBITER_HOST}"

# ── label nodes ──────────────────────────────────────────────────────────
oc label node -l node-role.kubernetes.io/master  portworx.io/node-type=storage     --overwrite
oc label node -l node-role.kubernetes.io/master  portworx.io/run-on-master=true    --overwrite
oc label node -l node-role.kubernetes.io/arbiter portworx.io/node-type=storageless --overwrite

# ── resolve partlabel → raw device, per node ─────────────────────────────
resolve_partlabel() {
  local node="$1"
  oc debug -q "node/$node" -- chroot /host readlink -f /dev/disk/by-partlabel/px-metadata 2>/dev/null \
    | tr -d '\r' | grep -E '^/dev/' | head -1 || true
}

echo "Resolving /dev/disk/by-partlabel/px-metadata per node (via oc debug)..."
MASTER1_META="$(resolve_partlabel "$MASTER1_HOST")"
MASTER2_META="$(resolve_partlabel "$MASTER2_HOST")"
ARBITER_META="$(resolve_partlabel "$ARBITER_HOST")"

for entry in \
  "$MASTER1_HOST|$MASTER1_META" \
  "$MASTER2_HOST|$MASTER2_META" \
  "$ARBITER_HOST|$ARBITER_META"
do
  host="${entry%%|*}"; dev="${entry##*|}"
  if [ -z "$dev" ]; then
    echo "FATAL: could not resolve /dev/disk/by-partlabel/px-metadata on $host." >&2
    echo "       Is the cluster fully installed and have the 98-{0,1}-machineconfig-* MCs rolled?" >&2
    exit 1
  fi
  printf "  %-30s %s\n" "$host" "$dev"
done

# ── generate 98-6-portworx-storagecluster.yaml from portworx-storagecluster.yaml.template ───────────────────────────────
# portworx-storagecluster.yaml.template has one unique token per stanza
# (${MASTER1_META_DEV}, ${MASTER2_META_DEV}, ${ARBITER_META_DEV}); three plain
# sed replaces are enough. The .template is untouched so rerunning this
# script always regenerates the .yaml cleanly from a known-good source.
SRC="$HERE/portworx-storagecluster.yaml.template"
OUT="$HERE/98-6-portworx-storagecluster.yaml"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found" >&2; exit 1; }

sed \
  -e '/^@@ DO NOT/d' \
  -e "s|\${MASTER1_META_DEV}|$MASTER1_META|g" \
  -e "s|\${MASTER2_META_DEV}|$MASTER2_META|g" \
  -e "s|\${ARBITER_META_DEV}|$ARBITER_META|g" \
  "$SRC" > "$OUT"

echo "Generated 98-6-portworx-storagecluster.yaml from .yaml.template with per-node raw device paths."
