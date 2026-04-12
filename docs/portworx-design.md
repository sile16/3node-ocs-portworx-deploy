# Portworx design notes

Background and rationale for the StorageCluster shape in
`deploy/04-portworx-storagecluster.yaml`. Behavior lives in the manifest;
this doc explains *why*.

## Topology

Pure/Red Hat **Two-Node-Arbiter (TNA)** Design Guide, PX 3.5 + OCP 4.20.
Validated here on PX 3.6.0 + OCP 4.21.9 (one minor above the formal matrix —
re-verify at apply time).

- 2 storage masters, RF=2, PX-StoreV2.
- 1 arbiter, storageless, holds KVDB metadata only.
- All 3 nodes participate in KVDB quorum; data replicas live only on the masters.

## License

Trial (30 days) auto-activates on first StorageCluster bring-up. No key, no
registration. To register with Pure1 / px-central or activate a paid license,
drop a `deploy/99-portworx-register.sh` (gitignored — site-specific) and
`install-portworx.sh` runs it automatically.

## Partition layout (set by `deploy/01-/02-machineconfig-*.yaml`)

Each install disk is partitioned at install time:

| Partition | Label         | Size            | Used as                          |
|-----------|---------------|-----------------|----------------------------------|
| p1–p4     | (RHCOS)       | up to 170 GiB   | Install + rootfs (auto-grown)    |
| p5        | `px-metadata` | 64 GiB          | `systemMetadataDevice` (PX-StoreV2) |
| p6        | `px-data`     | rest of disk    | Storage pool (master only)       |

Arbiter has no p6 — it's storageless.

## Device-discovery decision

The shipped config uses `useAll: true` (raw whole disks only) on each master,
plus an explicit `systemMetadataDevice: /dev/disk/by-partlabel/px-metadata`.
Trade-off: the on-disk px-data partition is **not** auto-consumed; add it
post-install:

```sh
pxctl service drive add -d /dev/disk/by-partlabel/px-data --newpool
```

The alternative `useAllWithPartitions: true` would auto-consume px-data at
install time (1.5 TiB out of the gate vs ~986 GiB), but requires a raw-path
`systemMetadataDevice` (e.g. `/dev/vda5`) due to a partlabel-symlink resolution
bug in PX exclusion logic. Raw paths are hardware-specific (vda5 on libvirt,
sda5/nvme0n1p5 on bare metal) and break the hardware-agnostic shape of `deploy/`.
Operators who want the higher install-time capacity can swap locally.

## Pre-reqs OCP doesn't provide (already handled)

- px-metadata + px-data partitions — created by `deploy/01-/02-machineconfig-*.yaml`.
- Stable `/dev/disk/by-partlabel/px-metadata` symlink — automatic from the partition `label:`.
- No `/var/lib/portworx` filesystem mount — MachineConfigs intentionally omit `filesystems:` and `systemd:` blocks.
- SCCs + privileged-pod RBAC — Portworx operator creates its own SCC.
- Kernel modules (`dm_thin_pool`, `dmsetup`) — built into RHCOS 9.6.

## Hard prerequisite: Secure Boot OFF

Portworx's `px.ko` kernel module is not signed with a key in RHCOS's shim
keyring. With Secure Boot enabled, the kernel rejects the module and Portworx
never starts. Disable Secure Boot in BIOS on every node (libvirt `create-vms.sh`
already uses the non-SB OVMF firmware variant).

## References

- [PX-RH TNA Design Guide (PDF)](https://portworx.com/wp-content/uploads/2025/11/PX-RH-TNA-DesignGuide.pdf)
- [Portworx Licenses](https://docs.portworx.com/portworx-enterprise/platform/license)
- [Portworx prerequisites — firewall ports](https://docs.portworx.com/portworx-enterprise/install-portworx/prerequisites)
- [Install on OpenShift Bare Metal (non-airgap)](https://docs.portworx.com/portworx-enterprise/platform/install/bare-metal/openshift-non-airgap)
- [StorageCluster CRD reference](https://docs.portworx.com/portworx-enterprise/reference/crd/storage-cluster)
