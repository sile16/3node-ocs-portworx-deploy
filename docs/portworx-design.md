# Portworx design notes

Background and rationale for the StorageCluster shape in
`deploy/templates/98-px4-storagecluster.yaml`. Behavior lives in the
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
replace the stub in `deploy/templates/98-px5-register.sh`; the rendered
per-site copy under `deploy/sites/<site>/` is gitignored so credentials don't
leak, and operators run it after the StorageCluster reaches `phase=Running`.

## Partition layout (set by `deploy/templates/98-machineconfig-*.yaml`)

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
`deploy/templates/98-px1-prepare.sh`. Trade-off: the on-disk
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
`98-px1-prepare.sh` queries each node via `oc debug` at install
time (`readlink -f /dev/disk/by-partlabel/px-metadata`) and `sed`-replaces
the per-node `${MASTER1_META_DEV}` / `${MASTER2_META_DEV}` / `${ARBITER_META_DEV}`
tokens in the adjacent `98-px4-storagecluster.yaml` before the operator
sees it. No site-specific hand-editing; the CSV-templated `deploy/` stays
hardware-agnostic.

`useAllWithPartitions: true` would auto-consume px-data at install time
(1.5 TiB out of the gate vs ~986 GiB). Not shipped because it exacerbates
the same class of discovery collision if the metadata device is expressed
as anything but a raw path — see README → Known-broken-configs.

## Pre-reqs OCP doesn't provide (already handled)

- px-metadata + px-data partitions — created by `deploy/templates/98-machineconfig-*.yaml`.
- Stable `/dev/disk/by-partlabel/px-metadata` symlink — automatic from the partition `label:`. Referenced by `98-px1-prepare.sh` at install time; **not** referenced in the final `98-px4-` (see above).
- No `/var/lib/portworx` filesystem mount — MachineConfigs intentionally omit `filesystems:` and `systemd:` blocks.
- SCCs + privileged-pod RBAC — Portworx operator creates its own SCC.
- Kernel modules (`dm_thin_pool`, `dmsetup`) — built into RHCOS 9.6.

## Secure Boot

PX 3.6.0+ ships a signed `px.ko` against the "Portworx Secure Boot CA @2025"
key. Two supported modes:

**SB disabled (simplest):** nothing to do. `px.ko` loads unconditionally.
Acceptable for labs; most physical-hardware policies require SB on.

**SB enabled (default for physical):** the PX CA cert must be trusted by the
kernel before `px.ko` can load. Two paths, depending on environment:

- **Bare-metal — MOK enrollment (one-time per node, at first boot):**
  `./98-px0-enroll-mok-secure-boot.sh` downloads the PX CA on each node (via `oc debug`
  + `curl`), verifies its sha256 against the pin at the top of the script,
  and calls `mokutil --import` with a well-known password. Nodes are
  assumed to have outbound internet at deploy time (same assumption as the
  operator pulling images from `quay.io`). The operator then reboots each
  node (IPMI / iDRAC / iLO / physical console) and completes enrollment via
  MokManager at the next firmware handoff (~10 s prompt, one password entry).
  After reboot, `./98-px0-enroll-mok-secure-boot.sh --verify` confirms enrollment. Cert
  URL + sha256 + year are pinned at the top of the script; bump them in the
  same PR as any `startingCSV` bump if PX rotates their CA. This is the
  only step in the bare-metal flow that requires physical/console touch;
  USB-ISO install already requires one such touch per node, so the cost
  fits the existing rollout envelope.

- **KVM regression — UEFI `db` pre-seeded at VM-define time:**
  `test/kvm/host-setup/px-secboot-vars.sh` builds a per-VM `OVMF_VARS.fd`
  containing MS KEK + MS UEFI CA (baseline for shim) + the Portworx CA in db.
  `test/kvm/create-vms.sh` uses the Secure-Boot OVMF code variant and points
  each domain's `<nvram>` at its pre-seeded file. No MOK enrollment needed —
  the cert is already in `db` at first firmware pass. This is what the KVM
  regression exercises (tests the signed-module load path, but NOT MokManager
  interaction — that's bare-metal only).

If SB is on and the PX CA is not trusted, PX stays stuck at `Initializing`
with `px-cluster` pods `0/1 Ready` forever; `dmesg` shows
`Key was rejected by service`.

## References

- [PX-RH TNA Design Guide (PDF)](https://portworx.com/wp-content/uploads/2025/11/PX-RH-TNA-DesignGuide.pdf)
- [Portworx Licenses](https://docs.portworx.com/portworx-enterprise/platform/license)
- [Portworx prerequisites — firewall ports](https://docs.portworx.com/portworx-enterprise/install-portworx/prerequisites)
- [Install on OpenShift Bare Metal (non-airgap)](https://docs.portworx.com/portworx-enterprise/platform/install/bare-metal/openshift-non-airgap)
- [StorageCluster CRD reference](https://docs.portworx.com/portworx-enterprise/reference/crd/storage-cluster)
