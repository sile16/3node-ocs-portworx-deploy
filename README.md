# 3node-ocs-portworx-deploy

Reference deployment for a 3-node OpenShift 4.21 TNA cluster (2 masters + 1
arbiter) with Portworx Enterprise providing RF=2 storage. Target: many-site
USB-ISO bare-metal rollouts.

## What to read first

Everything you actually deploy lives in **`deploy/`**. Site-specific values live
in `sites.csv`; `render.sh` renders `templates/` into `sites/<site>/` so each
site gets its own self-contained directory. Files in `templates/` are numbered
to match the order an operator runs them at the site.

```
deploy/
├── sites.csv                               one row per site: hostnames, MACs, VIPs, DNS
├── render.sh                               awk-based template render, sites.csv × templates/ → sites/<site>/
├── templates/                              canonical inputs; ${VAR} placeholders per sites.csv columns
│   ├── 01-machineconfig-master.yaml            master px-metadata + px-data partitions (agent-installer manifest)
│   ├── 02-machineconfig-arbiter.yaml           arbiter px-metadata partition            (agent-installer manifest)
│   ├── 03-configmap-clulster-monitoring.yaml   cluster-monitoring user-workload enable
│   ├── 04-prepare-for-portworx.sh              label master/arbiter nodes for placement
│   ├── 05-portworx-subscription.yaml           OLM install of portworx-certified
│   ├── 06-portworx-storagecluster.yaml         TNA StorageCluster; nodeName fields templated
│   ├── 07-portworx-register.sh                 optional site-specific license / px-central registration
│   ├── aicli_parameters.yml                    aicli input: VIPs, hosts, MACs, pull secret
│   └── check_status.sh                         one-shot health snapshot (OCP + PX), flags known-bad symptoms
└── sites/<site>/                           rendered, per-site, gitignored — what the site operator ships against
```

## Install flow (bare metal)

```sh
# 0. Add/update your site row in deploy/sites.csv, then render its dir.
cd deploy
./render.sh austin                         # → deploy/sites/austin/*

# 1. Cluster install via aicli (ISO burnt to USB, boot all 3 nodes).
#    01-/02- MachineConfigs are packed into the agent installer ISO here.
cd sites/austin
aicli create cluster    --paramfile aicli_parameters.yml prod-aus
aicli create deployment --paramfile aicli_parameters.yml prod-aus
# wait ~30-60 min for install-complete

# 2. Portworx bring-up — run the numbered steps in order.
export KUBECONFIG=/path/to/kubeconfig
oc apply -f 03-configmap-clulster-monitoring.yaml
./04-prepare-for-portworx.sh               # labels nodes for PX placement
oc apply -f 05-portworx-subscription.yaml  # wait for portworx-operator Available
oc apply -f 06-portworx-storagecluster.yaml
./07-portworx-register.sh                  # optional, site-specific license
./check_status.sh                          # sanity check at any point
```

## Pre-install checklist

- [ ] **Secure Boot disabled** in BIOS on all 3 nodes — Portworx `px.ko` is unsigned. See `docs/portworx-design.md`.
- [ ] Install disks ≥256 GB (170 GiB rootfs + 64 GiB px-metadata + margin).
- [ ] `pull_secret:` path in `deploy/templates/aicli_parameters.yml` points at a valid pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
- [ ] `api_vip` and `ingress_vip` columns in `deploy/sites.csv` are free, routable IPs on the site's machine network.
- [ ] Hostnames and MACs are set only in `deploy/sites.csv`; those same values land in both `aicli_parameters.yml` (via the agent installer) and `06-portworx-storagecluster.yaml` (`nodeName` fields), rendered together by `render.sh`.
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
cd ../../deploy && ./render.sh <site> && cd sites/<site> && \
  oc apply -f 03-configmap-clulster-monitoring.yaml && ./04-prepare-for-portworx.sh && \
  oc apply -f 05-portworx-subscription.yaml && oc apply -f 06-portworx-storagecluster.yaml
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
| 2026-04-12 | `bd0d360` | 4.21.9 | 3.6.0    | libvirt                    | 986 GiB (2×493)         | Two consecutive end-to-end passes exercising `install-portworx.sh` script hardening — OLM deployment-exists poll, placeholder regex scoped to `nodeName:`, `phase=Running` wait. Smoke test PASSED both runs. |

## Known-broken configs

| Config | Fails how | Workaround |
|---|---|---|
| `useAllWithPartitions: true` + `systemMetadataDevice: /dev/disk/by-partlabel/px-metadata` | PX doesn't resolve the partlabel symlink before cross-referencing against discovery → `/dev/vda5` lands in both metadata + storage lists → "device has filesystem on it" | Bug is path-resolution, not exclusion logic. Use raw path (`/dev/vda5`) for the metadata device — works (retest #9 PASS), but per-host hardware-specific. Default ship: `useAll: true` (skips px-data; add post-install via `pxctl service drive add`). |
| `useAll: true` + `systemMetadataDevice: /dev/disk/by-id/<custom-symlink>` pointing at a whole raw disk | Same bug class as partlabel — PX does not canonicalize the symlink before building its exclusion list. `useAll` enumerates the underlying `/dev/sdc` as a storage candidate, writes its own `pwxN` FS label during init, then `InitSystemMetadata` fails with `device /dev/disk/by-id/px-metadata-disk has a filesystem on it with labels any:pwxN`. Proves the bug is **symlink-general**, not partlabel-specific; `useAll` does **not** dodge it when the symlink target is a whole disk that `useAll` discovers. Tested 2026-04-13 on PX 3.6.0 with a dedicated 64 GiB metadata disk surfaced via udev rule (`deploy/01-` drops `/etc/udev/rules.d/99-px-metadata.rules`). | Same as partlabel: use a raw path (`/dev/sdc`) for `systemMetadataDevice`. Not shipped — per-node hardware-specific path breaks the hardware-agnostic shape of `deploy/`. Secondary lesson from the same run: virtio-blk silently truncates disk `serial=` to 20 chars, which strips any hostname-based suffix — the test env needed to switch masters to `virtio-scsi` (SCSI VPD 0x80 accepts full string + scsi_id populates `ID_SERIAL_SHORT`) for the udev match to fire. |
| `nodes[].selector.labelSelector` on TNA StorageCluster (instead of `nodeName`) | **Admission accepts it** (`oc apply --dry-run=server` passes, object stores fine), then the operator reconcile rejects at `storagecluster.go:3320`: `"Failed to create TNA NodeSpecs: NodeSpec for arbiter node <hostname> not found, please add it to the storage cluster spec"`. StorageCluster phase flips to `Degraded`. | TNA reconcile does an exact `nodeName` lookup per node — labelSelector matches aren't consulted. Ship exact `nodeName` on every entry; `install-portworx.sh` substitutes from live `oc get nodes`. Tested on PX 26.1.0 operator / 3.6.0 runtime, 2026-04-12. |

## License

TODO: pick a license before making the repo public.
