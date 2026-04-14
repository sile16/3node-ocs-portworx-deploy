# RUNBOOK — libvirt regression environment

How to reproduce the cluster end-to-end on a fresh Ubuntu 24.04 host using
the libvirt test harness in `test/kvm/`.

For bare-metal rollout, skip the libvirt setup and use `aicli` against the
assisted-installer, driven by the site's row in `deploy/sites.csv`:

```sh
cd deploy
./render.sh <site>                                           # produces deploy/sites/<site>/*
cd sites/<site>
aicli create cluster    --paramfile aicli_parameters.yml <cluster_name>
aicli download iso      <cluster_name>                       # pulls <cluster_name>.iso
# boot each node from the ISO — any of: USB stick, virtual media/CD (iDRAC,
# iLO, IPMI), or PXE/HTTP-boot the extracted kernel+initrd+rootfs.
# USB: sudo dd if=<cluster_name>.iso of=/dev/sdX bs=4M status=progress conv=fsync
# Hosts register with assisted-service by MAC (see `hosts:` in paramfile).
aicli wait cluster <cluster_name>                            # blocks until install-complete
export KUBECONFIG=$(aicli info cluster <cluster_name> -f kubeconfig)

# Portworx bring-up, in numeric order:
oc apply -f 98-3-configmap-clulster-monitoring.yaml
./98-4-prepare-for-portworx.sh       # labels + resolves per-node raw metadata device, generates 98-6-*.yaml
oc apply -f 98-5-portworx-subscription.yaml
# InstallPlan is Manual + pinned via startingCSV; approve it before waiting.
IP=$(oc -n portworx get installplan -o name | head -1)
oc -n portworx patch "$IP" --type merge -p '{"spec":{"approved":true}}'
oc -n portworx wait --for=condition=Available deployment/portworx-operator --timeout=10m
oc apply -f 98-6-portworx-storagecluster.yaml
./98-7-portworx-register.sh          # optional license activation
./check_px_status.sh               # health snapshot
```

`full_iso: true` in the paramfile embeds the rootfs in the ISO so nodes don't
download it from assisted-service at boot — useful on slow or flaky links. The
nodes still need network connectivity to assisted-service during install for
discovery and progress reporting.

## Prereqs

- Ubuntu 24.04 LTS, x86_64
- VT-x / AMD-V enabled in BIOS (`grep -c vmx /proc/cpuinfo` > 0)
- 16 logical CPUs, 48 GiB RAM, 80 GiB free under `/var/lib/libvirt/images`
- Outbound internet (first install pulls ~26 GiB)
- `~/.local/pullsecret` (download from console.redhat.com/openshift/install/pull-secret)
- `~/.ssh/id_rsa.pub`
- `oc`, `kubectl`, `openshift-install` (matching OCP 4.21.x) on `$PATH`

## End-to-end flow

```sh
cd test/kvm

./envsetup.sh                             # one-time: apt + libvirt + docker + tna-net
./host-setup/registry-cache.sh up         # optional: pull-through quay.io cache
./host-setup/autostart-watcher.sh start   # REQUIRED: agent installer poweroff workaround

./generate-iso.sh                         # render install-config + build agent ISO
./create-vms.sh                           # define + boot 3 VMs

./wait-bootstrap.sh                       # bootstrap-complete (~15-25 min)
./wait-bootstrap.sh install-complete      # install-complete (~20-30 min)

sudo ./host-setup/update-etc-hosts.sh add # so `oc` can reach the cluster
export KUBECONFIG=$PWD/generated/auth/kubeconfig
oc get nodes                              # expect 3 Ready

./collect-cluster-state.sh                # per-node partition validation

# Portworx — render the site dir, then run the numbered steps in order.
(cd ../../deploy && ./render.sh test-kvm)
cd ../../deploy/sites/test-kvm
oc apply -f 98-3-configmap-clulster-monitoring.yaml
./98-4-prepare-for-portworx.sh
oc apply -f 98-5-portworx-subscription.yaml
IP=$(oc -n portworx get installplan -o name | head -1)
oc -n portworx patch "$IP" --type merge -p '{"spec":{"approved":true}}'
oc -n portworx wait --for=condition=Available deployment/portworx-operator --timeout=10m
oc apply -f 98-6-portworx-storagecluster.yaml
./check_px_status.sh
cd -

./portworx/05-smoke-test.sh               # PVC bind + write/read

./teardown.sh                             # destroy VMs + clean pool volumes
```

## Observability (anytime during install)

- `./status.sh` — domains, CPU, disk, log tail, rendezvous containers
- `./snapshot-consoles.sh` — PNG of each VM's console
- `./rendezvous-logs.sh` — assisted-service container logs
- `tail -F /tmp/agent-bootstrap.log`
- `./host-setup/autostart-watcher.sh logs`

## Pass criteria

After `collect-cluster-state.sh`:
- Every node: `/dev/disk/by-partlabel/px-metadata` present, ~64 GiB
- Masters also: `/dev/disk/by-partlabel/px-data` present (rest of disk)
- Rootfs grew to ~170 GiB (= `startMiB` in `deploy/templates/98-{0,1}-machineconfig-*.yaml`)
- `findmnt /var/lib/portworx` returns non-zero (NOT a separate mount)
- `oc get mcp` shows master + arbiter pools both `UPDATED=True`

After the Portworx bring-up (98-3 → 98-4 → 98-5 → 98-6) + smoke test:
- `pxctl status` reports `PX is operational`, all 3 nodes Online
- `pxctl cluster list` shows storage on masters, "No Storage" on arbiter
- Smoke test PVC binds + writes + reads against `px-csi-replicated`

## Gotchas (encoded in scripts; surfaced in memory)

- `virt-install --cdrom` blocks forever — `create-vms.sh` backgrounds + kills it after `virsh domstate=running`.
- Agent installer issues `poweroff` (not reboot) post-write-to-disk; libvirt's default `on_poweroff=destroy` would orphan the install. `autostart-watcher.sh` restarts the domain within ~2 s.
- `agent-config.yaml` `rootDeviceHints.deviceName` must match the actual guest device — change one, change both.
- First install populates the registry cache; the speedup shows on the second install onward.
- Secure Boot off in the libvirt firmware (`create-vms.sh` uses `OVMF_CODE_4M.fd`, non-SB variant) — Portworx's `px.ko` is unsigned.

## Full purge

```sh
./teardown.sh
./host-setup/autostart-watcher.sh stop
./host-setup/registry-cache.sh purge
sudo ./host-setup/update-etc-hosts.sh remove
virsh -c qemu:///system net-destroy tna-net && virsh -c qemu:///system net-undefine tna-net
```
