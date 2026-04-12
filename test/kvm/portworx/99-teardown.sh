#!/usr/bin/env bash
# Remove Portworx from the cluster (idempotent). Does not touch px-metadata/px-data partitions.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$(cd "$HERE/.." && pwd)/generated/auth/kubeconfig}"

OC="${OC:-$HOME/bin/oc}"
[ -x "$OC" ] || OC=oc

echo "=== removing smoke-test artifacts (if still around) ==="
"$OC" -n default delete pod px-smoketest --ignore-not-found --wait=false
"$OC" -n default delete pvc px-smoketest --ignore-not-found --wait=false

echo
echo "=== deleting StorageCluster (operator cleans up DaemonSet + volumes) ==="
"$OC" -n portworx delete storagecluster px-cluster --ignore-not-found
# Give operator time to reconcile teardown
for i in $(seq 1 24); do
  pods=$("$OC" -n portworx get pods --no-headers 2>/dev/null | grep -v portworx-operator | wc -l)
  printf '  iter %02d: non-operator pods remaining=%s\n' "$i" "$pods"
  [ "$pods" -eq 0 ] && break
  sleep 5
done

echo
echo "=== removing node labels ==="
for n in master-1.example.local master-2.example.local arbiter-1.example.local; do
  "$OC" label node "$n" portworx.io/node-type- portworx.io/run-on-master- --ignore-not-found 2>&1 | sed 's/^/  /'
done

echo
echo "=== deleting Subscription + CSV ==="
csv=$("$OC" -n portworx get subscription portworx-certified -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
"$OC" -n portworx delete subscription portworx-certified --ignore-not-found
[ -n "$csv" ] && "$OC" -n portworx delete csv "$csv" --ignore-not-found || true

echo
echo "=== deleting OperatorGroup + namespace ==="
"$OC" -n portworx delete operatorgroup portworx --ignore-not-found
"$OC" delete namespace portworx --ignore-not-found

echo
echo "=== CRDs (left in place — delete manually if desired) ==="
"$OC" get crd | grep -E 'libopenstorage' || echo "  (no portworx CRDs remaining)"

echo
echo "Teardown done. px-metadata + px-data partitions on every node are untouched."
