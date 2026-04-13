#!/usr/bin/env bash
#
# collect-cluster-state.sh — post-install validation
#
# SSHes to each of the 3 nodes as `core` and dumps the things that prove
# (or disprove) the partition mechanism worked in the real OCP cluster:
#
#   1. lsblk with PARTLABEL column
#   2. /dev/disk/by-partlabel/ symlinks
#   3. `sudo blkid` probe output
#   4. `sudo sgdisk --print` of the boot device
#   5. df -h / findmnt (rootfs should be ~120 GiB, /var/lib/portworx NOT a mount)
#   6. kubelet + crio status
#
# All output lands in ./logs/<timestamp>/{node-a,node-b,arbiter}.log so it
# can be handed off to the customer or diffed across runs.
#
# Also snapshots cluster-level state from the host via kubeconfig:
#   - `oc get nodes -o wide`
#   - `oc get clusterversion`
#   - `oc get co` (ClusterOperators)
#   - `oc get mcp`  (MachineConfigPools — confirms our 98-px-storage-* applied)
#
# The SSH key Ignition injects into the core user's authorized_keys is
# ~/.ssh/id_rsa.pub (via generate-iso.sh). Plain ssh -i against the
# DHCP-reserved IP is the only code path that uses it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${HERE}/generated"
KUBECONFIG_PATH="${GEN}/auth/kubeconfig"

SSH_KEY="${HOME}/.ssh/id_rsa"
[ -f "$SSH_KEY" ] || { echo "FATAL: ssh key missing at $SSH_KEY" >&2; exit 1; }

SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${HERE}/logs/${TS}"
mkdir -p "$LOG_DIR"
echo "=== writing logs to $LOG_DIR ==="

# Node-name → IP and boot device
declare -A NODE_IP=(
  [master-1.example.local]=192.168.125.20
  [master-2.example.local]=192.168.125.21
  [arbiter-1.example.local]=192.168.125.22
)
declare -A NODE_BOOT=(
  [master-1.example.local]=/dev/vda
  [master-2.example.local]=/dev/vda
  [arbiter-1.example.local]=/dev/sda
)

collect_one() {
  local name="$1" ip="$2" boot="$3"
  local out="${LOG_DIR}/${name}.log"
  echo "=== ${name} @ ${ip} (boot=${boot}) ==="
  {
    echo "### $(date -Is) ${name} @ ${ip}"
    echo "### boot device: ${boot}"
    echo
    # Use a bash -s heredoc so all commands run inside a single ssh session.
    ssh "${SSH_OPTS[@]}" "core@${ip}" "BOOT=${boot} bash -s" <<'REMOTE' 2>&1 || echo "(ssh failed)"
set +e
echo "### hostname"; hostname
echo "### kernel";   uname -r

echo
echo "### lsblk (PARTLABEL column)"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT

echo
echo "### /dev/disk/by-partlabel/"
ls -l /dev/disk/by-partlabel/ 2>/dev/null || echo "(no by-partlabel dir)"

echo
echo "### sudo blkid (probe — picks up fresh partitions that cache misses)"
sudo blkid 2>/dev/null || true

echo
echo "### sudo sgdisk --print ${BOOT}"
sudo sgdisk --print "${BOOT}" 2>/dev/null || echo "(sgdisk failed on ${BOOT})"

echo
echo "### px-metadata partlabel symlink check (expected on every node)"
if [ -e /dev/disk/by-partlabel/px-metadata ]; then
  echo "PASS: /dev/disk/by-partlabel/px-metadata -> $(readlink -f /dev/disk/by-partlabel/px-metadata)"
else
  echo "FAIL: /dev/disk/by-partlabel/px-metadata missing"
fi

echo
echo "### px-data partlabel symlink check (expected on masters only)"
case "$(hostname)" in
  master-*)
    if [ -e /dev/disk/by-partlabel/px-data ]; then
      echo "PASS: /dev/disk/by-partlabel/px-data -> $(readlink -f /dev/disk/by-partlabel/px-data)"
    else
      echo "FAIL: /dev/disk/by-partlabel/px-data missing on master"
    fi
    ;;
  *)
    if [ -e /dev/disk/by-partlabel/px-data ]; then
      echo "WARN: /dev/disk/by-partlabel/px-data unexpectedly present on non-master"
    else
      echo "OK: no px-data on non-master (expected — arbiter is storageless)"
    fi
    ;;
esac

echo
echo "### df -h"
df -h /sysroot / /var 2>/dev/null || df -h

echo
echo "### /var/lib/portworx mount check (should NOT be a separate mount)"
if findmnt /var/lib/portworx >/dev/null 2>&1; then
  echo "FAIL: /var/lib/portworx is a separate mount"
  findmnt /var/lib/portworx
else
  echo "OK: /var/lib/portworx is not a separate mount"
fi

echo
echo "### systemctl kubelet crio"
systemctl is-active kubelet 2>&1
systemctl is-active crio    2>&1

echo
echo "### rpm-ostree status (first 30 lines)"
sudo rpm-ostree status 2>/dev/null | head -30 || true
REMOTE
  } > "$out" 2>&1
  echo "  -> ${out}"
}

for name in master-1.example.local master-2.example.local arbiter-1.example.local; do
  collect_one "$name" "${NODE_IP[$name]}" "${NODE_BOOT[$name]}"
done

# ── cluster-level snapshot via kubeconfig ──────────────────────────────────
if [ -r "$KUBECONFIG_PATH" ]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
  CLUSTER_LOG="${LOG_DIR}/cluster.log"
  echo "=== cluster-level snapshot (via ${KUBECONFIG_PATH}) ==="
  {
    echo "### oc get nodes -o wide"
    oc get nodes -o wide 2>&1 || true
    echo
    echo "### oc get clusterversion"
    oc get clusterversion 2>&1 || true
    echo
    echo "### oc get co"
    oc get co 2>&1 || true
    echo
    echo "### oc get mcp"
    oc get mcp 2>&1 || true
    echo
    echo "### MachineConfig: 98-px-storage-master"
    oc get mc 98-px-storage-master -o yaml 2>&1 || true
    echo
    echo "### MachineConfig: 98-px-storage-arbiter"
    oc get mc 98-px-storage-arbiter -o yaml 2>&1 || true
  } > "$CLUSTER_LOG" 2>&1
  echo "  -> ${CLUSTER_LOG}"
else
  echo "(skipping cluster-level snapshot — kubeconfig not found at $KUBECONFIG_PATH)"
fi

echo
echo "=== done — artifacts in ${LOG_DIR} ==="
