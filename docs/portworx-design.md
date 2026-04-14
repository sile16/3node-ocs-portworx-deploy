# Portworx design notes

Background and rationale for the StorageCluster shape in
`deploy/templates/98-6-portworx-storagecluster.yaml`. Behavior lives in the
manifest; this doc explains *why*.

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
replace the stub in `deploy/templates/98-7-portworx-register.sh`; the rendered
per-site copy under `deploy/sites/<site>/` is gitignored so credentials don't
leak, and operators run it after the StorageCluster reaches `phase=Running`.

## Partition layout (set by `deploy/templates/98-{0,1}-machineconfig-*.yaml`)

Each install disk is partitioned at install time:

| Partition | Label         | Size            | Used as                          |
|-----------|---------------|-----------------|----------------------------------|
| p1–p4     | (RHCOS)       | up to 170 GiB   | Install + rootfs (auto-grown)    |
| p5        | `px-metadata` | 64 GiB          | `systemMetadataDevice` (PX-StoreV2) |
| p6        | `px-data`     | rest of disk    | Storage pool (master only)       |

Arbiter has no p6 — it's storageless.

## Device-discovery decision

The shipped config uses `useAll: true` (raw whole disks only) on each master,
plus a raw-path `systemMetadataDevice` (e.g. `/dev/vda5`, `/dev/sda5`,
`/dev/nvme0n1p5`) populated **per node** by
`deploy/templates/98-4-prepare-for-portworx.sh`. Trade-off: the on-disk
px-data partition is **not** auto-consumed; add it post-install:

```sh
pxctl service drive add -d /dev/disk/by-partlabel/px-data --newpool
```

PX 3.6.0 has a symlink-resolution bug: `systemMetadataDevice` given as any
symlink (`/dev/disk/by-partlabel/px-metadata`, custom by-id udev rules,
etc.) fails to init because PX enumerates the underlying device twice (once
via discovery, once via the metadata reservation) and collides. We work
around it by shipping a raw-path value — but raw paths differ across
hardware (`vda5` on libvirt, `sda5` / `nvme0n1p5` on bare metal), so
`98-4-prepare-for-portworx.sh` queries each node via `oc debug` at install
time (`readlink -f /dev/disk/by-partlabel/px-metadata`) and `sed`-replaces
the per-node `${MASTER1_META_DEV}` / `${MASTER2_META_DEV}` / `${ARBITER_META_DEV}`
tokens in the adjacent `98-6-portworx-storagecluster.yaml` before the operator
sees it. No site-specific hand-editing; the CSV-templated `deploy/` stays
hardware-agnostic.

`useAllWithPartitions: true` would auto-consume px-data at install time
(1.5 TiB out of the gate vs ~986 GiB). Not shipped because it exacerbates
the same class of discovery collision if the metadata device is expressed
as anything but a raw path — see README → Known-broken-configs.

## Pre-reqs OCP doesn't provide (already handled)

- px-metadata + px-data partitions — created by `deploy/templates/98-{0,1}-machineconfig-*.yaml`.
- Stable `/dev/disk/by-partlabel/px-metadata` symlink — automatic from the partition `label:`. Referenced by `98-4-prepare-for-portworx.sh` at install time; **not** referenced in the final `98-6-` (see above).
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
