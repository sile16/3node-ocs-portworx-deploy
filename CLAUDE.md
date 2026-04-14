# CLAUDE.md

Guidance for Claude Code sessions on this repo.

## Doc rules

- **Don't duplicate code or config in docs.** Reference the file, summarize intent.
- File headers: short, single inline `#` comments. No multi-line "Why" blocks.

## What this repo is

A reference deployment for a 3-node OCP 4.21 TNA cluster (2 masters + 1 arbiter)
with Portworx Enterprise (RF=2). Target: many-site USB-ISO bare-metal rollout.

`deploy/` is the deliverable. `test/kvm/` is the libvirt regression env that
validates it — per-role VM spec in `test/kvm/vms/`, KVM-only MachineConfigs
in `test/kvm/machineconfigs/`, scripts at the top level of `test/kvm/`.

## Key invariants

- `startMiB` mandatory on every Ignition partition (omit → rootfs auto-grow eats the partition).
- No `filesystems:` / `systemd:` blocks in the px-storage MachineConfigs — Portworx wants raw partitions / devices
- Reference partitions by `partlabel`, not by number — Ignition may renumber.
- `device:` in MachineConfigs uses `/dev/disk/by-id/coreos-boot-disk` — hardware-agnostic symlink (RHCOS 4.11+).
- **Secure Boot must be OFF** on every node — Portworx `px.ko` is unsigned, blocks otherwise.
- StorageCluster TNA: `selector.nodeName` (not labelSelector) on every node, `systemMetadataDevice` on every master.
- PX `systemMetadataDevice` / `kvdbDevice` values must be **raw device paths** (`/dev/vda5`, `/dev/sda5`, …) — PX 3.6.0 has a symlink-resolution bug that breaks partlabel/by-id symlinks. `deploy/templates/98-px1-prepare.sh` resolves those per node via `oc debug` and patches `98-px4-` in place. Partlabel is still correct for the MC partition definitions and for any non-PX consumer.

## Memory

`~/.claude/projects/-home-sile-github-3node-ocs-portworx-deploy/memory/` holds
feedback notes from past sessions (auto-loaded). Read MEMORY.md first.
