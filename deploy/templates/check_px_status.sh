#!/usr/bin/env bash
# One-shot health snapshot. Answers, in order:
#   1. Is the OCP cluster reachable and healthy enough to install on?
#   2. What phase is the Portworx StorageCluster in?
#   3. Are the px-cluster pods Ready? Any CrashLoopBackOff?
#   4. Any pxctl alerts, and do any match a KNOWN-BAD pattern from
#      README → Known-broken-configs?

set -uo pipefail
: "${KUBECONFIG:?KUBECONFIG not set}"

ok()   { printf '  [ OK ] %s\n'   "$*"; }
warn() { printf '  [WARN] %s\n'   "$*"; }
fail() { printf '  [FAIL] %s\n'   "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

# ── OCP cluster ──────────────────────────────────────────────────────────
section "OpenShift cluster"
if ! oc get --raw /readyz >/dev/null 2>&1 && ! oc get nodes >/dev/null 2>&1; then
  fail "cluster API unreachable (check KUBECONFIG / network / VIP)"
  exit 1
fi

nodes_total=$(oc get nodes --no-headers 2>/dev/null | wc -l)
nodes_ready=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
if [ "$nodes_ready" -eq "$nodes_total" ] && [ "$nodes_total" -gt 0 ]; then
  ok "nodes: $nodes_ready/$nodes_total Ready"
else
  fail "nodes: $nodes_ready/$nodes_total Ready"
  oc get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{printf "         - %s %s\n",$1,$2}'
fi

# AVAILABLE = $3, PROGRESSING = $4, DEGRADED = $5 in `oc get co --no-headers`
bad_co=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $5=="True" {printf "         - %s avail=%s prog=%s deg=%s\n",$1,$3,$4,$5}')
if [ -z "$bad_co" ]; then
  ok "clusteroperators: all Available, none Degraded"
else
  fail "clusteroperators with issues:"
  echo "$bad_co"
fi

# ── Portworx namespace / operator ────────────────────────────────────────
if ! oc get ns portworx >/dev/null 2>&1; then
  section "Portworx"
  warn "namespace 'portworx' not found — Portworx not installed yet"
  exit 0
fi

section "Portworx StorageCluster"
phase=$(oc -n portworx get storagecluster px-cluster -o jsonpath='{.status.phase}' 2>/dev/null || true)
case "${phase:-}" in
  "")           warn "StorageCluster 'px-cluster' not found (apply 98-px4-* yet?)" ;;
  Running)      ok   "phase: Running" ;;
  Initializing) warn "phase: Initializing (in progress)" ;;
  Failed)       fail "phase: Failed" ;;
  Degraded)     fail "phase: Degraded" ;;
  *)            warn "phase: $phase" ;;
esac

# Per-node StorageNode status — jsonpath (positional awk breaks when
# StorageNode columns like ID/VERSION are still empty during early init
# and the AGE column slides into a status position).
if oc -n portworx get storagenode >/dev/null 2>&1; then
  while IFS=$'\t' read -r name status; do
    [ -n "$name" ] || continue
    case "$status" in
      Online)       ok   "node $name: Online" ;;
      Initializing) warn "node $name: Initializing" ;;
      "")           warn "node $name: (no phase reported yet)" ;;
      *)            fail "node $name: $status" ;;
    esac
  done < <(oc -n portworx get storagenode \
             -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null)
fi

# ── Portworx pods ────────────────────────────────────────────────────────
section "Portworx pods"
px_pods=$(oc -n portworx get pods -l name=portworx --no-headers 2>/dev/null)
if [ -z "$px_pods" ]; then
  warn "no px-cluster pods scheduled yet"
else
  while IFS= read -r line; do
    set -- $line
    name="$1"; ready="$2"; status="$3"; restarts="$4"
    case "$status" in
      Running)
        [ "${ready%%/*}" = "${ready##*/}" ] \
          && ok   "$name  $ready $status (restarts=$restarts)" \
          || warn "$name  $ready $status (restarts=$restarts)"
        ;;
      *)  fail "$name  $ready $status (restarts=$restarts)" ;;
    esac
  done <<< "$px_pods"
fi

# Any pod in the ns in a bad state (covers portworx-api / px-csi-ext / etc.)
bad_pods=$(oc -n portworx get pods --no-headers 2>/dev/null \
             | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull/ {print}')
if [ -n "$bad_pods" ]; then
  section "pods in trouble (all of namespace portworx)"
  while IFS= read -r line; do fail "$line"; done <<< "$bad_pods"
fi

# ── pxctl alerts + known-bad pattern match ───────────────────────────────
section "pxctl alerts"
POD=$(oc get pods -n portworx -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  warn "no px-cluster pod available to query pxctl alerts"
else
  alerts=$(oc -n portworx rsh "$POD" /opt/pwx/bin/pxctl alerts show 2>&1 \
             | sed '/^$/d')
  if [ -z "$alerts" ] || echo "$alerts" | grep -qi "No alerts"; then
    ok "no pxctl alerts"
  else
    echo "$alerts" | head -25 | sed 's/^/    /'

    # Known-bad pattern flags — mirror README → Known-broken-configs.
    if echo "$alerts" | grep -qiE "pwx[0-9]+.*has a filesystem|filesystem on it with labels"; then
      fail "SYMPTOM: systemMetadataDevice symlink-resolution bug — the symlink target is also being enumerated as storage and collides on init. Switch to a raw-path systemMetadataDevice."
    fi
    if echo "$alerts" | grep -qiE "STORAGE_MEDIUM_MAGNETIC|not supported for metadata pool|use SSD or NVMe"; then
      fail "SYMPTOM: Wrong media type — metadata pool sees a rotational device. Bare metal firmware should report non-rotational; in KVM, ship the 99-libvirt-rotational-*.yaml MC workaround."
    fi
    if echo "$alerts" | grep -qiE "px\.ko.*(Cannot allocate memory|Key was rejected|not signed)"; then
      fail "SYMPTOM: px.ko kernel module failed to load. Check: Secure Boot disabled in BIOS, and node has ≥8 GiB RAM (per README pre-install checklist)."
    fi
    if echo "$alerts" | grep -qiE "Node is not in quorum|Waiting to connect to peer"; then
      warn "SYMPTOM: Node not in quorum — peer connectivity on TCP 17002 may be blocked, or the other nodes haven't initialized yet."
    fi
    if echo "$alerts" | grep -qiE "Storage failed initialization|NodeInitFailure"; then
      fail "SYMPTOM: Storage init failed — see the accompanying NodeInitFailure alert above for the specific device, and cross-ref README Known-broken-configs."
    fi
  fi
fi

echo
