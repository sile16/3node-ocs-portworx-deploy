# RUNBOOK 1 — Test environment setup (libvirt / KVM)

Set up the 3-VM libvirt cluster on a fresh Ubuntu 24.04 host. This
environment mirrors the bare-metal topology so `deploy/` manifests can be
validated before shipping to real hardware.

## Prereqs

- Ubuntu 24.04 LTS, x86_64
- VT-x / AMD-V enabled in BIOS (`grep -c vmx /proc/cpuinfo` > 0)
- 16 logical CPUs, 64 GiB RAM (24 GiB per master + 8 GiB arbiter + host overhead)
- 80 GiB free under `/var/lib/libvirt/images`
- Outbound internet (first install pulls ~26 GiB)
- `~/.local/pullsecret` (download from console.redhat.com/openshift/install/pull-secret)
- `~/.ssh/id_rsa.pub`
- `oc`, `kubectl`, `openshift-install` (matching OCP 4.21.x) on `$PATH`
- `aicli` (`pip install aicli`) — assisted-installer CLI for cluster creation + kubeconfig
- `python3-virt-firmware` (`apt install python3-virt-firmware`) for Secure Boot NVRAM seeding

## Host tuning

```sh
# KSM — dedupes ~16 GiB across 3 similar RHCOS VMs
sudo sh -c 'echo 10000 > /sys/kernel/mm/ksm/pages_to_scan'
sudo sh -c 'echo 50    > /sys/kernel/mm/ksm/sleep_millisecs'
sudo sh -c 'echo 1     > /sys/kernel/mm/ksm/run'

# Swap — safety net for memory peaks during CNV install
sudo swapon /swapfile   # or create: fallocate -l 16G /swapfile && mkswap /swapfile
```

## One-time setup

```sh
cd test/kvm
./envsetup.sh                             # apt + libvirt + docker + tna-net
./host-setup/registry-cache.sh up         # optional: pull-through quay.io cache
```

## Build + boot the cluster

```sh
./host-setup/autostart-watcher.sh start   # REQUIRED before create-vms.sh
./generate-iso.sh                         # render install-config + build agent ISO
./create-vms.sh                           # define + boot 3 VMs (Secure Boot ON)

./wait-bootstrap.sh install-complete      # blocks ~30-50 min

sudo ./host-setup/update-etc-hosts.sh add
export KUBECONFIG=$PWD/generated/auth/kubeconfig
oc get nodes                              # expect 3 Ready
./collect-cluster-state.sh                # per-node partition validation
```

### Secure Boot

`create-vms.sh` boots with `OVMF_CODE_4M.secboot.fd` + per-VM NVRAM
pre-seeded by `host-setup/px-secboot-vars.sh` (Portworx CA in UEFI db + MOK).
Set `SEED_PX_CERT=no` before `create-vms.sh` to simulate a bare-metal node
without MOK enrollment (for failure-mode testing).

### Snapshots (for fast iteration)

```sh
# Save (VMs must be shut off)
./snapshot-save.sh <name>

# Revert
./snapshot-restore.sh <name>
virsh start master-1.example.local master-2.example.local arbiter-1.example.local
```

## Teardown

```sh
./teardown.sh                             # destroy VMs + clean pool volumes
```

## Full purge

```sh
./teardown.sh
./host-setup/autostart-watcher.sh stop
./host-setup/registry-cache.sh purge
sudo ./host-setup/update-etc-hosts.sh remove
virsh -c qemu:///system net-destroy tna-net && virsh -c qemu:///system net-undefine tna-net
```

## Observability (anytime)

- `./status.sh` — domains, CPU, disk, log tail
- `./snapshot-consoles.sh` — PNG of each VM's console
- `./rendezvous-logs.sh` — assisted-service container logs
- `tail -F /tmp/agent-bootstrap.log`
- `./host-setup/autostart-watcher.sh logs`
