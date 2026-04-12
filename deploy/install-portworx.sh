#!/usr/bin/env bash
# Portworx TNA bring-up. Run after `oc get nodes` shows 3 Ready.
#   export KUBECONFIG=...; cd deploy && ./install-portworx.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG:?KUBECONFIG not set}"

# Label by role (matches placement selectors in 04-).
oc label node -l node-role.kubernetes.io/master  portworx.io/node-type=storage     --overwrite
oc label node -l node-role.kubernetes.io/master  portworx.io/run-on-master=true    --overwrite
oc label node -l node-role.kubernetes.io/arbiter portworx.io/node-type=storageless --overwrite

# Operator via OLM.
oc apply -f "${HERE}/03-portworx-subscription.yaml"

# OLM takes time to reconcile the Subscription → InstallPlan → CSV → Deployment.
# `oc wait` fails fast on a missing resource, so poll for the Deployment first.
echo "waiting for portworx-operator deployment to be created by OLM..."
for _ in $(seq 1 60); do
  oc -n portworx get deployment portworx-operator >/dev/null 2>&1 && break
  sleep 5
done
if ! oc -n portworx get deployment portworx-operator >/dev/null 2>&1; then
  echo "FATAL: portworx-operator deployment not created within 5 minutes" >&2
  echo "       Check: oc -n portworx get subscription,installplan,csv" >&2
  exit 1
fi
if ! oc -n portworx wait --for=condition=Available deployment/portworx-operator --timeout=10m; then
  echo "FATAL: portworx-operator did not become Available within 10 minutes" >&2
  echo "       Check: oc -n portworx get pods,events,subscription,installplan,csv" >&2
  exit 1
fi

# StorageCluster TNA requires exact nodeName selectors, so fill them from live state.
MASTERS=( $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}') )
ARBITER=$(oc get nodes -l node-role.kubernetes.io/arbiter -o jsonpath='{.items[0].metadata.name}')

# GET NODE hostanmes.
[ "${#MASTERS[@]}" -eq 2 ] || { echo "FATAL: expected 2 master nodes, found ${#MASTERS[@]}: ${MASTERS[*]:-(none)}" >&2; exit 1; }
[ -n "$ARBITER" ]          || { echo "FATAL: no arbiter node found" >&2; exit 1; }

# Check nodes are READY
for node in "${MASTERS[@]}" "$ARBITER"; do
  ready=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [ "$ready" = "True" ] || { echo "FATAL: node $node is not Ready" >&2; exit 1; }
done

# replace names in file to a temp file.
rendered_storagecluster="$(mktemp)"
trap 'rm -f "$rendered_storagecluster"' EXIT
sed -e "s|__MASTER_0_NODE_NAME__|${MASTERS[0]}|" \
    -e "s|__MASTER_1_NODE_NAME__|${MASTERS[1]}|" \
    -e "s|__ARBITER_NODE_NAME__|${ARBITER}|" \
    "${HERE}/04-portworx-storagecluster.yaml" > "$rendered_storagecluster"

# check to make sure our replace worked — scope to `nodeName:` lines so the
# header comment (which documents the __*_NODE_NAME__ convention) doesn't trip us.
if grep -E '^[[:space:]]*nodeName:.*__.*_NODE_NAME__' "$rendered_storagecluster"; then
  echo "FATAL: unreplaced nodeName placeholder remains in rendered StorageCluster" >&2
  exit 1
fi

# apply the file
oc apply -f "$rendered_storagecluster"

# The Portworx operator only transitions `.status.phase` to "Running" once
# Install=Completed AND RuntimeState=Online, so this single wait covers both.
# (There is no "Ready" condition on StorageCluster — don't be tempted to add one.)
if ! oc -n portworx wait --for=jsonpath='{.status.phase}'=Running storagecluster/px-cluster --timeout=20m; then
  echo "FATAL: px-cluster did not reach phase=Running within 20 minutes" >&2
  echo "       Check: oc -n portworx get storagecluster,pods; oc -n portworx describe storagecluster px-cluster" >&2
  exit 1
fi

# Optional site-specific license / px-central registration (gitignored).
if [ -x "${HERE}/99-portworx-register.sh" ]; then
  echo "=== running 99-portworx-register.sh ==="
  "${HERE}/99-portworx-register.sh"
fi
