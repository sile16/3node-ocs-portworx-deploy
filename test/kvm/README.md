# test/kvm — libvirt regression environment

A 3-VM mini-cluster on local libvirt that exercises the manifests in `deploy/`
end-to-end before they touch real hardware.

For end-to-end reproduction, see `docs/RUNBOOK.md`. This README is a layout
index + libvirt-specific gotchas.

## Layout

```
test/kvm/
├── vms/                          KVM node spec (edit here — no scripts)
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

The two masters use virtio-blk (`/dev/vda` boot + `/dev/vdb` data); the
arbiter uses virtio-scsi (`/dev/sda`). Mixing bus types is deliberate — it
exercises `deploy/`'s `coreos-boot-disk` symlink on both. VIPs are `.10`
(API) and `.11` (Ingress); network is dedicated NAT `tna-net` on
192.168.125.0/24, DHCP reservations pin each MAC to its IP.

## Scripts

| Group              | Files                                                              |
|--------------------|--------------------------------------------------------------------|
| One-time setup     | `envsetup.sh`, `host-setup/registry-cache.sh`, `host-setup/autostart-watcher.sh` |
| ISO build          | `build-iso.sh`, `generate-iso.sh`, `upload-iso-to-pool.sh`         |
| Cluster lifecycle  | `create-vms.sh`, `wait-bootstrap.sh`, `teardown.sh`                |
| Observability      | `status.sh`, `snapshot-consoles.sh`, `rendezvous-logs.sh`          |
| Validation         | `collect-cluster-state.sh`, `host-setup/update-etc-hosts.sh`       |
| Portworx           | `portworx/05-smoke-test.sh`, `portworx/99-teardown.sh`             |

`build-iso.sh` copies MachineConfigs from `../../deploy/templates/01-` and
`../../deploy/templates/02-` into the agent installer's manifest dir, then
layers every `*.yaml` in `./machineconfigs/` on top. Edit a
`deploy/templates/*.yaml` (bare-metal canonical) or a `./machineconfigs/*.yaml`
(KVM-only) and the next `generate-iso.sh` picks it up — no forks.

`create-vms.sh` reads `vms/nodes.conf` and sources `vms/<role>.conf` per
node, so tuning resources or adding a host is a config-file edit.

## Ephemeral (gitignored)

- `generated/` — install-config.yaml, openshift/, agent.x86_64.iso, auth/
- `logs/` — snapshots, console captures, per-node validation logs
- `host-setup/registry-cert.pem`, `registry-key.pem` — generated on first run

## Libvirt-specific gotchas

- **`virt-install --cdrom` blocks forever.** `create-vms.sh` backgrounds it and kills the wrapper after `virsh domstate=running`.
- **Agent installer issues `poweroff` post-write-to-disk.** libvirt's default `on_poweroff=destroy` would orphan the install. Run `host-setup/autostart-watcher.sh start` BEFORE `create-vms.sh` — it polls `domstate` and restarts shut-off VMs within ~2 s. `create-vms.sh` launches it automatically.
- **`agent-config.yaml` `rootDeviceHints.deviceName` must match the actual guest device.** Mismatch causes a silent "ready but never installing" stall.
- **`bus='nvme'` is rejected by libvirt's domain XML schema.** Masters use `virtio-blk` (`/dev/vda`), arbiter uses `virtio-scsi` (`/dev/sda`). The `coreos-boot-disk` symlink in `deploy/templates/01-/02-` makes the MachineConfigs bus-agnostic.
- **Secure Boot off in firmware.** `create-vms.sh` uses the non-SB OVMF firmware variant — required for Portworx `px.ko`.
- **`virt-install`'s disk-size check sums VIRTUAL sizes.** `create-vms.sh` passes `--check disk_size=off,path_in_use=off`.

## Iteration speed: the registry cache

`host-setup/registry-cache.sh up` runs a `registry:2` container at
`https://192.168.125.1:5000` as a transparent pull-through proxy for `quay.io`.
First install populates the cache; subsequent installs cut wall-clock by ~25 min.

When `host-setup/registry-cert.pem` is present, `build-iso.sh` auto-inlines it
into `install-config.yaml`'s `additionalTrustBundle`. When absent (e.g. on a
bare-metal build host), a mirror-free ISO is produced — same script, no flags.
