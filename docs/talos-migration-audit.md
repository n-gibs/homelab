# Talos Linux Migration Audit — homelab (k3s → Talos)

Date: 2026-08-10. Audited against the repo at commit `62e4a30`.

> **Superseded in part.** Longhorn was deployed 2026-08-13 (see
> `docs/archive/superpowers/specs/2026-08-13-longhorn-deployment-design.md` and
> `docs/archive/superpowers/plans/2026-08-13-longhorn-deployment.md`), replacing the eight `local-path`
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
3 control-plane nodes that also schedule workloads, real etcd instead of k3s's
embedded one.

The k3s server flags map cleanly and most just vanish:

| k3s flag | Talos |
|---|---|
| `--disable traefik` | n/a — Talos ships none |
| `--disable servicelb` | n/a |
| `--disable metrics-server` | n/a — you already deploy your own (`system/metrics-server`) |
| `--flannel-backend=none` | no Flannel (`cluster.network.cni.name: none` in the v1alpha1 schema) |
| `--disable-network-policy` | implied by `cni: none` |
| `--disable-kube-proxy` | `KubeProxyConfig` with `enabled: false`; Cilium runs `kubeProxyReplacement: true` |
| `--write-kubeconfig-mode=644` | n/a — `talosctl kubeconfig` |
| `--resolv-conf /run/systemd/resolve/resolv.conf` | n/a — no systemd-resolved; Talos manages resolv.conf |
| `--node-label homelab.io/media=true` | `KubeNodeConfig` `labels` |
| control-plane taint on worker-00 | `KubeNodeConfig` `taints` |

Talos v1.14 deprecates most of the v1alpha1 fields this table and the layout doc used to cite
(`cluster.network`, `cluster.proxy`, `machine.nodeLabels`, `machine.network`, `machine.kubelet`,
`machine.install`) in favour of multi-document configs. Pin the Talos version, generate with
`talosctl gen config --talos-version` for it, and write the patches in that schema; a v1alpha1
field and its replacement document in the same config fail validation.

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
- Node labels/taints → `KubeNodeConfig` `labels` / `taints`.

**New on Talos, never built for k3s: UPS shutdown.** The NAS is the NUT primary for the
CP1500PFCLCD (#187). Each Talos node needs, from its first boot:
- the `nut-client` extension, configured by an `ExtensionServiceConfig` holding `upsmon.conf`:
  `MONITOR <ups>@192.168.30.144 1 <user> <pass> secondary`, `SHUTDOWNCMD "/sbin/poweroff"`, and
  `SHUTDOWNEXIT no`, which keeps the node logged in to the NAS until it has drained, so the NAS
  doesn't cut UPS power under it;
- a patch on the generated `KubeletConfig` document setting, under `config:`,
  `shutdownGracePeriodByPodPriority`: priority 0 → 180s, 1000000000 → 60s, 2000000000 → 30s.
  `longhorn-critical` (1e9) sits below kubelet's critical cut-off, so the default two-phase mode
  would stop Longhorn alongside the apps still using it. The patch must also set
  `shutdownGracePeriod` and `shutdownGracePeriodCriticalPods` to `0s`: Talos defaults them to
  30s/10s, and kubelet won't start with either beside a by-priority list;
- BIOS set to power on after AC loss, since the NAS powers the UPS off at the end.

Design and reasoning: `docs/superpowers/specs/2026-11-23-ups-graceful-shutdown-design.md`.

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

Two spot-checks:

- **qBittorrent/gluetun** uses `NET_ADMIN` and userspace WireGuard. Pod Security `baseline`,
  Talos's default, rejects `NET_ADMIN`, so its namespace needs the `privileged` label (see the
  layout doc). `WIREGUARD_IMPLEMENTATION: userspace` means no kernel WireGuard module is
  needed. The `10.43.0.10:53` CoreDNS resolver holds only if Talos's `serviceSubnets` is pinned
  to `10.43.0.0/16`; Talos defaults to `10.96.0.0/12`. **Verify `/dev/net/tun` availability** on a Talos node before cutover;
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

**The extension set**, confirmed against the catalog on 2026-09-11:

| Extension | Tier | Why |
|---|---|---|
| `siderolabs/iscsi-tools` | core | Longhorn V1 volumes need `iscsiadm` on the host. This is what replaces `roles/common`'s `iscsid` enable (§4). |
| `siderolabs/util-linux-tools` | contrib | Longhorn's other documented requirement. Contrib tier, but it is what the official Longhorn-on-Talos guide names. |
| `siderolabs/i915` | core | `/dev/dri` for QSV on the G9s (§6). Bake it in now even though nothing transcodes today: the set is compiled into the boot asset, so adding one later costs an image rebuild and a node upgrade. |
| `siderolabs/intel-ucode` | core | Microcode, which Ubuntu supplies today for free. |
| `siderolabs/nut-client` | contrib | `upsmon` as a NUT secondary of the NAS, so a power cut shuts the node down cleanly (§5). Added 2026-11-23; the k3s nodes never got a NUT client. |

Deliberately excluded: `nfsd` (the NAS owns the export, §2), `nfs-utils` (TrueNAS exports
NFSv4-only and the v4 client is in-kernel), `nvme-cli` (the 12TB is USB, §5), `mdadm` (now a
deprecated no-op) and `tailscale` (it runs in-cluster as a subnet router, not as a host service).

No NIC firmware extension is needed on the G9. worker-01 reports `Intel Ethernet Connection (17)
I219-LM [8086:1a1c]` driving `eno1` on in-tree `e1000e`. Re-check with `lspci -nn | grep -i
ethernet` on the new G9 before building the schematic, since HP ships variants inside one model
line (the two G9s already differ on RAM).

Pin digests, never tags:
`crane export ghcr.io/siderolabs/extensions:v<version> | tar x -O image-digests | grep <name>`.
- `justfile` recipes: `provision*`, `ping*`, `vault-*`, `lint`, `build-usb` all get replaced by
  a handful of `talosctl` recipes. `bootstrap*` and `seal` are unaffected.
- Ansible Vault (`.vault_pass`, `ansible/group_vars/all/vault.yml`) currently holds `vault_k3s_token`. Talos
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

**Phase 0 — prerequisite, do this regardless of Talos. In progress.**
Move `/mnt/storage` to a NAS. Update the NFS IP in `system/nfs-provisioner/values.yaml`, the 10
app `type: nfs` mounts, and the 2 static PVs. Retire `nfs_server`, the SMART exporter, the udev
APM rule, and the disk half of `prometheusrule-temperature.yaml` — all four already carry
`TODO(NAS)`. This is worth doing on its own merits and removes the Talos blocker as a side effect.

Hardware is arriving and the build is specified in `docs/nas-migration-checklist.md`: CWWK N305,
TrueNAS SCALE, pool named `storage` so the export path stays `/mnt/storage`. Two items there
feed back into this audit — the export is **NFSv4-only**, which settles verify-item #4 (no
`nfs-utils` extension in the schematic) provided nothing turns out to need v3 locking; and
TrueNAS must be alerting on its own disks before `smart-temp-textfile` is deleted, or §5's
"NAS-first fixes the SMART loss" is only true on paper.

**Phases 1 and 2 — superseded by the fourth-node plan below.** They assumed three boxes and a
throwaway test target. A second G9 removes both constraints.

### The fourth-node plan (2026-09-09)

A second G9 (i5-12500T) is arriving to replace worker-00, the G4. It ships with one 8GB stick
and no drive; it gets a 512GB NVMe and 32GB of new DDR4. The spare 8GB stick goes into the G6's
empty slot before it joins Talos in step 5, taking it from 16GB to 24GB. That is a
better migration than Phases 1–2 above: the new box is Phase 1's test target *and* the first
node of the real cluster, so the bake period is free and there is a rollback the whole way.

**It is not a join.** Talos control-plane nodes run their own etcd behind Talos-generated PKI;
there is no path that adds one to k3s's embedded etcd. The new G9 starts a *second cluster*,
the two run side by side against the same NAS, and apps cut over one at a time. (A Talos
*worker* can technically join k3s with its CA and a bootstrap token — don't. It ends with the
new cluster's identity rooted in the CA of the thing being deleted.)

**Four resources both clusters will claim.** All four are silent failures, not errors:

| Resource | Collision | Fix |
|---|---|---|
| `system/external-dns` | `txtOwnerId: homelab` with `policy: sync` in both clusters. Each treats the other's records as its own orphans and deletes them. | Give the Talos cluster a distinct `txtOwnerId` before it ever syncs. |
| Cilium L2 VIP | Both would ARP for `192.168.30.200`. | The pool is `192.168.30.200/29`, so `.201`–`.207` are free. Allocate a second VIP; collapse to `.200` at cutover. |
| `platform/tailscale` Connector | Both advertise `192.168.30.0/24`. | Don't deploy it on Talos until cutover. |
| cert-manager | Two ACME accounts, same wildcard. Let's Encrypt allows 5 duplicate certificates per week. | Prod issuer on Talos with an added `*.talos.nik-homelab.dev` name, so the certificate isn't a duplicate. Staging would serve moved apps an untrusted certificate. |

`docs/talos-two-cluster-layout.md` supersedes this table. It lists the collisions found since,
and puts the Talos VIP at `.208`, outside the k3s pool rather than inside it.

**The API endpoint is on the node being retired.** `api_endpoint: 192.168.30.129` in
`ansible/group_vars/k3s_cluster.yml` is worker-00's own address, not a VIP. Pulling the G4
strands nothing: a k3s server whose etcd is already initialized ignores an unreachable join URL
(`pkg/cluster/bootstrap.go`, v1.36.4+k3s1). Don't run Ansible to repoint it, because k3s-ansible
restarts every server. Point the control node's kubeconfig at worker-01 (`192.168.30.194`) by
hand and drop worker-00 from `ansible/inventory.yml`.

Give the Talos cluster a control-plane VIP from the start (a `Layer2VIPConfig` document)
so this doesn't recur. Pick the address before step 2: it becomes the cluster endpoint in the
generated config and certificates. It must sit outside the DHCP range and both LB pools.

**Don't migrate apps onto a one-node cluster.** Longhorn at 2 replicas sits Degraded with one
node, and every CNPG cluster runs `instances: 3` with `podAntiAffinityType: required`, so with
fewer than three nodes the extra instances sit Pending. Order:

1. Take worker-00 (G4) out of k3s. Pause kured and cordon the G4. Set `instances: 2` in each
   CNPG cluster's `postgres.yaml` (Infisical's `postgres.k3s.yaml`). Scale-down removes the
   highest-serial replica wherever it runs, so for any instance still on the G4, switch the
   primary away if needed and remove it with `kubectl cnpg destroy <cluster> <instance>`; the
   cordon makes CNPG rebuild it on the other node. Then drain the G4 and delete its node object,
   which removes its etcd member.
2. Create the Talos cluster on the new G9 and the G4 together: bootstrap etcd on the G9
   (control plane #1), then apply the G4's config (control plane #2). Prerequisites: the
   helmfile `talos` environment that pins the Talos kube context, and HOM-18's Talos Cilium
   values. Today's recipes take no environment and apply k3s's Cilium values to whatever
   context is current, so they gain one (`helmfile -e talos`) first. Run only the Cilium and
   ArgoCD releases. The root release waits until the HOM-19 selector change is merged and its
   no-op check has passed on k3s; before that, the root ApplicationSets have no selector and
   Talos would sync every app. Platform only, no apps. This answers verify-items 1 and 5 on
   real hardware, and verify-item 2 for the G9's and G4's NICs.
3. Migrate apps k3s → Talos, biggest first. Per app: scale to zero on k3s, restore from its own
   backup on the NAS, verify, move on. CNPG clusters start on Talos at `instances: 2`.
4. Move the Infisical server, then Tailscale, Renovate and blackbox-exporter, to Talos. The
   Infisical move follows the layout doc's own procedure for it. k3s now runs nothing that
   matters, and the subnet router and Talos's secret source both survive the next step.
5. Remove worker-02 (G6) from k3s, fit the spare 8GB stick, run one memtest pass, and install
   it as Talos control plane #3 from its own schematic, which carries its NVMe kernel argument.
   Wipe worker-01 (G9) next → control plane #4. Raise the Talos CNPG clusters back to
   `instances: 3`.
6. Cordon the G4, `kubectl cnpg destroy` any CNPG instance on it, evict its Longhorn replicas,
   drain it, and `talosctl reset` it, which takes its etcd member out with it. The reset leaves
   the Node object, so `kubectl delete node` it. Talos is back at three members; retire the
   box. HOM-24 then collapses the overlays.

Starting Talos on two nodes means Longhorn and CNPG have a second node from the first sync,
with no single-node stage. The cost: k3s is already at two members while Talos is being shaken
down, and rolling back a failed Talos install means reinstalling Ubuntu and k3s on the G4.

**Every Talos node is a control plane that also runs workloads.** One base machine config,
which leaves control planes schedulable, serves all of them, plus a small patch per node for its
hostname, static IP and labels. Kernel arguments live in the Image Factory schematic, so the G6
gets its own. The layout doc's Machine config section lists the documents. Talos sets the role at
install and can't promote a worker later, so no node ever needs a second wipe.

**Take the G4 out of k3s first, retire it last.** Leaving k3s, it is the cheapest node to lose:
k3s keeps worker-01 and worker-02, which are both ingress announcers and hold the only working
iGPU, and drops the overload hotspot. RAM splits 40GB on k3s (24 + 16) against 48GB on Talos
(32 + 16) during step 3, and the G4 gives Longhorn and CNPG a second node.

Constraints with no way around them at four boxes:

- **Both clusters run two etcd members until step 5**: k3s from step 1, Talos from its
  creation in step 2. A 2-member etcd tolerates zero
  failures and has more ways to lose quorum than a 1-member one, which makes this the worst
  stretch of the migration. Keep it short and don't reboot or upgrade anything optional. On
  k3s that means kured stays paused and `just provision` doesn't run: either restarts a server.
  Take a `talosctl etcd snapshot` before each app move; losing either Talos node for good means
  recovering with `talosctl bootstrap --recover-from`.
- In step 5, drain the G6 and delete its node object while both k3s servers are up, so k3s
  removes its etcd member; never power it off first. Talos goes 2 → 3 → 4 → 3 members from
  there; four tolerates one failure, the same as three.
- The G6 needs `nvme_core.default_ps_max_latency_us=0`, as `ansible/host_vars/worker-02.yml`
  sets today. Put it in a G6-only schematic's `customization.extraKernelArgs`:
  `machine.install.extraKernelArgs` is deprecated and only applies under legacy GRUB boot
  (`cmd/installer/pkg/install/install.go`, v1.14.7), so a UEFI install ignores it. Confirm with
  `talosctl read /proc/cmdline` before the G6 takes an etcd member. Without the argument the
  drive stops answering after boot and takes the member and its Longhorn replicas with it.
- The G4's 128GB NVMe holds one replica of every Longhorn volume while Talos has two nodes.
  The volumes declared on `main` total about 43Gi, beside the CNPG `local-path` volumes and the
  image cache. Check `kubectl -n longhorn-system get volumes` against the space Talos leaves
  before step 2.

**What the new node changes elsewhere in this audit:**

- §1's control-plane taint inconsistency dies with worker-00, as does the i915-blacklisted node
  and the requestless-container density hotspot. Cluster RAM goes 16/24/16 → 32/24/24, with a
  12th-gen replacing an 8th-gen.
- §6's Jellyfin note assumes one modern iGPU. Two 12th-gen G9s means `homelab.io/media` is no
  longer the only expression of "the better encoder" — revisit which node it points at.
**Node labels need settling before the new G9 is installed**

Two labels, and after worker-00 retires neither set is obviously right. Decide both explicitly —
each fails silently when wrong.

`homelab.io/quicksync=true` (replacing `homelab.io/media`, see the NAS checklist) goes on the
two G9s and is consumed by Jellyfin alone.

`homelab.io/ingress=true` is the harder one, because it is not a label but a **triple that must
agree**:

1. the set of nodes carrying the label,
2. `envoyDeployment.replicas` in `system/envoy-gateway/envoyproxy.yaml`,
3. the `nodeSelector` there and the one in `cilium-l2-announce.yaml`, which must be identical.

`topologySpreadConstraints` with `maxSkew: 1` and `DoNotSchedule` spreads the proxies evenly
across candidate nodes, so keep `replicas` at or above the number of labelled nodes; extra
replicas double up harmlessly. A labelled node with no proxy is less dangerous than this audit
first assumed: Cilium's L2 announcer skips an `externalTrafficPolicy: Local` service on a node
with no live local backend (`hasLocalBackends` in `pkg/l2announcer/l2announcer.go`, v1.20.5,
the version on `main` and live on k3s). Talos's Cilium values (HOM-18) should pin the same
release. While the sets differ, `envoyproxy.yaml` splits
into `.k3s`/`.talos` halves; on Talos only the new G9 carries the label until step 5.

Options once worker-00 is gone:

| Set | replicas | Trade |
|---|---|---|
| All three nodes | 3 | Widest failover, every node can announce. One more Envoy pod. |
| Both G9s | 2 | Ingress set becomes identical to quicksync; the G6 can never serve ingress. |
| worker-01 + worker-02 (today's set) | 2 | The new G9 gets no ingress role for no particular reason. |

All three nodes is the default worth taking. The original reason to keep the set at two — the
l2-announce comment's "not `homelab.io/media`, that would make worker-02 a scheduling target for
apps whose data is on worker-01's disk" — dies with the NAS. The documented rolling-update outage
assumed Cilium moves the L2 lease only on node failure; if the local-backend check above holds,
re-test it on Talos rather than carrying the note over.

Two Talos details that touch this:

- Talos applies node labels from the machine config on **every boot**, unlike k3s's `--node-label`, which only applies
  at kubelet registration. The CLAUDE.md warning about labelling an existing node by hand goes
  away — this is a small, real win.
- `cilium-l2-announce.yaml` matches interfaces `^enp2s0$` and `^eno1$`. Confirm what Talos names
  the NICs on the new G9 and the G6 (verify-item #2) before relying on ingress there; a
  non-matching interface means the node silently never announces.

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
   **Partly settled 2026-09-11:** worker-01 (G9) presents its single I219-LM as `eno1` under
   Ubuntu, alongside an unused `wlp0s20f3`. Talos uses the same predictable-naming scheme, so
   `eno1` is the expectation rather than the confirmation. Read it off the node in step 2.
3. `/dev/net/tun` availability and whether gluetun's `tun0` binding works unchanged (§6).
4. Whether any arr needs NFSv3 locking (→ `nfs-utils` extension) or NFSv4 suffices.
5. Talos's CoreDNS vs `system/coredns/` ownership of the `kube-dns` Service (§6).
6. UPS shutdown ordering (§5). Does `/sbin/poweroff` from `upsmon` run kubelet's graceful
   shutdown, or Talos's own cordon-and-drain? And when does Talos stop `ext-nut-client`? Its
   service `depends` on `cri`, so it may stop before pods finish, which logs it out and lets the
   NAS cut power early. Test on a node in step 2: `talosctl shutdown`, and watch `upsc -c` on the
   NAS keep the client listed until the node is drained.

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
