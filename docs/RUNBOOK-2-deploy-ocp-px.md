# RUNBOOK 2 — Deploy OCP + Portworx

Deploy the 3-node TNA cluster (2 masters + 1 arbiter) and bring up
Portworx Enterprise with RF=2 storage. Applies to both bare-metal (via
`aicli`) and the libvirt test environment (via the agent ISO from
RUNBOOK 1).

## Bare-metal install (aicli)

```sh
cd deploy
./render.sh <site>                        # or: ./render.py <site>
cd sites/<site>

aicli create cluster    --paramfile aicli_parameters.yml <cluster_name>
aicli download iso      <cluster_name>
# boot each node from the ISO (USB stick, virtual media, PXE)
aicli wait cluster <cluster_name>

# All steps below require a working `oc` against the new cluster.
# aicli produces a kubeconfig:
export KUBECONFIG=$(aicli info cluster <cluster_name> -f kubeconfig)
```

## Libvirt install

See RUNBOOK-1-test-env.md — after `oc get nodes` shows 3 Ready:

```sh
cd deploy && ./render.sh -o austin && cd sites/austin
export KUBECONFIG=<path>/test/kvm/generated/auth/kubeconfig
```

## Secure Boot MOK enrollment (SB-enabled sites only)

Skip if Secure Boot is disabled in BIOS.

```sh
./98-px0-enroll-mok-secure-boot.sh        # downloads PX CA + mokutil --import per node
# reboot each node via IPMI/iDRAC/iLO; answer MokManager (~10 s prompt)
./98-px0-enroll-mok-secure-boot.sh --verify
```

On the KVM test environment this is handled automatically by pre-seeded
NVRAM — no MOK enrollment step needed.

## Portworx bring-up

Run these in order from the rendered site directory:

```sh
# 1. Cluster monitoring
oc apply -f 98-px2-configmap-clulster-monitoring.yaml

# 2. Apply Kubernetes node labels (portworx.io/node-type, portworx.io/run-on-master)
./98-px1-prepare.sh

# 3. PX operator subscription (Manual approval + pinned startingCSV)
oc apply -f 98-px3-operator-subscription.yaml

# 4. Approve the InstallPlan
IP=$(oc -n portworx get installplan -o name | head -1)
oc -n portworx patch "$IP" --type merge -p '{"spec":{"approved":true}}'

# 5. Wait for operator
oc -n portworx wait --for=condition=Available deployment/portworx-operator --timeout=10m

# 6. StorageCluster (TNA, partlabel, repl=2)
oc apply -f 98-px4-storagecluster.yaml

# 7. Optional license
./98-px5-register.sh

# 8. Health check
./check_px_status.sh
```

## Pass criteria

- `oc -n portworx get storagecluster` → `phase=Running`
- `oc -n portworx get storagenodes` → all 3 `Online`
- `pxctl status` → `PX is operational`, masters show storage, arbiter `No Storage`
- `pxctl cluster list` → `Status: OK`, 3 nodes
- GPT partition labels: `/dev/disk/by-partlabel/px-metadata` present on every node;
  `/dev/disk/by-partlabel/px-data` on masters only (these are GPT partition-name
  entries, not Kubernetes node labels or filesystem labels)

## PX smoke test (libvirt)

```sh
cd test/kvm
./portworx/05-smoke-test.sh              # PVC bind + sentinel write/read
```

## Snapshot checkpoint (libvirt)

After PX is Running, save a snapshot for fast iteration:

```sh
# shutdown all 3 VMs first
./host-setup/autostart-watcher.sh stop
virsh shutdown master-1.example.local master-2.example.local arbiter-1.example.local
# wait for all shut off, then:
./snapshot-save.sh px-installed
```

Revert anytime with `./snapshot-restore.sh px-installed`.

## Known issues

- `oc wait deploy/portworx-operator` may return NotFound if OLM hasn't
  created the deployment yet — poll until it appears, then wait.
- `portworx-api` + `px-csi-ext` sidecars CrashLoopBackOff briefly (~2 min)
  during first PX init, then self-heal.
- PX 3.6.0 `systemMetadataDevice` symlink bug only affects
  `useAllWithPartitions: true` — shipped config uses `useAll: true` +
  partlabel which is safe.
