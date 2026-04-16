# RUNBOOK 3 — Deploy OpenShift Virtualization (KubeVirt) on Portworx

Install OpenShift Virtualization (CNV) and configure it to use
Portworx-backed storage for VM disks, scratch space, and shared
filesystems. Requires a working OCP + PX cluster from RUNBOOK 2.

## Prerequisites

- OCP cluster with PX `phase=Running` (RUNBOOK 2 complete)
- Master VMs: ≥24 GiB RAM each (CNV + OCP + PX combined footprint)
- Host KSM enabled (see RUNBOOK 1 host tuning) if running on libvirt

## Step 1: Portworx StorageClasses for KubeVirt

Apply **before** the HyperConverged CR so CDI can build StorageProfiles
from these classes. Shipped with explicit `repl=2` for TNA (only 2 storage
nodes; do not rely on PX auto-create which may default to repl=3).

```sh
cd deploy/sites/<site>
oc apply -f 99-kubevirt-0-storageclasses.yaml
```

Creates three StorageClasses:

| Name | Use case | Key params |
|---|---|---|
| `px-rwx-block-kubevirt` | VM boot/data disks (default virt class) | `repl=2`, `nodiscard=true`, RWX Block |
| `px-rwx-file-kubevirt` | Shared FS (vTPM, cloud-init ISOs) | `repl=2`, `sharedv4=true` |
| `px-cdi-scratch` | CDI importer scratch | `repl=1` (ephemeral) |

`px-rwx-block-kubevirt` carries the annotation
`storageclass.kubevirt.io/is-default-virt-class: "true"` — CDI
automatically selects it when a DataVolume uses `spec.storage` (the smart
path) without an explicit `storageClassName`.

## Step 2: Install the CNV operator

```sh
oc apply -f 99-kubevirt-1-operator-subscription.yaml

# Wait for InstallPlan + approve (Manual approval, same pattern as PX)
IP=$(oc -n openshift-cnv get installplan -o name | head -1)
oc -n openshift-cnv patch "$IP" --type merge -p '{"spec":{"approved":true}}'

# Wait for HCO operator
oc -n openshift-cnv wait --for=condition=Available deployment/hco-operator --timeout=10m
```

## Step 3: Deploy HyperConverged CR

```sh
oc apply -f 99-kubevirt-2-hyperconverged.yaml
```

This template sets `enableCommonBootImageImport: false` (top-level spec,
**not** under `featureGates` which is deprecated + silently ignored). Without
this, HCO auto-imports 6 OS boot images (CentOS, Fedora, RHEL) at 30 GiB
each — 180 GiB × repl=2 = 360 GiB of PX pool on a TNA cluster.

Wait for Available:

```sh
oc -n openshift-cnv wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True \
  hco/kubevirt-hyperconverged --timeout=15m
```

## Step 4: Verify

```sh
# CNV operator
oc -n openshift-cnv get csv                         # Phase=Succeeded
oc -n openshift-cnv get hco kubevirt-hyperconverged # Available=True

# virt-handler on compute nodes
oc -n openshift-cnv get ds virt-handler             # READY = number of masters

# PX StorageClasses recognized by CDI
oc get storageprofile px-rwx-block-kubevirt -o yaml  # claimPropertySets: RWX + Block

# No unwanted boot images
oc -n openshift-virtualization-os-images get pvc     # should be empty
```

## Step 5: Smoke-test VM

```sh
oc apply -f 99-kubevirt-3-test-vm.yaml
```

This creates a DataVolume (`spec.storage` — no explicit SC, CDI
auto-resolves `px-rwx-block-kubevirt`) importing Cirros 0.6.2, and a
VirtualMachine that boots from it.

```sh
# Wait for import + VM
oc get dv vm-pxtest-boot                 # Succeeded
oc get vmi vm-pxtest                     # Running, Ready=True

# Verify PVC is on PX with correct properties
oc get pvc vm-pxtest-boot                # RWX, Block, px-rwx-block-kubevirt

# Console access (login: cirros / gocubsgo)
virtctl console vm-pxtest
```

## Step 6: Live migration test

```sh
# Check which node the VM is on
oc get vmi vm-pxtest -o jsonpath='{.status.nodeName}{"\n"}'

# Trigger migration
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: vm-pxtest-migrate
spec:
  vmiName: vm-pxtest
EOF

# Watch — should move to the other master in ~10 s
oc get vmim vm-pxtest-migrate            # Succeeded
oc get vmi vm-pxtest -o jsonpath='{.status.nodeName}{"\n"}'  # different node
```

Live migration works because the PVC is RWX Block — both source and
destination nodes can attach the shared Portworx volume simultaneously
during the migration window.

## Cleanup

```sh
oc delete vm vm-pxtest
oc delete dv vm-pxtest-boot
oc delete vmim vm-pxtest-migrate
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| HCO stuck `Available=False` | Memory pressure on masters | Bump master VM RAM to ≥24 GiB; enable host KSM + swap |
| `hco-operator` CrashLoopBackOff | Leader-election timeout against kube-apiserver | Same — memory pressure; also check `oc adm top nodes` |
| DataVolume stuck `PendingPopulation` | `WaitForFirstConsumer` + no pod consuming yet | Normal for ~30 s; if stuck >2 min, check CDI importer pod events |
| 180 GiB of unexpected PVCs in `openshift-virtualization-os-images` | `enableCommonBootImageImport` set under deprecated `featureGates` path | Patch HCO: `spec.enableCommonBootImageImport: false` (top-level); delete the DVs |
| PVC Pending with no SC assigned | Used `spec.pvc` in DataVolume instead of `spec.storage` | Switch to `spec.storage` — CDI auto-resolves from the default virt SC annotation |
