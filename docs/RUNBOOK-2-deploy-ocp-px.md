# RUNBOOK 2 — Deploy OCP + Portworx

Deploy the 3-node TNA cluster (2 masters + 1 arbiter) and bring up
Portworx Enterprise with RF=2 storage. Covers both bare-metal (via
`aicli`) and the libvirt test environment (via the agent ISO from
RUNBOOK 1).

---

## Bare-metal install

### Prerequisites

- 3 physical servers racked + cabled (2 masters, 1 arbiter)
- Each server: ≥256 GB install disk, UEFI boot, network between nodes
- IPMI / iDRAC / iLO access for console + power control
- A build host with: `aicli`, `oc`, `openshift-install` on `$PATH`
- Pull secret at `~/.local/pullsecret` (from console.redhat.com)
- Site row populated in `deploy/sites.csv` with correct hostnames, MACs, VIPs, DNS

### Pre-install checklist

- [ ] All 3 nodes powered on, BIOS configured for UEFI boot
- [ ] **Secure Boot:** either disabled in BIOS, or enabled (MOK enrollment in step 3 below)
- [ ] Install disk ≥256 GB on each node (170 GiB OS + 64 GiB px-metadata + margin)
- [ ] API VIP + Ingress VIP are free, routable IPs on the machine network
- [ ] Portworx ports open between nodes: TCP 17001–17022, UDP 17002
- [ ] DNS (or `/etc/hosts` on the build host) resolves `api.<base_dns_domain>` → API VIP

### Step 1: Render the site + create the installer ISO

```sh
cd deploy
./render.sh <site>                        # or: ./render.py <site>
cd sites/<site>

# Create the cluster definition in assisted-service
aicli create cluster    --paramfile aicli_parameters.yml <cluster_name>
aicli create deployment --paramfile aicli_parameters.yml <cluster_name>

# Download the agent ISO (contains RHCOS + MachineConfigs including
# the 98-machineconfig-{master,arbiter}.yaml that carve the px-metadata
# and px-data GPT partitions at install time)
aicli download iso <cluster_name>
```

### Step 2: Boot all 3 nodes from the ISO

Options (pick one per node):
- **USB stick:** `sudo dd if=<cluster_name>.iso of=/dev/sdX bs=4M status=progress conv=fsync`
- **Virtual media:** attach the ISO via iDRAC/iLO/BMC virtual CD-ROM
- **PXE/HTTP boot:** extract kernel+initrd+rootfs from the ISO; serve via TFTP/HTTP

Nodes register with assisted-service by MAC address (configured in
`aicli_parameters.yml` from `sites.csv`).

```sh
# Wait for install to complete (~30-60 min)
aicli wait cluster <cluster_name>
```

Monitor progress:
```sh
aicli info cluster <cluster_name>         # cluster-level status
aicli list hosts                          # per-host status + validations
```

### Step 3: Authenticate to the new cluster

```sh
# aicli produces the kubeconfig:
export KUBECONFIG=$(aicli info cluster <cluster_name> -f kubeconfig)

# Verify all 3 nodes are Ready
oc get nodes
# Expected: 2 × control-plane,master,worker + 1 × arbiter, all Ready
```

### Step 4: Secure Boot MOK enrollment (SB-enabled sites only)

Skip this step entirely if Secure Boot is disabled in BIOS.

The enroll script downloads the Portworx Secure Boot CA (pinned URL +
sha256 at the top of the script) onto each node via `oc debug` + `curl`,
then runs `mokutil --import` with a temporary password. Nodes need
outbound internet for the download.

```sh
./98-px0-enroll-mok-secure-boot.sh
```

The script prints per-node instructions. For each node:

1. Reboot via IPMI / iDRAC / iLO (or physical power cycle)
2. Within ~10 s of firmware handoff, **MokManager** appears on the console
3. Press any key → **Enroll MOK** → View key 0 (Portworx Secure Boot CA) → **Continue**
4. When asked "Enroll the key(s)?": **Yes**
5. Enter the temporary password printed by the script (default: `portworx`)
6. System reboots into RHCOS normally

After all nodes have rebooted and enrolled:

```sh
./98-px0-enroll-mok-secure-boot.sh --verify
# Expected: all nodes show "OK (Portworx CA enrolled)"
```

### Step 5: Portworx bring-up

Run these in order from the rendered site directory (`deploy/sites/<site>/`):

```sh
# 5a. Enable cluster-monitoring user-workload
oc apply -f 98-px2-configmap-clulster-monitoring.yaml

# 5b. Apply Kubernetes node labels (portworx.io/node-type, portworx.io/run-on-master)
./98-px1-prepare.sh

# 5c. Install PX operator (Manual approval + pinned startingCSV)
oc apply -f 98-px3-operator-subscription.yaml

# 5d. Approve the InstallPlan (wait for it to appear first)
#     The InstallPlan may take 30-60 s to be created by OLM after the
#     subscription. If the command below returns empty, wait and retry.
IP=$(oc -n portworx get installplan -o name | head -1)
oc -n portworx patch "$IP" --type merge -p '{"spec":{"approved":true}}'

# 5e. Wait for the PX operator deployment to become Available
#     NOTE: this may return NotFound if OLM hasn't created the deployment
#     yet — poll `oc -n portworx get deploy portworx-operator` until it
#     exists, then run the wait.
oc -n portworx wait --for=condition=Available deployment/portworx-operator --timeout=10m

# 5f. Deploy the StorageCluster (TNA topology, partlabel-based, repl=2)
oc apply -f 98-px4-storagecluster.yaml

# 5g. Optional: activate license / register with PX-Central
./98-px5-register.sh

# 5h. Health check (run anytime — flags known-bad symptoms)
./check_px_status.sh
```

### Step 6: Verify

```sh
# StorageCluster phase
oc -n portworx get storagecluster
# Expected: phase=Running

# All 3 storage nodes online
oc -n portworx get storagenodes
# Expected: all 3 Online

# PX operational from inside the cluster
POD=$(oc -n portworx get pod -l name=portworx -o jsonpath='{.items[0].metadata.name}')
oc -n portworx exec "$POD" -- /opt/pwx/bin/pxctl status
# Expected: "PX is operational", masters show storage pool, arbiter "No Storage"

oc -n portworx exec "$POD" -- /opt/pwx/bin/pxctl cluster list
# Expected: Status: OK, 3 nodes Online
```

### Step 7: Validate GPT partition-names on each node

```sh
for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $n ---"
  oc debug --quiet node/$n -- chroot /host ls /dev/disk/by-partlabel/
done
```

Expected per node:
- **Masters:** BIOS-BOOT, EFI-SYSTEM, boot, root, **px-metadata**, **px-data**
- **Arbiter:** BIOS-BOOT, EFI-SYSTEM, boot, root, **px-metadata** (no px-data)

These are GPT partition-name entries (set by Ignition from the
`98-machineconfig-*.yaml` at install time), visible via udev as
`/dev/disk/by-partlabel/<name>`. They are distinct from:
- **Filesystem labels** (e.g. XFS `mdvol` that PX writes inside px-metadata)
- **Kubernetes node labels** (e.g. `portworx.io/node-type=storage`)

---

## Libvirt install

See RUNBOOK-1-test-env.md — after `oc get nodes` shows 3 Ready:

```sh
cd deploy && ./render.sh -o austin && cd sites/austin
export KUBECONFIG=<path>/test/kvm/generated/auth/kubeconfig
```

Then skip to Step 5 (Portworx bring-up) above. Secure Boot MOK
enrollment is handled automatically by the pre-seeded NVRAM in the
KVM test environment.

### PX smoke test (libvirt only)

```sh
cd test/kvm
./portworx/05-smoke-test.sh              # PVC bind + sentinel write/read
```

### Snapshot checkpoint (libvirt only)

After PX is Running, save a snapshot for fast iteration on KubeVirt
or other experiments:

```sh
./host-setup/autostart-watcher.sh stop
virsh shutdown master-1.example.local master-2.example.local arbiter-1.example.local
# wait for all shut off, then:
./snapshot-save.sh px-installed
```

Revert anytime with `./snapshot-restore.sh px-installed`.

---

## Known issues

| Issue | Details | Workaround |
|---|---|---|
| `oc wait deploy/portworx-operator` returns NotFound | OLM hasn't created the deployment yet after InstallPlan approval | Poll `oc -n portworx get deploy portworx-operator` until it appears, then `oc wait` |
| `portworx-api` + `px-csi-ext` CrashLoopBackOff | Normal during first ~2 min of PX init; sidecars depend on px-cluster health endpoint | Wait — self-heals once PX daemon is ready |
| `systemMetadataDevice` symlink-resolution bug | PX 3.6.0 fails to canonicalize symlinks when used with `useAllWithPartitions: true` | Shipped config uses `useAll: true` + partlabel which avoids the bug. See header comment in `98-px4-storagecluster.yaml` |
| GPT partition-names missing on a node | See README → Resilience tests for diagnosis | Check `sgdisk --print /dev/<boot>` for GPT integrity; restore with `sgdisk --change-name` if needed |
