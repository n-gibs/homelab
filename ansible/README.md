# Ansible

Provisions a 3-node k3s cluster on HP ProDesk Mini PCs using [k3s-ansible](https://github.com/k3s-io/k3s-ansible).

## Nodes

| Host | Role | IP |
|------|------|----|
| worker-00 (G4) | server + worker, `api_endpoint` | 192.168.30.129 |
| worker-01 (G9) | server + worker, NFS server, media label | 192.168.30.194 |
| worker-02 (G6) | server + worker | 192.168.30.136 |

SSH user: `homelab`

## Prerequisites

Install tools:

```bash
brew install just ansible ansible-lint
pip3 install passlib --break-system-packages
```

Deploy SSH key to all nodes:

```bash
ssh-copy-id homelab@192.168.30.194
ssh-copy-id homelab@192.168.30.129
ssh-copy-id homelab@192.168.30.136
```

## First-time setup

### 1. Install Ansible dependencies

```bash
just deps
```

### 2. Fill in TODO IPs

```bash
just todos
```

All node IPs are already filled in in `ansible/inventory.yml`.

### 3. Set up vault

Generate a token:
```bash
openssl rand -hex 32
```

Create vault password file (gitignored):
```bash
echo 'your-vault-password' > .vault_pass
chmod 600 .vault_pass
```

Edit vault with token:
```bash
just vault-edit
# set: vault_k3s_token: "your-token"
```

### 4. Run

```bash
just provision
```

## Common commands

```bash
just               # list all commands
just deps          # install galaxy dependencies
just ping          # test all nodes
just provision     # full provisioning run
just provision-common  # only the common role (base hardening), --tags common
just provision-nfs     # only the NFS server/client roles, --tags nfs
just dry-run       # check mode, no changes
just lint          # run ansible-lint
just vault-view    # inspect vault contents
just todos         # show remaining TODOs
```

## Structure

```
ansible/
├── inventory.yml          # Node inventory (server group — all 3 nodes are k3s server+worker)
├── site.yml               # Main playbook
├── requirements.yml       # k3s-ansible galaxy role
├── vault.yml              # Encrypted secrets (committed)
├── vault.yml.example      # Example vault structure
├── group_vars/
│   └── k3s_cluster.yml    # k3s version, shared flags, token ref
├── host_vars/
│   ├── worker-00.yml      # G4: drop control-plane taint (post-migration)
│   ├── worker-01.yml      # G9: media label (no taint)
│   └── worker-02.yml      # G6: no control-plane taint (schedulable)
└── roles/
    ├── common/               # SSH hardening, UFW, unattended-upgrades
    ├── nfs_server/            # NFS export of 12TB drive on worker-01
    ├── nfs_client/            # NFS mount on worker-00 and worker-02
    └── cert_manager_issuers/  # Apply ClusterIssuer manifests
```

## k3s Configuration

- CNI: Cilium (flannel + k3s network policy disabled)
- Ingress: Envoy Gateway (traefik + servicelb disabled)
- metrics-server disabled in k3s; deployed from `system/metrics-server` instead
- HA control plane: all 3 nodes are k3s server+worker, no taints at all; worker-01 carries a `homelab.io/media=true` label so media apps land on G9 via nodeSelector (see `docs/archive/g6-migration.md`)
- k3s version: v1.36.3+k3s1 — set as `k3s_version` in `group_vars/k3s_cluster.yml`, bumped by Renovate

## Node workarounds

The `common` role carries several fixes whose reasoning outruns a manifest comment. Each task
there keeps a one-line *why* and points here.

### containerd snapshotter

The native snapshotter once worked around an early Ubuntu 26.04 overlayfs problem. overlayfs is
healthy on these nodes now, and native has no union mount, so every layer is a full copy of its
parent: unpacking one 798MB image took 8m23s against 26s, and the store grew to 80G against 2.2G.
The task uses `state: absent` rather than deletion so already-provisioned nodes get cleaned up
too, and takes effect on the next k3s restart.

Changing snapshotters invalidates every image already on the node ("content digest not found"), so
a switch needs a full re-pull.

### k3s startup gate on the Cilium CNI socket

Cilium's `05-cilium.conflist` persists on disk once written. At boot containerd finds it and
kubelet marks the node Ready, while `/var/run` is a fresh tmpfs with no `cilium.sock`. kubelet
then starts every bound pod at once and cilium-cni fails the losers after a hard 30s wait for the
socket. CoreDNS is usually among them, so it presents as a per-node DNS outage on an
apparently-Ready node.

Dropping the stale conflist first makes the node honestly NotReady until the agent rewrites it.
`--register-with-taints=node.cilium.io/agent-not-ready` does **not** work here: taints apply only
at first Node registration, never on reboot.

The `ExecStartPre` is guarded on the socket so `systemctl restart k3s` against a healthy agent is
a no-op. k3s runs `KillMode=process`, which keeps the running agent alive across a k3s restart,
and the agent only writes the conflist during its own startup.

That same guard is what allows two cilium-agents on one node: a restart can build a new agent
container while the old process survives, and the two then fight over the shared BPF LB maps
invisibly. Reaping the old agent here was tried and reverted, because it trades a rare silent
failure for a routine one and the containerd-wedge remediation is exactly `systemctl restart k3s`.
The invariant belongs in the new agent's startup. Detection is the `CiliumAgentDuplicate` alert in
`system/monitoring-system/`.

### network-online.target

`k3s.service` already has `Wants=`/`After=network-online.target`, but that target is vacuous here.
`systemd-networkd-wait-online` is skipped every boot on an unmet `ConditionPathIsSymbolicLink`
pointing into `/run/systemd/generator/`, which exists on none of the three nodes. So nothing waits
for DHCP and k3s starts with no default route. `Restart=always` self-heals a normal reboot, but
during a cluster move, with the switch booting alongside the nodes, all three flap k3s and their
etcd members until the route appears.

Clearing the condition lets the unit run, which is all the target needs to mean something; k3s's
existing `After=` does the rest. It costs 7ms when the network is already up, and k3s uses
`Wants=` rather than `Requires=`, so a DHCP that never completes degrades to the old behaviour
instead of blocking the boot.

### inotify limits

`fs.inotify.max_user_instances` defaults to 128, charged per-UID, and every containerd-shim holds
two. worker-00 hit 129/128 at 37 pods, after which even PID 1 could not allocate an inotify fd.
An audit (`.claude/scripts/inotify-audit.py`) found no leak: the only growth term is pod count,
which kubelet caps at 110 per node, so 1024 is real headroom at the measured ~2.2 fds per pod.
`max_user_watches` is nowhere near its limit and was raised only for symmetry.

### USB drive head parking

worker-01's 12TB WD ships at APM 128, which parks the heads ~50 times an hour on a drive that is
0.02% busy: 9% of its 600k load-cycle rating in five weeks. APM 254 stops it outright with no
temperature penalty.

The rule fires on udev `add`/`change` rather than a boot-time unit, because APM is volatile and
resets whenever the drive loses power, which on USB includes bus re-enumeration with the node
still up.

It uses `smartctl` rather than `idle3ctl` or `hdparm`: the WD120EDGZ is an Ultrastar He12
white-label with no idle3 timer, so unload is APM alone, and APM over SAT needs no vendor commands
aimed at the disk backing every NFS PVC in the cluster.

It matches on vendor and model rather than serial. The shucked drive hangs off a generic SATA-USB
bridge that fabricates an unstable identity, with `ID_SERIAL_SHORT` and `ID_WWN` both
`5000000000000001` and the by-id link re-randomised per enumeration. The SCSI INQUIRY strings are
the only bridge-independent fields left, and worker-01 has exactly one USB disk.

Both this rule and the SMART textfile exporter exist for that one drive. Once `/mnt/storage` moves
to a NAS the nodes have only NVMe left, hwmon covers it, and both should be deleted rather than
left emitting nothing. The disk half of
`system/monitoring-system/prometheusrule-temperature.yaml` goes with them.

### SMART temperature exporter

CPU and NVMe temperatures already reach Prometheus free through node-exporter's hwmon collector.
USB-attached drives have no hwmon entry, since `drivetemp` binds to SATA hosts rather than
usb-storage, so worker-01's 12TB WD is invisible to it. That drive is the only spinning disk and
the hottest sensor in the cluster, at 61C against a 65C spec maximum. Feeding it through the
textfile collector beats adding a second exporter, and it emits nothing on a node with no
SMART-readable non-NVMe disk.

### NVMe APST on worker-02

The WD PC SN740 in worker-02 stops answering shortly after boot if it picks its own power state.
`nvme_core.default_ps_max_latency_us=0` disables APST outright and is the only value this drive
has actually run on. A 5000us limit, which would leave ps3 and block ps4/ps5, was tried once and
remains untested: the node needed a physical M.2 reseat before it would POST again, so that boot
never reached the kernel. The saving at stake is 0.010W, and the heat this was chasing is the ACPI
`_CST` C3 ceiling rather than the drive.

The module parameter is writable at runtime but `nvme reset` will not re-read it, so an APST
change cannot be tested without a reboot.

### UFW rules

Cilium's health and metrics ports are allowed from the node subnet rather than the pod subnet.
Prometheus scrapes a node IP, which is outside the cluster CIDR, so Cilium masquerades the pod
source to the scraping node's own address. Without those rules the default deny made every
cross-node probe time out while ICMP and pod-to-pod both passed: cilium-health read 1/3 reachable
on all three nodes, and the Cilium scrape only ever worked on whichever node Prometheus happened
to be running on.

The etcd ports (2379 client, 2380 peer, 2381 metrics) listen on the node IP on every server. They
were hand-added and never written down, which is the only reason the HA control plane worked while
the role claimed to describe the firewall. They are now scoped to the node subnet, because every
etcd peer is on `192.168.30.0/24` and nothing off that subnet has any business holding a cluster
datastore connection.

The blanket allow from the pod CIDR is kept deliberately. Pods reach the host on more ports than
anyone can enumerate (kubelet, hostPort metrics endpoints, NFS, cilium-health) and the failure
mode of missing one is a silent timeout that reads as a network fault, which has already cost real
hours. The pod CIDR is inside the cluster's trust boundary: anything that can source from it is
already running on these nodes.

Four rules were removed rather than codified. Nothing listens on 5001 on any node, there is no
registry mirror for it, and Tailscale uses 41641/udp outbound and has been working all along
without an inbound allow, so 51820 and 51821 were WireGuard ports for a WireGuard nobody runs. The
service-CIDR rule matched nothing, because a service IP is a destination that DNAT rewrites, so no
packet ever arrives with a source address in `10.43.0.0/16`. The ufw module only adds, so these
need an explicit delete to leave the nodes.
