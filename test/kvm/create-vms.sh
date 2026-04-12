#!/usr/bin/env bash
#
# create-vms.sh — define + boot the 3 KVM VMs.
#
# Reads per-role resource spec from vms/<role>.conf and the node inventory
# from vms/nodes.conf. Edit those files to tune the cluster — this script
# contains only the libvirt orchestration logic and workarounds.
#
# Prereqs:
#   1. ./generate-iso.sh succeeded (./generated/agent.x86_64.iso in pool).
#   2. libvirtd running, user in libvirt group.
#   3. default storage pool active.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${HERE}/generated"
VMS_DIR="${HERE}/vms"

LIBVIRT_URI="qemu:///system"
NET_NAME="tna-net"
POOL_NAME="default"
POOL_ISO_NAME="tna-agent.iso"

# ── prereq checks ──────────────────────────────────────────────────────────
ISO="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$POOL_NAME" "$POOL_ISO_NAME" 2>/dev/null || true)"
[ -n "$ISO" ] && [ -f "$ISO" ] || {
  echo "FATAL: pool ISO '${POOL_ISO_NAME}' not found in pool '${POOL_NAME}'" >&2
  echo "       Run ./generate-iso.sh first (it uploads the ISO into the pool)." >&2
  exit 1
}

command -v virt-install >/dev/null || { echo "FATAL: virt-install not installed" >&2; exit 1; }
command -v virsh        >/dev/null || { echo "FATAL: virsh not installed" >&2; exit 1; }

virsh -c "$LIBVIRT_URI" list --all >/dev/null 2>&1 || {
  echo "FATAL: cannot reach $LIBVIRT_URI — are you in the libvirt group? (check: id)" >&2
  exit 1
}

virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" >/dev/null 2>&1 || {
  echo "FATAL: libvirt storage pool '$POOL_NAME' not found." >&2
  echo "       Create it: virsh -c $LIBVIRT_URI pool-define-as default dir --target /var/lib/libvirt/images" >&2
  echo "                  virsh -c $LIBVIRT_URI pool-autostart default" >&2
  echo "                  virsh -c $LIBVIRT_URI pool-start default" >&2
  exit 1
}

[ -f "${VMS_DIR}/nodes.conf" ] || { echo "FATAL: ${VMS_DIR}/nodes.conf not found" >&2; exit 1; }

# ── create tna-net if missing ──────────────────────────────────────────────
# DHCP host reservations are built from vms/nodes.conf so the inventory
# stays the single source of truth. VIPs (.10/.11) sit below the DHCP
# range (.100+) and are never assigned.
if ! virsh -c "$LIBVIRT_URI" net-info "$NET_NAME" >/dev/null 2>&1; then
  echo "=== creating libvirt network '$NET_NAME' (192.168.125.0/24) ==="
  NET_XML="$(mktemp)"
  trap 'rm -f "$NET_XML"' EXIT
  {
    cat <<'EOF'
<network>
  <name>tna-net</name>
  <forward mode='nat'><nat><port start='1024' end='65535'/></nat></forward>
  <bridge name='virbr-tna' stp='on' delay='0'/>
  <ip address='192.168.125.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.125.100' end='192.168.125.200'/>
EOF
    while read -r hostname role mac ip _rest; do
      if [ -z "${hostname:-}" ] || [[ "$hostname" =~ ^# ]]; then continue; fi
      printf "      <host mac='%s' name='%s' ip='%s'/>\n" "$mac" "$hostname" "$ip"
    done < "${VMS_DIR}/nodes.conf"
    cat <<'EOF'
    </dhcp>
  </ip>
</network>
EOF
  } > "$NET_XML"
  virsh -c "$LIBVIRT_URI" net-define "$NET_XML"
  virsh -c "$LIBVIRT_URI" net-autostart "$NET_NAME"
  virsh -c "$LIBVIRT_URI" net-start "$NET_NAME"
  rm -f "$NET_XML"; trap - EXIT
else
  if virsh -c "$LIBVIRT_URI" net-info "$NET_NAME" | awk -F: '/^Active/{gsub(/ /,"",$2); print $2}' | grep -qx yes; then
    echo "=== '$NET_NAME' already active — reusing ==="
  else
    echo "=== starting existing '$NET_NAME' network ==="
    virsh -c "$LIBVIRT_URI" net-start "$NET_NAME"
  fi
fi

# ── start autostart-watcher (libvirt on_poweroff=destroy workaround) ──────
#
# The agent-based installer calls poweroff after writing the image to disk,
# expecting firmware to reboot into the installed OS. libvirt's default
# lifecycle policy is on_poweroff=destroy, which eats the domain.
#
# We cannot fix this at virt-install time: --cdrom internally forces
# on_reboot=destroy, and libvirt rejects any combination with
# on_poweroff=restart. So a background watcher polls `virsh list` every
# 2 s and `virsh start`s any shut-off tna-* domain.
"${HERE}/host-setup/autostart-watcher.sh" start >/dev/null 2>&1 || {
  echo "WARN: autostart-watcher.sh did not start cleanly — install may stall"
  echo "      if the agent installer powers off a VM. Start it manually:"
  echo "      ${HERE}/host-setup/autostart-watcher.sh start"
}

# ── define-and-start each VM ───────────────────────────────────────────────
#
# virt-install with --cdrom blocks forever (agent ISO never calls
# shutdown-on-complete). We background it, poll `virsh domstate` until
# "running", then kill the wrapper. libvirtd keeps the domain alive.
#
# Firmware: non-Secure-Boot OVMF (.fd, not .ms.fd). Portworx px.ko is
# unsigned — SB blocks the module load with "Key was rejected by service".

declare -a VI_NAMES

run_virt_install() {
  local name="$1" ram="$2" vcpus="$3" mac="$4"; shift 4
  VI_NAMES+=("$name")
  echo "=== defining VM $name (ram=${ram}MiB vcpus=$vcpus mac=$mac) ==="

  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram" \
    --vcpus "$vcpus" \
    --cpu host-passthrough \
    --os-variant fedora-coreos-stable \
    --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd,menu=on \
    --network "network=${NET_NAME},mac=${mac},model=virtio" \
    --cdrom "$ISO" \
    --graphics vnc,listen=127.0.0.1 \
    --noautoconsole \
    --wait -1 \
    --check disk_size=off,path_in_use=off \
    "$@" >/tmp/virt-install-${name}.log 2>&1 &
  local pid=$!

  local ok=0
  for _ in $(seq 1 60); do
    if virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -q running; then
      ok=1; break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "FATAL: virt-install for $name exited before domain was running." >&2
      echo "       Log: /tmp/virt-install-${name}.log" >&2
      tail -20 "/tmp/virt-install-${name}.log" >&2
      exit 1
    fi
    sleep 1
  done
  if [ "$ok" -ne 1 ]; then
    echo "FATAL: domain $name did not reach running state within 60s." >&2
    kill "$pid" 2>/dev/null || true
    exit 1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "  $name: running"
  sleep 2
}

# Iterate the node inventory. For each node:
#   1. source vms/<role>.conf for RAM / vCPU / disk shape
#   2. build --disk args (byte-precise pre-create for arbiter, size=N GiB
#      for masters)
#   3. virt-install
while read -r hostname role mac ip _rest; do
  if [ -z "${hostname:-}" ] || [[ "$hostname" =~ ^# ]]; then continue; fi

  ROLE_CONF="${VMS_DIR}/${role}.conf"
  [ -f "$ROLE_CONF" ] || { echo "FATAL: role conf not found: $ROLE_CONF" >&2; exit 1; }
  # reset per-node, then source
  RAM_MIB= VCPUS= DISK_BUS= BOOT_SIZE_GIB= BOOT_SIZE_BYTES= DATA_SIZE_GIB=
  # shellcheck disable=SC1090
  source "$ROLE_CONF"

  virt_args=()

  if [ "$DISK_BUS" = "scsi" ]; then
    # virtio-scsi needs an explicit controller declaration.
    virt_args+=(--controller "scsi,model=virtio-scsi")
  fi

  # Boot disk: byte-precise pre-create when BOOT_SIZE_BYTES is set (arbiter's
  # 256 GB-base-10 SSD sim); otherwise virt-install pool=...,size=N GiB.
  if [ -n "${BOOT_SIZE_BYTES:-}" ]; then
    BOOT_VOL="${hostname}-boot.qcow2"
    if ! virsh -c "$LIBVIRT_URI" vol-info --pool "$POOL_NAME" "$BOOT_VOL" >/dev/null 2>&1; then
      echo "=== pre-creating boot volume $BOOT_VOL (${BOOT_SIZE_BYTES} bytes) ==="
      virsh -c "$LIBVIRT_URI" vol-create-as "$POOL_NAME" "$BOOT_VOL" "$BOOT_SIZE_BYTES" --format qcow2
    fi
    virt_args+=(--disk "vol=${POOL_NAME}/${BOOT_VOL},bus=${DISK_BUS},serial=${hostname}-boot")
  else
    virt_args+=(--disk "pool=${POOL_NAME},size=${BOOT_SIZE_GIB},format=qcow2,bus=${DISK_BUS},serial=${hostname}-boot")
  fi

  # Optional data disk.
  if [ "${DATA_SIZE_GIB:-0}" -gt 0 ]; then
    virt_args+=(--disk "pool=${POOL_NAME},size=${DATA_SIZE_GIB},format=qcow2,bus=${DISK_BUS},serial=${hostname}-data")
  fi

  run_virt_install "$hostname" "$RAM_MIB" "$VCPUS" "$mac" "${virt_args[@]}"
done < "${VMS_DIR}/nodes.conf"

# Final sanity pass.
for name in "${VI_NAMES[@]}"; do
  if ! virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -q running; then
    echo "FATAL: $name is not running after create-vms.sh — something regressed." >&2
    exit 1
  fi
done

# ── summary ────────────────────────────────────────────────────────────────
echo
echo "=== VMs defined and booted ==="
echo
printf "  %-26s %-9s %-19s %s\n" "Name" "Role" "MAC" "IP"
printf "  %-26s %-9s %-19s %s\n" "----" "----" "---" "--"
while read -r hostname role mac ip _rest; do
  if [ -z "${hostname:-}" ] || [[ "$hostname" =~ ^# ]]; then continue; fi
  printf "  %-26s %-9s %-19s %s\n" "$hostname" "$role" "$mac" "$ip"
done < "${VMS_DIR}/nodes.conf"
cat <<EOF

Cluster endpoints after install:
  API VIP       : 192.168.125.10       (api.tna.example.local)
  Ingress VIP   : 192.168.125.11       (*.apps.tna.example.local)
  kubeconfig    : ${GEN}/auth/kubeconfig
  kubeadmin pw  : ${GEN}/auth/kubeadmin-password

Watch progress:
  virsh -c $LIBVIRT_URI list --all
  openshift-install agent wait-for bootstrap-complete --dir=${GEN}
  openshift-install agent wait-for install-complete  --dir=${GEN}

When done:
  ./collect-cluster-state.sh
  ./teardown.sh
EOF
