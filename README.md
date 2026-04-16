# 3node-ocs-portworx-deploy

Reference deployment for a 3-node OpenShift 4.21 TNA cluster (2 masters + 1
arbiter) with Portworx Enterprise providing RF=2 storage. Target: many-site
USB-ISO bare-metal rollouts.

Key Requirements: 

- Process needs to be automated across many sites in repeatable fashion.
- Arbiter node has a single drive for OS and portworx kvdb 
- Needs to partition prior to /var exampanding and using full disk.
- Need to map partition info to a block device.

Challenges: 

- Physical hosts have different boot device names we have seen sda, sdb, nvme0n1, (vda in kvm)

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
│   ├── 98-machineconfig-master.yaml                 master px-metadata + px-data partitions (agent-installer manifest; 98- = customer MC layer)
│   ├── 98-machineconfig-arbiter.yaml                arbiter px-metadata partition            (agent-installer manifest)
│   ├── 98-px1-prepare.sh                            apply Kubernetes node labels (portworx.io/node-type) so StorageCluster's nodeAffinity matches
│   ├── 98-px2-configmap-clulster-monitoring.yaml    cluster-monitoring user-workload enable
│   ├── 98-px3-subscription.yaml                     OLM install of portworx-certified
│   ├── 98-px4-storagecluster.yaml                   TNA StorageCluster; uses partlabel symlink for px-metadata (safe with `useAll: true`)
│   ├── 98-px5-register.sh                           optional site-specific license / px-central registration
│   ├── aicli_parameters.yml                    aicli input: VIPs, hosts, MACs, pull secret
│   └── check_px_status.sh                      one-shot health snapshot (OCP + PX), flags known-bad symptoms
└── sites/<site>/                           rendered, per-site, gitignored — what the site operator ships against
```

## Install flow (bare metal)

```sh
# 0. Add/update your site row in deploy/sites.csv, then render its dir.
cd deploy
./render.sh austin                         # → deploy/sites/austin/*

# 1. Cluster install via aicli (ISO burnt to USB, boot all 3 nodes).
#    98-machineconfig-{master,arbiter} are packed into the agent installer ISO here.
cd sites/austin
aicli create cluster    --paramfile aicli_parameters.yml prod-aus
aicli create deployment --paramfile aicli_parameters.yml prod-aus
# wait ~30-60 min for install-complete

# All steps below require a working `oc` authenticated to the new cluster.
# `aicli` already produces a kubeconfig; grab its path with:
#    export KUBECONFIG=$(aicli info cluster prod-aus -f kubeconfig)
# If you already have `oc get nodes` working against this cluster, skip that.

# 2. (Secure-Boot-enabled sites only) MOK-enroll the Portworx signing cert on each node.
#    Skip if Secure Boot is disabled in BIOS and go to step 3.
./98-px0-enroll-mok-secure-boot.sh                    # stages mokutil --import + prints reboot checklist
# reboot each node via IPMI/iDRAC/iLO; answer MokManager (~10 s prompt) with the printed password
./98-px0-enroll-mok-secure-boot.sh --verify           # confirms Portworx CA is in each node's enrolled MOKs

# 3. Portworx bring-up — run the numbered steps in order.
./98-px1-prepare.sh                       # labels masters + arbiter
oc apply -f 98-px2-configmap-clulster-monitoring.yaml
oc apply -f 98-px3-subscription.yaml
# installPlanApproval is Manual + pinned via startingCSV — approve before waiting.
oc -n portworx patch "$(oc -n portworx get installplan -o name | head -1)" \
  --type merge -p '{"spec":{"approved":true}}'
oc -n portworx wait --for=condition=Available deploy/portworx-operator --timeout=10m
oc apply -f 98-px4-storagecluster.yaml
./98-px5-register.sh                      # optional, site-specific license
./check_px_status.sh                      # sanity check at any point
```

## Pre-install checklist

- [ ] **Secure Boot:** either disabled in BIOS, OR enabled + plan for one-time MOK enrollment on first boot (run `./98-px0-enroll-mok-secure-boot.sh`, reboot each node, answer MokManager prompt). PX 3.6.0 `px.ko` is signed by the "Portworx Secure Boot CA @2025"; the enroll script downloads the CA on each node (pinned URL + sha256 at the top of the script) and stages `mokutil --import`. Nodes need outbound internet at enrollment time. See `docs/portworx-design.md` → "Secure Boot".
- [ ] Install disks ≥256 GB (170 GiB rootfs + 64 GiB px-metadata + margin).
- [ ] `pull_secret:` path in `deploy/templates/aicli_parameters.yml` points at a valid pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
- [ ] `api_vip` and `ingress_vip` columns in `deploy/sites.csv` are free, routable IPs on the site's machine network.
- [ ] Hostnames and MACs are set only in `deploy/sites.csv`; those same values land in both `aicli_parameters.yml` (via the agent installer) and `98-px4-storagecluster.yaml` (`nodeName` fields) at render time.
- [ ] Network between nodes allows Portworx ports (TCP 17001-17022, UDP 17002 — `startPort: 17001` in `98-px4-storagecluster.yaml`).

## Hardware assumptions

- **Masters (×2)**: an install disk ≥256 GB (any whole device). Optional second raw disk is auto-discovered as additional Portworx capacity.
- **Arbiter (×1)**: single install disk ≥256 GB, no second disk needed (storageless, holds KVDB metadata only).

The MachineConfigs use `/dev/disk/by-id/coreos-boot-disk` — a stable RHCOS
udev symlink — so they are hardware-agnostic across SSD/NVMe/SATA targets.
The assisted installer picks the install disk itself (largest by default);
if a site needs to constrain it, add a per-host `installation_disk_id:` to
the `hosts:` entries in `templates/aicli_parameters.yml`. PX references the
px-metadata partition via its `/dev/disk/by-partlabel/` symlink, which stays
hardware-agnostic because the GPT partition label (partition-name entry in the
GPT table, not a filesystem label or Kubernetes label) is set by the same
MachineConfig regardless of boot-disk device name.

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
  ./98-px1-prepare.sh && \
  oc apply -f 98-px2-configmap-clulster-monitoring.yaml && \
  oc apply -f 98-px3-subscription.yaml && \
  oc -n portworx patch "$(oc -n portworx get installplan -o name | head -1)" --type merge -p '{"spec":{"approved":true}}' && \
  oc -n portworx wait --for=condition=Available deploy/portworx-operator --timeout=10m && \
  oc apply -f 98-px4-storagecluster.yaml
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
| 2026-04-13 | `c12a305` | 4.21.9 | 3.6.0    | libvirt                    | 986 GiB (2×493)         | First end-to-end pass of the new `deploy/` layout: per-site `render.sh <site>` driven by `sites.csv` → `98-px1-prepare.sh`  |
| 2026-04-14 | `cabd6f1` | 4.21.9 | 3.6.0    | libvirt                    | 986 GiB (2×493)         | Full re-validation (`test/kvm/logs/fullrun-20260414T091709.log`, ~60 min wall). Teardown → `generate-iso.sh` → `create-vms.sh` → install-complete → `render.sh austin` → 98-px2 → 98-px1-prepare → 98-px3 → InstallPlan approve → 98-px4. StorageCluster phase=Running, 3/3 StorageNodes Online (986 GiB), smoke test PVC bound on `px-csi-replicated`, sentinel write/read OK.  |
| 2026-04-14 | `fd983d3` | 4.21.9 | 3.6.0    | libvirt + **Secure Boot**  | 986 GiB (2×493)         | First SB-on validation (`test/kvm/logs/fullrun-sb-mok-20260414T124755.log`). All 3 VMs booted with `OVMF_CODE_4M.secboot.fd` + per-VM NVRAM pre-seeded by `host-setup/px-secboot-vars.sh` (Portworx CA in both UEFI `db` AND MOK via `virt-fw-vars --add-mok --add-db`). Smoke test PVC bound + write/read OK. **Key finding:** `--add-db` alone is NOT enough — PX 3.6.0 px-runc pre-flight specifically checks the MOK list (`SecureBootCertNotEnrolled` alarm on db-only setup); must seed MOK too. |
| 2026-04-15 | `c217e5e` | 4.21.9 | 3.6.0    | libvirt + SB + **KubeVirt** | 986 GiB (2×493)        | Full stack: OCP + PX + OpenShift Virtualization (CNV 4.21.3). 24 GiB master VMs (bumped from 16 for CNV headroom; host KSM dedupes ~16 GiB across 3 RHCOS VMs, swap enabled). PX auto-detected HCO but didn't auto-create KubeVirt SCs — created manually: `px-rwx-block-kubevirt` (repl=2, nodiscard, default virt class), `px-rwx-file-kubevirt` (sharedv4), `px-cdi-scratch` (repl=1). CDI imported Cirros 0.6.2 into a 1 GiB RWX Block PVC on `px-rwx-block-kubevirt`; VirtualMachine `vm-pxtest` Running, Ready=True, PX volume HA=2 shared-block attached. |

## Resilience tests

All validated 2026-04-14 on libvirt with Secure Boot ON. Together these show that **Portworx 3.6.0 tolerates the full class of "GPT partition-label / MOK-enrollment got disturbed" failures without corrupting data or needing a StorageCluster rebuild** — which is exactly the robustness you want when a large fleet deploy hits one weird node.

| Test | What we did | PX behavior |
|---|---|---|
| **GPT partition-name renamed + node rebooted** | `sgdisk --change-name=5:px-metadata-broken /dev/vda` → reboot. `/dev/disk/by-partlabel/px-metadata` symlink (udev-generated from the GPT partition-name field) is gone after boot. | **Self-recovered** in ~60–90 s. `pxctl status` showed `Metadata Device: /dev/vda5` — PX fell back to filesystem-UUID discovery (the XFS filesystem label `mdvol` that PX writes inside the partition, distinct from the GPT partition-name). Cluster stayed `phase=Running`. Restoring the GPT partition-name with `sgdisk --change-name` was immediate, non-disruptive. |
| **SB on, no PX cert anywhere** (E1) | Installed cluster with SB enabled and zero Portworx trust in UEFI db / MOK. Applied full PX bring-up. | Clean failure. `pxctl alerts`: `SecureBootCertNotEnrolled`. `px-runc` exits before touching any device. StorageCluster stuck at `Initializing`. **All 6 GPT partition labels on every node intact.** No disk writes. |
| **Progressive MOK enrollment** (E2 → E3) | From the E1 failed state, added PX cert to master-1 only → observed asymmetric cluster. Then added to arbiter → 2/3 Online, still no quorum for writes. Then added to master-2 → full cluster. | Cluster healed incrementally. No teardown/reapply of the StorageCluster needed. `phase` went `Initializing → Degraded → Initializing → Running` as quorum arrived. **Partition labels intact through every transition.** |

**Takeaways**

- **A missing `/dev/disk/by-partlabel/<name>` symlink alone does not break PX.** PX caches the filesystem UUID of its metadata device and rediscovers the raw partition even when the symlink is gone. A missing `by-partlabel` dir on a failing node is a symptom, not a cause — the real question is whether the partition device node (e.g. `/dev/sdX5`) still exists.
- **PX's normal code paths don't modify GPT.** Across the no-cert install, partial-fix, and full-recovery cycles, every GPT partition entry (name, type, offsets) survived byte-identical. If a node in the wild has a wiped GPT, the cause is external to PX's bring-up (e.g. operator ran `wipefs -a` / `sgdisk --zap-all` during debugging, or a re-provisioning script targeted the wrong disk).
- **Asymmetric fix-up is safe.** Per-node MOK enrollment can land at its own pace — the StorageCluster doesn't need to be deleted and re-applied; PX promotes nodes to `Online` as their local cert becomes valid.
- **Recovery recipe for a wiped GPT:** while the kernel's in-memory partition table still holds (don't reboot yet), capture exact start/size sectors from `/sys/block/<disk>/<diskN>/{start,size}`, then rebuild GPT with `sgdisk --new=… --typecode=… --change-name=…` matching, then `udevadm trigger`. See `docs/portworx-design.md`.

## Known-broken configs

| Config | Fails how | Workaround |
|---|---|---|
| `useAllWithPartitions: true` + any symlink `systemMetadataDevice` (partlabel, by-id, …) | PX 3.6.0 doesn't canonicalize the symlink before cross-referencing against the partition list it enumerates under `useAllWithPartitions`. The underlying partition lands in both metadata + storage lists → init fails with `device … has a filesystem on it with labels any:pwxN`. Reproduced with partlabel and with custom by-id udev symlinks. | Don't combine `useAllWithPartitions: true` with symlinks. The shipped config sticks to `useAll: true` (whole disks only) + partlabel `systemMetadataDevice`, which is safe because `useAll` never enumerates partitions — so the symlink target isn't double-counted. If you genuinely need `useAllWithPartitions`, resolve `systemMetadataDevice` to a raw path per-node (e.g. `/dev/vda5`, `/dev/sda5`, `/dev/nvme0n1p5`). Tangential KVM lesson from the repro run: virtio-blk truncates disk `serial=` to 20 chars, so any udev rule matching on a hostname-suffix needs virtio-scsi (SCSI VPD 0x80 accepts the full string; `scsi_id` populates `ID_SERIAL_SHORT` cleanly). |
| `nodes[].selector.labelSelector` on TNA StorageCluster (instead of `nodeName`) | **Admission accepts it** (`oc apply --dry-run=server` passes, object stores fine), then the operator reconcile rejects at `storagecluster.go:3320`: `"Failed to create TNA NodeSpecs: NodeSpec for arbiter node <hostname> not found, please add it to the storage cluster spec"`. StorageCluster phase flips to `Degraded`. | TNA reconcile does an exact `nodeName` lookup per node — labelSelector matches aren't consulted. Ship exact `nodeName` on every entry; `deploy/render.sh` substitutes `${MASTER1_HOST}` / `${MASTER2_HOST}` / `${ARBITER_HOST}` from the site's row in `deploy/sites.csv`. Tested on PX 26.1.0 operator / 3.6.0 runtime, 2026-04-12. |

## License

TODO: pick a license before making the repo public.
