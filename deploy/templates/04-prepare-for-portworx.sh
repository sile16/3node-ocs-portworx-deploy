#!/usr/bin/env bash
# Portworx TNA bring-up. Run after `oc get nodes` shows 3 Ready.
# This script is rendered per-site into deploy/sites/<site>/install-portworx.sh
# by deploy/run_before_px_install.sh; run it from there so the adjacent
# 03-/04- manifests are the already-rendered copies for this site.
#   export KUBECONFIG=...; cd deploy/sites/<site> && ./install-portworx.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG:?KUBECONFIG not set}"

# Label by role (matches placement selectors in 04-).
oc label node -l node-role.kubernetes.io/master  portworx.io/node-type=storage     --overwrite
oc label node -l node-role.kubernetes.io/master  portworx.io/run-on-master=true    --overwrite
oc label node -l node-role.kubernetes.io/arbiter portworx.io/node-type=storageless --overwrite