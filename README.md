# 3node-ocs-portworx-deploy

Reference deployment for a 3-node OpenShift 4.21 TNA cluster (2 masters + 1
arbiter) with Portworx Enterprise providing RF=2 storage. Target: many-site
USB-ISO bare-metal rollouts.

## What to read first

Everything you actually deploy lives in **`deploy/`**. Four manifests + one
aicli paramfile + one orchestration script — self-contained.

```
deploy/
├── aicli_parameters.yml             aicli input: VIPs, hosts, MACs, pull secret
├── 01-machineconfig-master.yaml     master px-metadata + px-data partitions
├── 02-machineconfig-arbiter.yaml    arbiter px-metadata partition
├── 03-portworx-subscription.yaml    OLM install of portworx-certified
├── 04-portworx-storagecluster.yaml  TNA StorageCluster; nodeName placeholders are script-filled
└── install-portworx.sh              labels nodes + applies 03/04, fills nodeName placeholders
```

## Install flow (bare metal)

```sh
# 1. Cluster install via aicli (ISO burnt to USB, boot all 3 nodes).
cd deploy
aicli create cluster    --paramfile aicli_parameters.yml tna
aicli create deployment --paramfile aicli_parameters.yml tna
# wait ~30-60 min for install-complete

# 2. Portworx — single script.
export KUBECONFIG=/path/to/kubeconfig
./install-portworx.sh

# 3. (optional) site-specific license activation.
#    Drop deploy/99-portworx-register.sh (gitignored) and install-portworx.sh runs it.
```

## Pre-install checklist

- [ ] **Secure Boot disabled** in BIOS on all 3 nodes — Portworx `px.ko` is unsigned. See `docs/portworx-design.md`.
- [ ] Install disks ≥256 GB (170 GiB rootfs + 64 GiB px-metadata + margin).
- [ ] `pull_secret:` in `aicli_parameters.yml` points at a valid pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
- [ ] `api_vip:` and `ingress_vip:` are free, routable IPs on the machine network.
- [ ] Hostnames are entered only in `aicli_parameters.yml`; Portworx `nodeName` placeholders are filled from live node roles by `install-portworx.sh`.
- [ ] Network between nodes allows Portworx ports (TCP 17001-17022, UDP 17002 — `startPort: 17001` in `04-`).

## Hardware assumptions

- **Masters (×2)**: an install disk ≥256 GB (any whole device). Optional second raw disk is auto-discovered as additional Portworx capacity.
- **Arbiter (×1)**: single install disk ≥256 GB, no second disk needed (storageless, holds KVDB metadata only).

The MachineConfigs use `/dev/disk/by-id/coreos-boot-disk` — a stable RHCOS
udev symlink — so they are hardware-agnostic across SSD/NVMe/SATA targets.
`aicli_parameters.yml`'s `installation_disk:` is consumed by the assisted
installer *before* that symlink exists, so it still needs a real device path.

## Repo layout

| Path | Purpose |
|---|---|
| `deploy/` | The deliverable — config + install script. Customer-facing. |
| `docs/RUNBOOK.md` | Reproduction of the libvirt regression environment. |
| `docs/portworx-design.md` | Topology, license, partition layout, design decisions. |
| `test/kvm/` | Libvirt mini-cluster used to regression-test `deploy/` before real hardware. |
| `secrets/pull-secret.txt` | Placeholder pointing at `~/.local/pullsecret`. |

Anyone implementing this on new hardware only needs to touch `deploy/`.

## Test flow (libvirt regression)

Before touching real hardware, every change to `deploy/` is validated on a
3-VM libvirt cluster that mirrors the bare-metal topology (2 masters with
virtio-blk + 1 arbiter on virtio-scsi — two bus types on purpose, so the
MachineConfigs' `coreos-boot-disk` symlink is exercised on both).

The whole env lives under `test/kvm/`, split so a reader can inspect
config without reading scripts:

```
test/kvm/
├── vms/                          KVM node spec — edit here to tune resources
│   ├── master.conf                 RAM / vCPU / disks for master role
│   ├── arbiter.conf                RAM / vCPU / disks for arbiter role
│   └── nodes.conf                  hostname / role / MAC / IP inventory
├── machineconfigs/               KVM-only MachineConfigs (NOT shipped to bare metal)
│   ├── 99-libvirt-rotational-master.yaml
│   └── 99-libvirt-rotational-arbiter.yaml
├── agent-config.yaml             OCP agent installer input
├── install-config.yaml.template  OCP install-config with placeholders
└── *.sh                          build / create / teardown scripts
```

The agent installer boots from an ISO — same artifact you'd `dd` to a USB
stick for bare metal, just attached as a virtual CD-ROM.

```sh
cd test/kvm
./envsetup.sh                              # one-time host prep (libvirt, pool, group)
./generate-iso.sh                          # build-iso.sh + upload to libvirt pool
./create-vms.sh                            # define + boot 3 VMs from vms/*.conf
openshift-install agent wait-for install-complete --dir=./generated
cd ../../deploy && ./install-portworx.sh   # Portworx onto the fresh cluster
cd ../test/kvm && ./teardown.sh            # wipe VMs + volumes + generated/
```

Host-side details (registry cache, autostart-watcher, libvirt gotchas) live
in `test/kvm/README.md`. Full reproduction runbook is `docs/RUNBOOK.md`.

## Validated runs

| Date       | Commit    | OCP    | Portworx | Env                        | Capacity                | Notes |
|------------|-----------|--------|----------|----------------------------|-------------------------|-------|
| 2026-04-11 | `2f8c8b6` | 4.21.9 | 3.5.2    | libvirt (mixed bus)        | 518 GiB (2×259)         | Initial PX-StoreV2 pass, smoke test OK |
| 2026-04-12 | `434eae3` | 4.21.9 | 3.6.0    | libvirt                    | 986 GiB (2×493) + drive-add to 1.5 TiB | px-central-aligned spec; live `pxctl service drive add` |
| 2026-04-12 | `c580828` | 4.21.9 | 3.6.0    | libvirt                    | **1.5 TiB at install**  | Retest #9: `useAllWithPartitions` + raw-path systemMetadataDevice. Workaround proven; not shipped (hardware-specific) |

## Known-broken configs

| Config | Fails how | Workaround |
|---|---|---|
| `useAllWithPartitions: true` + `systemMetadataDevice: /dev/disk/by-partlabel/px-metadata` | PX doesn't resolve the partlabel symlink before cross-referencing against discovery → `/dev/vda5` lands in both metadata + storage lists → "device has filesystem on it" | Bug is path-resolution, not exclusion logic. Use raw path (`/dev/vda5`) for the metadata device — works (retest #9 PASS), but per-host hardware-specific. Default ship: `useAll: true` (skips px-data; add post-install via `pxctl service drive add`). |

## License

TODO: pick a license before making the repo public.
