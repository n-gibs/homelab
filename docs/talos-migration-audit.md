# Talos Linux Migration Audit — homelab (k3s → Talos)

Date: 2026-08-10. Audited against the repo at commit `62e4a30`.

> **Superseded in part.** Longhorn was deployed 2026-08-13 (see
> `docs/archive/superpowers/specs/2026-08-13-longhorn-deployment-design.md` and
> `docs/superpowers/plans/2026-08-13-longhorn-deployment.md`), replacing the eight `local-path`
> config/app-tree volumes this audit assumed would need a `local-path-provisioner` port to Talos.
> §3 and §5 below are corrected accordingly. The NFS blocker in §2 is unchanged.

## Verdict

**Don't do it as a like-for-like migration.** One hard blocker dominates everything else:
**worker-01 is the cluster's NFS server**, and Talos cannot run `nfs-kernel-server` as a host
service. Every other item on this list is tractable — most are genuinely *better* on Talos —
but that one either forces a container-based NFS server hack on the node holding all your bulk
data, or forces the NAS purchase that `roles/common` already has two `TODO(NAS)` markers for.

The clean sequencing is: **NAS first, Talos second.** Once `/mnt/storage` is off worker-01, the
migration goes from "rebuild the storage layer and the OS at once" to a boring node-by-node
rolling reinstall.

---

## Layer-by-layer

### 1. Kubernetes control plane — trivial

`k3s_version: v1.36.3+k3s1`, 3-node embedded etcd, all three servers. Talos is the same shape:
3 control-plane nodes with `allowSchedulingOnControlPlanes: true`, real etcd instead of k3s's
embedded one.

The k3s server flags map cleanly and most just vanish:

| k3s flag | Talos |
|---|---|
| `--disable traefik` | n/a — Talos ships none |
| `--disable servicelb` | n/a |
| `--disable metrics-server` | n/a — you already deploy your own (`system/metrics-server`) |
| `--flannel-backend=none` | `cluster.network.cni.name: none` |
| `--disable-network-policy` | implied by `cni: none` |
| `--write-kubeconfig-mode=644` | n/a — `talosctl kubeconfig` |
| `--resolv-conf /run/systemd/resolve/resolv.conf` | n/a — no systemd-resolved; Talos manages resolv.conf |
| `--node-label homelab.io/media=true` | `machine.nodeLabels` |
| control-plane taint on worker-00 | `machine.nodeTaints` |

Note the inconsistency this audit surfaced independent of Talos: `group_vars` sets
`extra_server_args` with a control-plane `NoSchedule` taint as the group default, but every
host either overrides it or is documented as schedulable. Worth reconciling either way.

**Effort: low.** This is a `machine.yaml` patch set, ~100 lines total.

---

### 2. NFS server on worker-01 — **BLOCKER**

Current state (`ansible/roles/nfs_server`):
- 12TB USB-attached WD, XFS, mounted at `/mnt/storage` by UUID with `x-systemd.automount`
- `nfs-kernel-server` exporting to `192.168.30.0/24` with `no_root_squash`
- Consumed by: `system/nfs-provisioner` (the `nfs` StorageClass), 10 app `values.yaml` files
  mounting `type: nfs` directly, and 2 static PVs (`immich/library-pv.yaml`,
  `nextcloud/data-pv.yaml`)

Talos has an [`nfsd` system extension](https://github.com/siderolabs/extensions) (extra tier) —
but read the description carefully: it provides *the kernel module driver only*. There is no
`rpc.nfsd`, no `exportfs`, no `/etc/exports`, no systemd unit to own the export. You would be
running the NFS server userspace in a privileged container with `hostNetwork`, driving the
in-kernel nfsd via a hostPath-mounted `/proc/fs/nfsd`, against a hostPath-mounted user volume.

That is a lot of moving parts wrapped around the single filesystem that every media app, both
Postgres backup targets, and every arr's backup destination depends on — and worker-01 already
has a documented failure mode where the drive drops off the USB bus and the NFS server does not
come back on its own (2026-08-08, obs 4707–4711). Adding a container-lifecycle dependency on
top of that is moving in the wrong direction.

**Options, ranked:**

1. **NAS first.** Move `/mnt/storage` to dedicated hardware. `nfs-subdir-external-provisioner`
   needs one IP change; the 10 app `type: nfs` mounts need one IP change; the 2 static PVs need
   one IP change. Talos then only ever needs to be an NFS *client*, which is fully supported
   (add `nfs-utils` for NFSv3 locking if anything needs it — check whether the arrs do). This
   also retires the `TODO(NAS)` blocks and the whole SMART-exporter problem in §5.
2. **Keep worker-01 on Ubuntu.** Two Talos control-plane nodes + one Ubuntu k3s node is not a
   thing — you'd need worker-01 out of the cluster entirely as a pure NAS box, dropping you to
   a 2-node control plane (no etcd quorum tolerance). Bad.
3. **nfsd extension + privileged server pod.** Technically possible, poorly trodden, and it
   puts your data path behind a pod that must start before the storage layer that ArgoCD's
   wave 1 depends on. Not recommended.

**Effort: high, or zero if you buy the NAS first.**

---

### 3. Stateful app volumes — now Longhorn, not `local-path`

This section originally recommended porting Rancher's `local-path-provisioner` to Talos, because
at audit time all eight config/app-tree volumes were pinned to `local-path`. As of 2026-08-13 all
eight are on Longhorn instead (`sonarr-config`, `radarr-config`, `lidarr-config`, `prowlarr-config`,
`bazarr-config`, `navidrome-config`, `cleanuparr-config`, `nextcloud-html-longhorn` — all
`attached`/`healthy`, 2 replicas). Only the CNPG cluster volumes remain on `local-path`
(`apps/immich/postgres.yaml`, `apps/nextcloud/postgres.yaml`, and Vaultwarden/Infisical's) — those
keep the `local-path-provisioner`-on-Talos need this section originally described, for the
unrelated reason that CNPG's own streaming replication already covers node failure (see the
addendum below).

That changes what this section needs to cover. Longhorn ships an [official Talos
guide](https://github.com/siderolabs/extensions) requiring the `iscsi-tools` and
`util-linux-tools` system extensions and a machine-config user volume mount for
`/var/lib/longhorn` — no `extraMount`/mount-propagation dance like `local-path-provisioner`
needed, since Longhorn owns its own directory rather than bind-mounting host paths per PVC.

**The fsync tax that made this worth measuring, not assuming**, gated the deployment itself
(Task 9, 2026-08-13, `fio` on worker-01):

| Class | write IOPS | fdatasync avg | fdatasync p99 |
|---|---|---|---|
| local-path | 2294 | 0.43 ms | 0.73 ms |
| longhorn | 530 | 1.86 ms | 2.93 ms |

About 4× on both write IOPS and fdatasync p99 — inside the "roughly an order of magnitude" bar
the deployment plan set going in. The qualitative half of the same gate ran Lidarr through 792
album refreshes, 76 artist refreshes, and a full RSS sync entirely on Longhorn: **zero**
`database is locked` errors. So the volumes this section worried about porting to Talos are, on
current evidence, fine on replicated block storage — the SQLite-over-network concern that drove
the original `local-path`-everywhere recommendation was real but survivable at this cluster's
scale and load.

Two consequences carried over from the old recommendation, now attached to Longhorn instead:
- The "NO sync-wave annotation" comment no longer applies here — Longhorn's StorageClass binds
  `Immediate`, unlike `local-path`'s `WaitForFirstConsumer`. It still applies to the CNPG volumes
  that stayed on `local-path`.
- The recovery paths written into each PVC manifest still point at the app's own backup on
  `/data/backups/` (NFS) as the second layer, and a Longhorn backup to the (soon to be relocated)
  NFS backup target as the volume-level layer underneath that. Both still need to exist off the
  node being reinstalled during a Talos rebuild.

**Effort: medium.** One new `system/longhorn/` app (already exists) + the two system extensions +
the machine-config volume mount, then zero changes to the eight PVCs themselves (same
StorageClass name, same `existingClaim`).

---

### 4. Cilium — mostly a wash, but every k3s workaround is deleted

`bootstrap/values/cilium.yaml` needs Talos-specific additions (`securityContext` capabilities,
`cgroup: /sys/fs/cgroup` host mount, `k8sServiceHost`/`Port` pointing at the Talos KubePrism
endpoint `localhost:7445` rather than `127.0.0.1:6443`, `cni.exclusive: false` if anything else
writes conflists). Standard, well-documented.

What you *delete* is the interesting part. Three of your hardest-won k3s hacks stop existing:

- **The Cilium CNI startup gate** (`roles/common`, ~30 lines of comment for a 1-line
  `ExecStartPre`). The whole bug is "Cilium's `05-cilium.conflist` persists across reboot while
  `/var/run` is a fresh tmpfs, so kubelet lies about Ready." Talos manages CNI conflists as part
  of its own boot sequence — this specific race does not reproduce. **Verify before deleting**,
  don't assume.
- **The dangling-BPF-backend / duplicate-agent problem.** The root cause is k3s's
  `KillMode=process` leaving the old cilium-agent process alive across `systemctl restart k3s`.
  Talos has no systemd and no `systemctl restart k3s`. The `CiliumAgentDuplicate` alert becomes
  vestigial (keep it — cheap, and a duplicate agent is still fatal if it ever happens another way).
- **`network-online.target` being vacuous.** Talos machine config has first-class static IP
  config. Your memory note *"nodes are DHCP-only while their IPs are hardcoded everywhere"* — the
  API endpoint `192.168.30.129`, the NFS server `192.168.30.194`, the Cilium L2 interface
  pattern — is fixed for free. This is the single biggest quality-of-life win in the migration.

`l2announcements` with `interfacePattern: "^(enp2s0|eno1)$"` — **verify the interface names**
Talos assigns on the G4/G6/G9. Predictable naming should hold, but confirm with `talosctl get
links` on one node before committing.

**Effort: medium, net negative complexity.**

---

### 5. Node-level Ansible → machine config — mostly wins, one real loss

`roles/common` is 400 lines. Here's where each piece lands:

**Deleted outright (Talos does it or the problem doesn't exist):**
- SSH hardening, `fail2ban` — no SSH on Talos at all. Strictly better.
- `ufw` rules (6 of them) — Talos ingress firewall in machine config, or drop entirely since
  the cluster is already on an isolated OPNsense VLAN.
- `chrony` + its `Restart=always` override — Talos has built-in NTP.
- `unattended-upgrades` — replaced by `talosctl upgrade` / system-upgrade-controller.
- `subuid`/`subgid`, containerd snapshotter override, LVM extension — all k3s/Ubuntu artifacts.
- The `network-online.target` override and the Cilium CNI gate (see §4).

**Ports cleanly:**
- `fs.inotify.max_user_instances=1024` / `max_user_watches` → `machine.sysctls`. Keep the
  audit rationale in a comment; the per-UID limit is a kernel property, not an Ubuntu one.
- Node labels/taints → `machine.nodeLabels` / `machine.nodeTaints`.

**Now also ports cleanly, added 2026-08-13 after the Longhorn deployment:** `roles/common`
enables and starts `iscsid` on all three nodes — Longhorn's V1 volumes need `iscsiadm` on the
host to attach. This is real Ansible work (Task 1 of the deployment) that would be **silently
lost** if `roles/common` is deleted as part of a Talos cutover without a replacement. The Talos
equivalent is the `iscsi-tools` and `util-linux-tools` system extensions plus a machine-config
user volume mount for `/var/lib/longhorn` (see §3) — that is the thing that must exist before
`roles/common` goes away, not an afterthought discovered when volumes fail to attach.

The audit's own hard blocker is unaffected by any of this: worker-01 running
`nfs-kernel-server` (§2) still has no Talos equivalent and still waits on the NAS purchase.
Longhorn's own backup target sits on the same NFS server today, so it inherits the same
dependency — it does not change the blocker's shape, just adds one more consumer of it.

**Breaks — the SMART temperature exporter:**

`smart-temp-textfile` (bash + `smartctl` + two systemd units + a udev APM rule) has **no Talos
equivalent**. There is no `smartmontools` extension; `nvme-cli` exists but the 12TB WD is USB,
not NVMe. Specifically you lose:
- `node_smart_temperature_celsius` for the drive running ~4°C from its spec max
- `node_smart_load_cycle_count`, i.e. the only evidence the APM fix is holding
- the udev rule setting `apm,254` — **on Talos the drive goes back to parking its heads ~50×/hour**

`system/monitoring-system/prometheusrule-temperature.yaml`'s disk alerts go permanently empty
(and per your own memory note, "a missing series leaves the alert expression empty" — it will
fail silently, not loudly).

This is the second independent argument for NAS-first: on a NAS the drive's SMART and APM are
the NAS's problem, and the Talos nodes have only NVMe left, which `hwmon` covers for free. Both
`TODO(NAS)` comments in `roles/common` already anticipate deleting this code.

CPU/NVMe temps via node-exporter `hwmon` continue to work — Talos exposes `/sys` normally.

**Effort: low to port, but accept the SMART loss or buy the NAS.**

---

### 6. Workloads — near-zero change

Everything from ArgoCD down is pure Kubernetes and does not care what OS the kubelet runs on:

- ArgoCD, the three stack ApplicationSets, `bootstrap/root` — unchanged.
- cert-manager, sealed-secrets, external-dns, envoy-gateway, VPA, metrics-server, CNPG, Loki,
  Alloy, kube-prometheus-stack, Renovate — unchanged.
- All 20 apps — unchanged, **except** the NFS server IP if you move to a NAS.

Two spot-checks that came back clean:

- **qBittorrent/gluetun** uses `NET_ADMIN` and userspace WireGuard. Talos allows added
  capabilities normally, and `WIREGUARD_IMPLEMENTATION: userspace` means no kernel WireGuard
  module is needed — the same reason it's set for Cilium eBPF compat. The `10.0.0.0/8,
  192.168.0.0/16` firewall bypass and the `10.43.0.10:53` CoreDNS resolver are cluster-CIDR
  facts, unaffected. **Verify `/dev/net/tun` availability** on a Talos node before cutover;
  userspace WG generally doesn't need it, but gluetun's health server assumes `tun0` exists and
  qBittorrent is explicitly bound to that interface in its UI config.
- **Jellyfin** does no hardware transcoding today (no `/dev/dri` anywhere in the repo, CPU limit
  `4`). If you ever want QSV on the G9, Talos has a core-tier `i915` extension — actually
  *easier* than Ubuntu.

**`system/coredns/` deserves attention.** The standalone `coredns-ha` Application exists to
back the pre-existing `kube-dns` Service that k3s created. Talos also ships its own CoreDNS
deployment in `kube-system`. On a fresh Talos cluster you'll have Talos's CoreDNS and your HA
manifests both claiming `kube-dns`. Decide up front: either set
`cluster.coreDNS.disabled: true` in the machine config and keep your manifests, or drop
`system/coredns/` and configure Talos's. Do not let both exist.

Also note Talos's `forwardKubeDNSToHost` behaviour interacts with how host-network pods resolve;
with `cni: none` + Cilium this is generally fine, but it's worth a look given how much of your
DNS pain history is in this repo.

---

### 7. Tooling and repo churn

- `ansible/` shrinks to almost nothing — `cert_manager_issuers` is the only role with no Talos
  equivalent, and it's applying k8s manifests, so it belongs in `config/` or GitOps anyway.
  `nfs_client` disappears (Talos mounts NFS via machine config or just in-pod). `nfs_server`
  and most of `common` are covered above.
- `autoinstall/` (Ubuntu USB) → Talos Image Factory schematic (pinning your extension set) +
  `talosctl apply-config`. Simpler.
- `justfile` recipes: `provision*`, `ping*`, `vault-*`, `lint`, `build-usb` all get replaced by
  a handful of `talosctl` recipes. `bootstrap*` and `seal` are unaffected.
- Ansible Vault (`.vault_pass`, `ansible/vault.yml`) currently holds `vault_k3s_token`. Talos
  secrets live in `secrets.yaml` from `talosctl gen secrets` — **that file is a root CA bundle
  for the cluster and must never be committed**. Plan where it lives (age/sops, or the same
  out-of-band path `.vault_pass` uses).
- Renovate config will need Talos version tracking added; the Image Factory schematic pins
  extension digests that drift with each Talos release.

---

## What you actually gain

Honest accounting, because most of the k3s pain in this repo is *not* solved by Talos:

**Real wins:**
1. Static IPs in declarative config, killing an entire class of boot-order bugs.
2. No SSH, no systemd, no apt — three of your logged incidents (k3s restart duplicating Cilium
   agents, containerd wedge remediated by `systemctl restart k3s`, snapshotter switch bricking
   images) are k3s/Ubuntu-specific and stop existing.
3. Atomic, rollback-able OS upgrades vs `unattended-upgrades` with `Automatic-Reboot "false"`
   (i.e. currently: security patches applied, never rebooted — a quiet liability).
4. Node config becomes reviewable YAML in git, same model as everything else here.

**Not solved by Talos:**
- The NFS single-point-of-failure. Talos makes it *worse*.
- SQLite-over-NFS. Same rules, same local-path exceptions.
- worker-00 density / requestless containers. Scheduler behaviour, not OS.
- The USB drive's thermals and head parking. Talos removes your ability to see or fix them.

**Costs:** no shell for debugging (`talosctl` only — a genuine adjustment given how much of this
repo's history is shell-based forensics on nodes), the SMART observability loss, and a period
where your muscle memory doesn't work.

---

## Recommended plan

**Phase 0 — prerequisite, do this regardless of Talos.**
Move `/mnt/storage` to a NAS. Update the NFS IP in `system/nfs-provisioner/values.yaml`, the 10
app `type: nfs` mounts, and the 2 static PVs. Retire `nfs_server`, the SMART exporter, the udev
APM rule, and the disk half of `prometheusrule-temperature.yaml` — all four already carry
`TODO(NAS)`. This is worth doing on its own merits and removes the Talos blocker as a side effect.

**Phase 1 — prove it on one node.**
Image Factory schematic (`i915` if you want Jellyfin QSV later; skip everything else initially).
Take worker-02 (the G6, least loaded, no media label) out, reinstall as Talos, join it to the
existing k3s cluster — **this does not work**, so instead: build a throwaway single-node Talos
VM or spare box, deploy Cilium + local-path + ArgoCD against it pointed at a branch, and confirm
the Cilium values, the local-path extraMount, and the CoreDNS ownership question. Cheap, and it
answers the three "verify before assuming" items in this audit.

**Phase 2 — cluster rebuild, not rolling migration.**
k3s and Talos control planes don't interoperate. Snapshot every local-path volume to the NAS
(the arrs' own System → Backup, `pg_dump` for both CNPG clusters, Vaultwarden's PVC), then
rebuild all three nodes as Talos and let ArgoCD reconcile from `main`. With the NAS already
holding bulk data and backups, this is a few hours, not a weekend.

**Phase 3 — cleanup.**
Delete `ansible/roles/{common,nfs_server,nfs_client}`, `autoinstall/`, the k3s justfile recipes,
the `CiliumAgentDuplicate` rationale comments that no longer apply, and the CNI-gate lore in
CLAUDE.md. Add a `talos/` directory with machine configs and the Image Factory schematic.

**If you're not buying a NAS: don't migrate.** The container-nfsd path puts fragile machinery
under the one filesystem the whole cluster depends on, and trades a working setup for a novel
failure mode on the node that already has a history of dropping its USB drive.

---

## Verify-before-committing list

Claims in this audit I could not confirm from the repo or docs alone:

1. Whether the Cilium conflist/tmpfs boot race reproduces on Talos (§4) — test on Phase 1 node.
2. Interface names Talos assigns on the ProDesk G4/G6/G9, for `l2announcements.interfacePattern`.
3. `/dev/net/tun` availability and whether gluetun's `tun0` binding works unchanged (§6).
4. Whether any arr needs NFSv3 locking (→ `nfs-utils` extension) or NFSv4 suffices.
5. Talos's CoreDNS vs `system/coredns/` ownership of the `kube-dns` Service (§6).

## Addendum — Rook/Ceph as the storage answer

Rook is the canonical "storage on Talos" answer, and it's the obvious thing to reach for since
it would run the whole storage layer in-cluster and sidestep the NFS-server-on-Talos blocker.
**It does not work on this hardware, and it doesn't solve the blocker anyway.** Measured
2026-08-10:

| node | RAM (total / avail) | NVMe | free on root | spare block devices | NIC |
|---|---|---|---|---|---|
| worker-00 | 15G / 11G | 119G, all in `ubuntu-vg` | 78G | **none** | 1× 1GbE |
| worker-01 | 23G / 16G | 477G, all in `ubuntu-vg` | 410G | 10.9T USB HDD | 1× 1GbE |
| worker-02 | 15G / 9G | 238G, plain ext4 on `nvme0n1p2` — **no LVM** | 198G | **none** | 1× 1GbE |

**1. There are no devices to give it.** Rook/BlueStore consumes raw devices, partitions, or
LVs — directory-backed OSDs were removed with filestore and are not coming back. Every node has
exactly one NVMe, fully consumed by root. worker-02 isn't even on LVM, so carving an OSD there
means repartitioning. The only genuinely spare device in the cluster is the USB HDD, and a
USB-attached OSD is a well-known way to lose data: a bus reset flaps the OSD, and this node
already dropped that drive off the bus once (2026-08-08).

**2. The capacity doesn't fit.** Current `local-path` provisioning is 142Gi across 13 PVCs
(3× 20Gi Immich DB, 3× 10Gi Nextcloud DB, 4× 10Gi arr configs, 10Gi Nextcloud html, 2Gi
Cleanuparr). At 3× replication with one replica per node, usable capacity is bounded by the
*smallest* node's free space — 78G on worker-00, against 142Gi wanted. It doesn't fit. Drop the
CNPG volumes (already replicated at the app layer, see below) and you're at 52Gi, which fits
worker-00's 78G with 26G left for container images on a 119G disk already 32G used. That is not
a margin, that's a countdown.

**3. It cannot hold the thing you'd be migrating for.** The NFS share is 2.7T used of 11T. Ceph
here would top out around 50–80G usable. The media library — the actual reason worker-01 runs an
NFS server, and the actual Talos blocker — is three orders of magnitude out of reach. You'd take
on Ceph's entire operational surface and *still* need the NAS.

**4. The RAM budget isn't there.** mon + mgr + OSD + MDS (CephFS needs one, plus a standby) +
operator + CSI provisioners/plugins is realistically 5–7G per node. worker-00 has 11G available
and worker-02 has 9G — and worker-02 already sits at 58% memory requested. You'd spend roughly
half the cluster's headroom to serve <80G.

**5. 1GbE, one NIC, shared with everything.** No second interface for a Ceph cluster network, so
3× replication write amplification rides the same link as VXLAN pod traffic *and* all NFS
traffic. Worse, the volumes you'd move are the SQLite configs — the ones on `local-path`
specifically because network-attached storage produced 996 "database is locked" errors in a
week. RBD is better behaved than NFS here (block semantics, no network file locking), but
replacing local NVMe with 3-way-replicated 1GbE for a latency-sensitive SQLite workload is
walking back toward the problem, not away from it.

**6. What it would fix is already fixed.** The one real Ceph win is removing `local-path`'s
node-pinning. But every pinned volume already has a durability story that doesn't need
distributed storage:
- CNPG (Immich, Nextcloud) — 3 instances with streaming replication. That *is* the replication.
- arr configs — the app's own System → Backup to `/data/backups/<app>/` on NFS.
- `nextcloud-html` — reconstructible from the container image by design.

Ceph would be re-solving these at ~6G RAM/node and a 1GbE write-amplification tax.

### If you want in-cluster replicated storage anyway

**Longhorn** is the right weight class for this hardware — ~500M/node plus per-volume replica
engines, no raw device requirement (it uses a directory under `/var/lib/longhorn`), and it runs
on Talos with the `iscsi-tools` and `util-linux-tools` extensions. It would fit.

**Deployed 2026-08-13, superseding this addendum's conclusion.** The concern raised here — that
Longhorn shouldn't hold the SQLite configs because of synchronous replication over 1GbE — was
worth measuring rather than assuming, so it gated the actual deployment (Task 9): fdatasync p99
came in at 2.93 ms vs 0.73 ms for `local-path`, about 4×, and Lidarr ran 792 album refreshes plus
a full RSS sync on Longhorn with zero `database is locked` errors. At this cluster's scale and
load the tax is real but survivable, not "you've built `local-path` with extra moving parts." All
eight SQLite/app-tree volumes that were on `local-path` are on Longhorn now, at `replicaCount: 2`
(not 1) — see §3.

**Superseded recommendation:** NAS for bulk, Longhorn for the stateful volumes this section
worried about, `local-path` only for the CNPG cluster volumes whose own streaming replication
already provides durability. No Ceph — the reasoning against it above (RAM, capacity, single
NIC) still holds; it was never Longhorn that this addendum's math ruled out.

## Sources

- [Talos Linux System Extensions catalog](https://github.com/siderolabs/extensions)
- [Talos — Local Storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage)
- [Talos — Local Storage (v1.6 docs)](https://www.talos.dev/v1.6/kubernetes-guides/configuration/local-storage/)
- [Using local-path-provisioner on Talos](https://oneuptime.com/blog/post/2026-03-03-use-local-path-provisioner-on-talos-linux/view)
- [Kubelet extraMounts on Talos](https://oneuptime.com/blog/post/2026-03-03-set-up-kubelet-extra-mounts-in-talos-linux/view)
- [NFS provisioner on Talos](https://unixorn.github.io/post/homelab/talos-nfs-provisioner/)
