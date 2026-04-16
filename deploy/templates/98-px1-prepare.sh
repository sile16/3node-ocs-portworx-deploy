#!/usr/bin/env bash
# Apply Kubernetes node labels for StorageCluster placement nodeAffinity.
# Idempotent — safe to re-run.

set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG not set}"

oc label node -l node-role.kubernetes.io/master  portworx.io/node-type=storage     --overwrite
oc label node -l node-role.kubernetes.io/master  portworx.io/run-on-master=true    --overwrite
oc label node -l node-role.kubernetes.io/arbiter portworx.io/node-type=storageless --overwrite
