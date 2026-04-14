#!/usr/bin/env bash
# pxctl status + PVC bind/write/read against px-csi-replicated. Override SC=<name>.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$(cd "$HERE/.." && pwd)/generated/auth/kubeconfig}"

OC="${OC:-$HOME/bin/oc}"
[ -x "$OC" ] || OC=oc

SC="${SC:-px-csi-replicated}"   # default RF=2 storage class; override via SC env
NS="default"
PVC_NAME="px-smoketest"
POD_NAME="px-smoketest"

cleanup() {
  echo
  echo "=== cleanup ==="
  "$OC" -n "$NS" delete pod "$POD_NAME" --ignore-not-found --wait=false
  "$OC" -n "$NS" delete pvc "$PVC_NAME" --ignore-not-found --wait=false
}
trap cleanup EXIT

echo "=== pxctl status ==="
PX_POD=$("$OC" -n portworx get pods -l name=portworx -o name 2>/dev/null | head -1)
if [ -n "$PX_POD" ]; then
  "$OC" -n portworx exec "$PX_POD" -c portworx -- /opt/pwx/bin/pxctl status 2>&1 | head -30 || true
else
  echo "  (no portworx daemonset pod found — did you render deploy/sites/<site>/ and apply 98-px1 → 98-px2 → 98-px3 → 98-px4?)"
  exit 1
fi

echo
echo "=== available StorageClasses ==="
"$OC" get sc
echo
echo "  (using SC: $SC — set SC=<name> env to override)"

# verify SC exists
if ! "$OC" get sc "$SC" >/dev/null 2>&1; then
  echo "FATAL: StorageClass '$SC' not found" >&2
  exit 1
fi

echo
echo "=== creating PVC + pod ==="
"$OC" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS
spec:
  containers:
    - name: busybox
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["/bin/sh","-c","echo hello-portworx > /data/hello && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC_NAME
EOF

echo
echo "=== waiting for pod Ready (up to 2 min) ==="
"$OC" -n "$NS" wait --for=condition=Ready pod/"$POD_NAME" --timeout=2m

echo
echo "=== verifying sentinel write/read ==="
got=$("$OC" -n "$NS" exec "$POD_NAME" -- cat /data/hello 2>&1)
if [ "$got" = "hello-portworx" ]; then
  echo "  OK: /data/hello = '$got'"
else
  echo "  FAIL: expected 'hello-portworx', got '$got'"
  exit 1
fi

echo
echo "=== pxctl volume list (should show our PVC) ==="
"$OC" -n portworx exec "$PX_POD" -c portworx -- /opt/pwx/bin/pxctl volume list 2>&1 | head -20 || true

echo
echo "=== PVC + PV ==="
"$OC" -n "$NS" get pvc "$PVC_NAME"
"$OC" get pv | grep "$PVC_NAME" || true

echo
echo "🏆 Portworx smoke test PASSED"
