#!/usr/bin/env bash
#
# envsetup.sh — one-time KVM host preparation for test/kvm
#
# Idempotent. Safe to re-run. Fixes anything that's missing; touches nothing
# that's already correct.
#
# Steps (each verifies then fixes if needed):
#   1. VT-x / KVM modules present and usable
#   2. libvirt + qemu + virt-install + ovmf apt packages installed
#   3. libvirtd running and user is in the `libvirt` group
#   4. default libvirt storage pool exists + active at /var/lib/libvirt/images
#   5. tna-net libvirt network exists + active (192.168.125.0/24 + DHCP host reservations)
#
# The script explicitly warns when a step would require logging out (group
# membership change) rather than silently failing.
#
# Anything in this file is Ubuntu / Debian-family specific. For RHEL/Fedora,
# swap `apt install` → `dnf install` and translate the package names.

set -euo pipefail

LIBVIRT_URI="qemu:///system"
POOL_NAME="default"
POOL_DIR="/var/lib/libvirt/images"
NET_NAME="tna-net"

APT_PKGS=(
  libvirt-daemon-system libvirt-clients
  virtinst virt-manager
  qemu-kvm qemu-system-x86 qemu-utils
  ovmf bridge-utils
  # used by host-setup/registry-cache.sh for the pull-through quay.io mirror
  docker.io
  openssl   # self-signed cert for the mirror
  curl      # health checks
  python3   # yaml validation in build-iso.sh dry-runs + other helpers
)

need_sudo() {
  if [ "$EUID" -eq 0 ]; then return 0; fi
  if sudo -n true 2>/dev/null; then return 0; fi
  echo "NOTE: the next step needs sudo — you will be prompted for your password."
}

step() { printf '\n=== %s ===\n' "$*"; }

# ── 1. VT-x ────────────────────────────────────────────────────────────────
step "1/5 CPU virtualization"
VMX_COUNT="$(grep -c vmx /proc/cpuinfo || true)"
SVM_COUNT="$(grep -c svm /proc/cpuinfo || true)"
if [ "$VMX_COUNT" -eq 0 ] && [ "$SVM_COUNT" -eq 0 ]; then
  echo "FATAL: CPU has neither vmx (Intel) nor svm (AMD) virtualization flags."
  echo "       Enable VT-x / AMD-V in BIOS and reboot."
  exit 1
fi
echo "  OK — $((VMX_COUNT + SVM_COUNT)) virtualization-capable CPU threads"

if [ -e /dev/kvm ]; then
  echo "  OK — /dev/kvm exists"
else
  echo "FATAL: /dev/kvm does not exist. Is the kvm kernel module loaded?"
  exit 1
fi

# ── 2. apt packages ────────────────────────────────────────────────────────
step "2/5 apt packages"
MISSING=()
for p in "${APT_PKGS[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
    MISSING+=("$p")
  fi
done
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "  OK — all ${#APT_PKGS[@]} packages already installed"
else
  echo "  MISSING: ${MISSING[*]}"
  need_sudo
  sudo apt update
  sudo apt install -y "${MISSING[@]}"
fi

# ── 3. libvirtd + group ────────────────────────────────────────────────────
step "3/5 libvirtd + libvirt group"
if ! systemctl is-active libvirtd >/dev/null; then
  echo "  libvirtd inactive — enabling + starting"
  need_sudo
  sudo systemctl enable --now libvirtd
fi
echo "  OK — libvirtd active"

if ! getent group libvirt | grep -qw "$USER"; then
  echo "  $USER is NOT in the libvirt group — adding"
  need_sudo
  sudo usermod -aG libvirt "$USER"
  echo
  echo "  !! IMPORTANT !!"
  echo "  You must now log out and log back in (or run 'newgrp libvirt') for the"
  echo "  libvirt group to take effect in your shell. Re-run this script afterward"
  echo "  to continue env setup."
  exit 0
fi

if ! id -nG "$USER" | grep -qw libvirt; then
  echo "  $USER is in /etc/group's libvirt entry but the CURRENT shell hasn't"
  echo "  picked it up (usermod -aG only applies to NEW logins)."
  echo "  Log out/in OR run 'newgrp libvirt' and re-run this script."
  exit 1
fi

if ! virsh -c "$LIBVIRT_URI" list --all >/dev/null 2>&1; then
  echo "FATAL: cannot reach $LIBVIRT_URI even though group is effective."
  echo "       Check 'systemctl status libvirtd' and '/var/log/libvirt/libvirtd.log'."
  exit 1
fi
echo "  OK — $USER can talk to $LIBVIRT_URI without sudo"

# ── 4. default storage pool ────────────────────────────────────────────────
step "4/5 default storage pool ($POOL_NAME → $POOL_DIR)"
if virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" >/dev/null 2>&1; then
  echo "  OK — pool '$POOL_NAME' already defined"
else
  echo "  defining pool '$POOL_NAME' at $POOL_DIR"
  virsh -c "$LIBVIRT_URI" pool-define-as "$POOL_NAME" dir --target "$POOL_DIR"
  virsh -c "$LIBVIRT_URI" pool-autostart "$POOL_NAME"
fi

if virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" | awk -F: '/^State/{gsub(/ /,"",$2); print $2}' | grep -qx running; then
  echo "  OK — pool active"
else
  echo "  starting pool '$POOL_NAME'"
  virsh -c "$LIBVIRT_URI" pool-start "$POOL_NAME"
fi

# ── 5. tna-net libvirt network ─────────────────────────────────────────────
step "5/5 tna-net libvirt network (192.168.125.0/24)"
if virsh -c "$LIBVIRT_URI" net-info "$NET_NAME" >/dev/null 2>&1; then
  echo "  OK — network '$NET_NAME' already defined"
else
  echo "  defining network '$NET_NAME'"
  NET_XML="$(mktemp)"; trap 'rm -f "$NET_XML"' EXIT
  cat > "$NET_XML" <<'EOF'
<network>
  <name>tna-net</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-tna' stp='on' delay='0'/>
  <ip address='192.168.125.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.125.100' end='192.168.125.200'/>
      <host mac='52:54:00:12:34:01' name='master-1.example.local' ip='192.168.125.20'/>
      <host mac='52:54:00:12:34:02' name='master-2.example.local' ip='192.168.125.21'/>
      <host mac='52:54:00:12:34:03' name='arbiter-1.example.local' ip='192.168.125.22'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh -c "$LIBVIRT_URI" net-define "$NET_XML"
  virsh -c "$LIBVIRT_URI" net-autostart "$NET_NAME"
  rm -f "$NET_XML"; trap - EXIT
fi

if virsh -c "$LIBVIRT_URI" net-info "$NET_NAME" | awk -F: '/^Active/{gsub(/ /,"",$2); print $2}' | grep -qx yes; then
  echo "  OK — network active"
else
  echo "  starting network '$NET_NAME'"
  virsh -c "$LIBVIRT_URI" net-start "$NET_NAME"
fi

# ── 6. dockerd (used only by the registry cache, optional) ───────────────
step "6/6 dockerd (for host-setup/registry-cache.sh)"
if ! systemctl is-active docker >/dev/null 2>&1; then
  echo "  dockerd inactive — enabling + starting"
  need_sudo
  sudo systemctl enable --now docker
fi
echo "  OK — dockerd active"

# Note: we intentionally do NOT add the user to the docker group here.
# The registry-cache.sh helper prefixes its docker calls with sudo, which is
# safer than adding $USER to a group that grants root-equivalent access.

echo
echo "=== env is ready ==="
echo "Next (full libvirt flow):"
echo "  ./host-setup/registry-cache.sh up      # (optional) pull-through quay.io mirror"
echo "  ./host-setup/autostart-watcher.sh start  # safety net for agent-installer poweroff"
echo "  ./generate-iso.sh                      # build agent.x86_64.iso + upload to pool"
echo "  ./create-vms.sh                        # boot the 3 VMs"
echo "  ./wait-bootstrap.sh                    # background watcher for bootstrap-complete"
echo "  ./status.sh                            # snapshot of install progress"
echo "  ./host-setup/update-etc-hosts.sh       # (after install) add api/apps DNS entries"
