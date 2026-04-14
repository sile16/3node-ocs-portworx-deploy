#!/usr/bin/env bash
# Label masters + arbiter so 98-px4-storagecluster's placement nodeAffinity
# matches. The StorageCluster references the px-metadata partition via its
# partlabel symlink directly — no per-node raw-device resolution needed
# (PX 3.6.0 handles the symlink fine as long as useAllWithPartitions is off;
# see the header comment in 98-px4-storagecluster.yaml).
#
# Must run AFTER the cluster is installed (MCs rolled so master + arbiter
# role labels exist). Idempotent.

set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG not set}"

oc label node -l node-role.kubernetes.io/master  portworx.io/node-type=storage     --overwrite
oc label node -l node-role.kubernetes.io/master  portworx.io/run-on-master=true    --overwrite
oc label node -l node-role.kubernetes.io/arbiter portworx.io/node-type=storageless --overwrite
