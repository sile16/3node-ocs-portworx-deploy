#!/usr/bin/env bash
#
# build-iso.sh — render config + build agent.x86_64.iso
#
# This is the COMMON path — it produces the same ISO whether you'll boot it
# in libvirt (test/kvm) or burn it to a USB stick for physical hardware.
# It does NOT touch libvirt at all.
#
# Inputs (committed in this directory):
#   install-config.yaml.template    — has __PULL_SECRET__ / __SSH_PUBKEY__ placeholders
#   agent-config.yaml               — hosts, MACs, rootDeviceHints, rendezvousIP
#   ../../deploy/templates/98-machineconfig-*.yaml — MCs copied from the canonical deploy/templates/ dir
#
# Inputs (from outside the repo):
#   ~/.local/pullsecret             — Red Hat pull secret JSON
#   ~/.ssh/id_rsa.pub               — ssh public key that ends up in the core user
#
# Process:
#   1. Stage a clean ./generated/ working directory
#   2. Copy install-config (with secrets substituted), agent-config, and openshift/ into it
#   3. Run `openshift-install agent create image --dir=./generated`
#
# Output:
#   ./generated/agent.x86_64.iso
#
# Note: the installer CONSUMES (moves/deletes) install-config.yaml and
# agent-config.yaml from its --dir at runtime. We never touch the committed
# sources — they always live next to this script; ./generated/ is disposable.
#
# Usage:
#   ./build-iso.sh                # default
#   OPENSHIFT_INSTALL=/path ./build-iso.sh
#   PULL_SECRET_FILE=... SSH_PUBKEY_FILE=... ./build-iso.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${HERE}/generated"

PULL_SECRET_FILE="${PULL_SECRET_FILE:-$HOME/.local/pullsecret}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"
OPENSHIFT_INSTALL="${OPENSHIFT_INSTALL:-$(command -v openshift-install || echo "$HOME/bin/openshift-install")}"
MIRROR_CERT_FILE="${MIRROR_CERT_FILE:-${HERE}/host-setup/registry-cert.pem}"
MIRROR_HOSTPORT="${MIRROR_HOSTPORT:-192.168.125.1:5000}"
# The system CA bundle file on the build host — we concatenate it with the
# mirror cert when wiring additionalTrustBundle. Required because the OCP
# agent installer mounts additionalTrustBundle as a REPLACEMENT for the
# container's tls-ca-bundle.pem (not as an addition), so if we pass only
# the self-signed mirror cert, the agent-register-cluster container loses
# all public-CA trust and fails every other HTTPS call.
# Ubuntu/Debian: /etc/ssl/certs/ca-certificates.crt
# RHEL/Fedora:   /etc/pki/tls/certs/ca-bundle.crt
SYSTEM_CA_BUNDLE="${SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
[ -s "$SYSTEM_CA_BUNDLE" ] || SYSTEM_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"

# ── prereq checks ───────────────────────────────────────────────────────────
[ -x "$OPENSHIFT_INSTALL" ] || {
  echo "FATAL: openshift-install not executable at: $OPENSHIFT_INSTALL" >&2
  echo "       Set OPENSHIFT_INSTALL=/path/to/openshift-install or add ~/bin to PATH." >&2
  exit 1
}

[ -s "$PULL_SECRET_FILE" ] || {
  echo "FATAL: pull secret missing or empty at $PULL_SECRET_FILE" >&2
  echo "       Download from https://console.redhat.com/openshift/install/pull-secret" >&2
  exit 1
}

[ -s "$SSH_PUBKEY_FILE" ] || {
  echo "FATAL: ssh public key missing at $SSH_PUBKEY_FILE" >&2
  echo "       Generate with: ssh-keygen -t rsa -f ~/.ssh/id_rsa" >&2
  exit 1
}

[ -f "${HERE}/install-config.yaml.template" ] || {
  echo "FATAL: install-config.yaml.template not found in ${HERE}" >&2
  exit 1
}

[ -f "${HERE}/agent-config.yaml" ] || {
  echo "FATAL: agent-config.yaml not found in ${HERE}" >&2
  exit 1
}

# ── stage the working directory fresh ──────────────────────────────────────
rm -rf "$GEN"
mkdir -p "$GEN/openshift"

# Copy the MachineConfigs from the canonical deploy/ directory at the repo
# root. The libvirt POC uses the SAME MCs as the physical target — our
# whole point of having deploy/ as a single source of truth. The file
# names just need to start with something openshift-install agent can
# recognize as a manifest (any .yaml works).
DEPLOY_TPL="${HERE}/../../deploy/templates"
[ -d "$DEPLOY_TPL" ] || { echo "FATAL: deploy/templates not found at $DEPLOY_TPL" >&2; exit 1; }
cp "${DEPLOY_TPL}/98-machineconfig-master.yaml"  "$GEN/openshift/"
cp "${DEPLOY_TPL}/98-machineconfig-arbiter.yaml" "$GEN/openshift/"

# KVM-specific MachineConfigs from ./machineconfigs/.
#
# These are workarounds for the libvirt test environment (e.g. rotational-hint
# udev rule for virtio disks). They are NOT shipped to bare metal — deploy/
# stays canonical. When cutting a bare-metal ISO, delete or rename this dir
# so its contents don't get folded in.
MC_DIR="${HERE}/machineconfigs"
if [ -d "$MC_DIR" ]; then
  mc_count=0
  for mc in "$MC_DIR"/*.yaml; do
    [ -f "$mc" ] || continue
    cp "$mc" "$GEN/openshift/$(basename "$mc")"
    echo "  kvm-mc: $(basename "$mc")"
    mc_count=$((mc_count + 1))
  done
  echo "  (merged $mc_count KVM-specific manifest(s) from ${MC_DIR#${HERE}/})"
else
  echo "  (no ${MC_DIR#${HERE}/} dir — shipping deploy/ manifests only, bare-metal-canonical)"
fi

cp "${HERE}/agent-config.yaml" "$GEN/agent-config.yaml"

# Secrets via env vars (not sed) — JSON pull secret contains `/`, `=`, `"`
# and every other character that would break sed; awk with ENVIRON[] is safe.
PULL_SECRET="$(tr -d '\n' < "$PULL_SECRET_FILE")"
SSH_PUBKEY="$(tr -d '\n' < "$SSH_PUBKEY_FILE")"
export PULL_SECRET SSH_PUBKEY

# ── build the mirror + trust-bundle blocks (or empty if no mirror) ────────
# When host-setup/registry-cache.sh has been run and the cert file exists,
# we inject:
#   1. imageContentSources — maps quay.io/openshift-release-dev/* to our mirror
#   2. additionalTrustBundle — the self-signed cert so OCP trusts our mirror
#      (additionalTrustBundlePolicy: Always because we want it applied at every
#       image pull, not just for proxies)
# When the cert file does NOT exist, both placeholders are replaced with
# empty strings and the resulting install-config.yaml is mirror-free — which
# is the correct behavior for a fresh environment or a bare-metal target
# that isn't running the libvirt-host cache.
# MIRROR + TRUST blocks can be large (the trust bundle is ~220 KB of PEM),
# which blows past argv/env limits when passed as awk -v or ENVIRON. We
# write both blocks to temp files and have awk getline them when it hits
# the corresponding placeholder lines.
MIRROR_BLOCK_FILE="$(mktemp)"
TRUST_BLOCK_FILE="$(mktemp)"
trap 'rm -f "$MIRROR_BLOCK_FILE" "$TRUST_BLOCK_FILE"' EXIT

if [ -s "$MIRROR_CERT_FILE" ]; then
  [ -s "$SYSTEM_CA_BUNDLE" ] || {
    echo "FATAL: system CA bundle not found — tried /etc/ssl/certs/ca-certificates.crt and /etc/pki/tls/certs/ca-bundle.crt" >&2
    echo "       Set SYSTEM_CA_BUNDLE=/path/to/bundle and rerun." >&2
    exit 1
  }
  echo "  mirror: found cert at $MIRROR_CERT_FILE → wiring install-config to use ${MIRROR_HOSTPORT}"
  echo "          trust bundle = ${SYSTEM_CA_BUNDLE} + ${MIRROR_CERT_FILE}"

  # ── imageContentSources block ───────────────────────────────────────
  cat > "$MIRROR_BLOCK_FILE" <<EOF
imageContentSources:
  - mirrors:
      - ${MIRROR_HOSTPORT}/openshift-release-dev/ocp-release
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors:
      - ${MIRROR_HOSTPORT}/openshift-release-dev/ocp-v4.0-art-dev
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF

  # ── additionalTrustBundle block ─────────────────────────────────────
  # The OCP agent installer mounts this trust bundle into the
  # agent-register-cluster container as a REPLACEMENT for the full
  # tls-ca-bundle.pem (see the container's unit file: it binds
  # /etc/pki/ca-trust/source/anchors/domain.crt onto tls-ca-bundle.pem).
  # That means we must inline EVERY CA the container needs: the host's
  # public CA bundle AND our self-signed mirror cert. If we inline only
  # the mirror cert, every other HTTPS call inside that container
  # fails validation and the install stalls in "Waiting for services"
  # with agent-register-cluster stuck in an auto-restart loop.
  {
    echo 'additionalTrustBundlePolicy: Always'
    echo 'additionalTrustBundle: |'
    sed 's/^/  /' "$SYSTEM_CA_BUNDLE"
    sed 's/^/  /' "$MIRROR_CERT_FILE"
  } > "$TRUST_BLOCK_FILE"
fi

awk -v mirror_file="$MIRROR_BLOCK_FILE" -v trust_file="$TRUST_BLOCK_FILE" '
function cat_file(path,    line) {
  while ((getline line < path) > 0) print line
  close(path)
}
{
  if ($0 == "__MIRROR_SOURCES__") { cat_file(mirror_file); next }
  if ($0 == "__TRUST_BUNDLE__")   { cat_file(trust_file);  next }
  gsub(/__PULL_SECRET__/, ENVIRON["PULL_SECRET"])
  gsub(/__SSH_PUBKEY__/, ENVIRON["SSH_PUBKEY"])
  print
}
' "${HERE}/install-config.yaml.template" > "$GEN/install-config.yaml"

# Sanity check — a leftover placeholder in a non-comment line means awk
# didn't substitute. Comment lines (starting with #) mentioning placeholder
# names by literal string are fine; they're documentation.
if grep -vE '^\s*#' "$GEN/install-config.yaml" \
   | grep -qE '__(PULL_SECRET|SSH_PUBKEY|MIRROR_SOURCES|TRUST_BUNDLE)__'; then
  echo "FATAL: placeholder substitution failed in $GEN/install-config.yaml" >&2
  grep -nE '__(PULL_SECRET|SSH_PUBKEY|MIRROR_SOURCES|TRUST_BUNDLE)__' "$GEN/install-config.yaml" >&2
  exit 1
fi

# ── run the installer ──────────────────────────────────────────────────────
echo "=== invoking openshift-install agent create image in $GEN ==="
"$OPENSHIFT_INSTALL" agent create image --dir="$GEN"

ISO="$GEN/agent.x86_64.iso"
if [ ! -f "$ISO" ]; then
  echo "FATAL: expected ISO not produced: $ISO" >&2
  exit 1
fi

printf '\n=== ISO built: %s (%s bytes) ===\n' \
  "$ISO" "$(stat -c %s "$ISO")"
echo
echo "To boot this ISO:"
echo "  libvirt       : ./upload-iso-to-pool.sh && ./create-vms.sh"
echo "  physical host : burn to USB with e.g. 'sudo dd if=$ISO of=/dev/sdX bs=4M status=progress'"
