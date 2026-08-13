# Longhorn Deployment — Design

Written 2026-08-13. Decides *how* Longhorn is deployed. Whether to deploy it at all is settled in
[`docs/longhorn-evaluation.md`](../../longhorn-evaluation.md); the sizing and Talos sections of that
document are superseded here and are amended as part of the implementation.

**Supersedes** `docs/superpowers/plans/2026-08-10-longhorn-migration.md`, which was written before
the evaluation and disagrees with it on chart version, scope, UI, VPA, backups and pilot app. That
file is rewritten rather than left alongside this one. Its one contribution that survives intact is
the fsync benchmark gate, which nothing here replaces.

## Goal

Replace `local-path` for eight volumes with replicated block storage, so a node failure
stops meaning a hand restore from the newest backup archive. The application sees an unchanged
block device with a real filesystem, so SQLite keeps working — that is the whole reason this is
possible at all.

What it does not do, stated once so it is not rediscovered: it does not make the media stack
survive worker-01, because worker-01 *is* the NFS server until the NAS lands. Longhorn is
front-loaded work whose payoff arrives at step two of `Longhorn → NAS → Talos`.

## Scope

**In (8 volumes, right-sized on migration):**

| Volume | Old claim | Real data | New claim |
|---|---|---|---|
| `sonarr-config` | 10Gi | 19.5 MB | 2Gi |
| `radarr-config` | 10Gi | 4.3 MB | 2Gi |
| `lidarr-config` | 10Gi | 35 MB | 2Gi |
| `prowlarr-config` | 10Gi | 13.5 MB | 2Gi |
| `bazarr-config` | 5Gi | 1.9 MB | 2Gi |
| `navidrome-config` | 10Gi | 10 MB | 2Gi |
| `cleanuparr-config` | 2Gi | 1.5 MB | 2Gi |
| `nextcloud-html` | 10Gi | 885 MB | 3Gi |
| **Total** | **67Gi** | **~1GB** | **17Gi** |

**Out:**

- **Jellyfin** (`jellyfin-config-local`, 20Gi). Its pin is wanted — 12th-gen QuickSync is on
  worker-01 and the PV's node affinity is what enforces it. Last, or never.
- **CNPG cluster volumes** (12 PVCs, 105Gi). Streaming replication across instances already
  provides node-failure durability; replicating again at the block layer doubles write
  amplification to solve a solved problem, and NFS/Longhorn is not a supported CNPG configuration.
  Permanently out.
- **Anything on `nfs`.** Media, backups, Loki, Prometheus. Untouched.
- **Longhorn RWX.** It works by fronting an RWO volume with an NFS-Ganesha pod — a single point of
  failure, and ironic given the direction of travel. RWX stays on the NFS share, then the NAS.
- **The v2 (SPDK) data engine.** Needs hugepages and considerably more RAM. Wrong fit for 16G nodes.

### Why the claim sizes matter

The evaluation sized replica placement off requested size, which is correct — Longhorn
thin-provisions data but its *scheduler* places replicas by request. What it did not account for is
that these are new PVCs, and nothing obliges `sonarr-config` to ask for 10Gi again when it holds
19.5 MB. Longhorn also expands in place, which `local-path` cannot, so under-sizing is now
recoverable rather than permanent.

Right-sizing takes the total from 67Gi to 17Gi, and that single change dissolves the sizing
problem: 17Gi at 2 replicas fits on all three nodes with default overprovisioning and worker-00's
`storageMinimalAvailablePercentage` reserve untouched. **Recreating a volume at its old size is
therefore a correctness error, not a cosmetic one** — do it and worker-00 stops being schedulable
and the exclusion argument returns.

## Chart placement and wiring

Directory: **`system/longhorn-system/`**. The `system` ApplicationSet in
`bootstrap/root/templates/stack.yaml` hardcodes `destination.namespace: {{path.basename}}`, and
Longhorn hardcodes `longhorn-system` in several of its own components. The directory name is the
namespace. Precedent: `system/monitoring-system/`, `system/kube-system/`.

`app.yaml`:

```yaml
chartName: longhorn
chartRepo: https://charts.longhorn.io
chartVersion: 1.11.3
syncWave: "1"
```

**Version 1.11.3, not 1.12.0.** Upstream marks 1.11.3 as the only current *stable* release; 1.12.0
is latest without that designation. Sync wave 1 puts it alongside `nfs-provisioner` and
`metrics-server`, so the CSI driver exists well before apps (stack wave 3) bind PVCs.

`csi.kubeletRootDir: /var/lib/kubelet` is set explicitly. Longhorn's k3s guidance covers this
because the CSI plugin fails in a way that reads like a Longhorn bug when it is wrong.

### Renovate

Nothing in `renovate.json` automerges, so the risk is not an unattended bump — it is a
casually-merged PR for a chart whose upgrades are an ordered procedure with per-release notes. One
packageRule closes that:

```json
{
  "matchManagers": ["custom.regex"],
  "matchFileNames": ["system/longhorn-system/app.yaml"],
  "groupName": "longhorn",
  "automerge": false,
  "dependencyDashboardApproval": true
}
```

No PR opens until it is approved on the dependency dashboard. Same shape as the existing
`nextcloud` rule, plus the approval gate.

### Two ArgoCD consequences worth knowing before the first sync

1. **The UI is read-mostly for settings.** The chart renders `Setting` CRs from `defaultSettings`,
   and the ApplicationSet runs `selfHeal: true`. A setting changed in the UI is reverted within
   minutes. Settings changes go through git. Volume and backup operations are unaffected — those
   CRs are not chart-managed.
2. **`deletingConfirmationFlag` stays `false`.** With `prune: true`, that flag is what stops
   deleting the directory from taking the volumes with it. Set it true only for a deliberate
   teardown.

`ServerSideApply=true` is already on the ApplicationSet, which is what keeps Longhorn's large CRDs
under the client-side-apply annotation limit.

## StorageClass

Chart-generated via `persistence.*` — one file, matching how the `nfs` class comes from its
provisioner's chart. No hand-written StorageClass.

| Setting | Value | Why |
|---|---|---|
| name | `longhorn` | chart default; every doc and KB article matches |
| default class | **`false`, permanently** | `local-path` stays the cluster default. CNPG clusters and the reconstructible-volume case must not land on Longhorn by omission |
| `reclaimPolicy` | `Retain` | matches `nfs`; these are the volumes whose deletion loses a SQLite database |
| `defaultFsType` | `ext4` | Longhorn's default and best-tested path |
| `numberOfReplicas` | `2` | see Node configuration |
| `staleReplicaTimeout` | `2880` (default) | at ~1GB total a full rebuild is seconds; tuning this is noise here |
| `allowVolumeExpansion` | `true` | chart default, and it actually works — this is what makes right-sizing safe |
| `defaultDataLocality` | `best-effort` | keeps a replica on the pod's own node when possible, so reads stay local and only the second replica crosses the wire. This is the mitigation for the fsync tax; do not omit it |

## Node configuration

**All three nodes are storage nodes, `numberOfReplicas: 2`.** This changes the evaluation's
recommendation (worker-00 excluded), and the reason is right-sizing: at 17Gi there is no capacity
argument left. Three storage nodes with two replicas means a degraded volume has somewhere to
rebuild, which two storage nodes do not, and it removes the evaluation's Talos warning entirely —
rebuilding one node leaves two, replicas re-place, no single-replica window to time-box.

`defaultDataPath: /var/lib/longhorn` on the root LV. Free space 2026-08-13: worker-00 69G,
worker-01 396G, worker-02 189G.

**The cost that right-sizing does not remove: `guaranteed-instance-manager-cpu` defaults to 12% of
allocatable CPU, per node.** The engine process runs wherever the volume is *attached*, not only
where replicas live, so worker-00 runs an instance-manager pod regardless of whether it stores
anything — a ~480m CPU **request** on a 4-core node with no hyperthreading and a documented history
of density problems. Excluding worker-00 as a storage node would never have avoided this; it only
avoids replica storage and rebuild I/O.

Set it to **5%** globally (~200m on worker-00, ~600m on the G9/G6). The setting also supports a
per-node override via the node's Instance Manager CPU Request field if worker-00 needs to go lower
still. Range is 0–40; 0 removes the request entirely, which is what created the worker-00 hotspot
in the first place, so not that.

Every other Longhorn component gets an explicit `resources.requests`. A requestless container is
invisible to the scheduler and counts as free capacity — the same note is on
`system/nfs-provisioner/values.yaml`.

## UI

`*.nik-homelab.dev` resolves publicly to `192.168.30.200`, the Cilium LB pool. Public DNS, private
routing: the hostnames are reachable from the LAN and over the Tailscale subnet router, not from the
internet. So the exposure being managed is LAN-level, not internet-level.

Longhorn's dashboard still ships with no authentication and can delete volumes, making it the only
app here with no login. **HTTPRoute plus an Envoy Gateway `SecurityPolicy` with basicAuth**,
credentials from Infisical at `/longhorn-system/longhorn-ui-auth`. Envoy Gateway's basicAuth wants
an htpasswd-format secret; the exact key layout is confirmed against the v1.8 API at implementation
time rather than guessed.

The route carries the standard Homepage annotations, group `Infrastructure`. `longhornUI.replicas:
1` — no HA for a dashboard.

## Backup target

`defaultSettings.backupTarget: nfs://192.168.30.194:/mnt/storage/longhorn-backups`. No credential
secret for NFS. Repointed at the NAS when it lands — one setting, and it is the only coupling
between the two projects.

One `RecurringJob` in the `default` group: **daily backup at 04:30, `retain: 7`.** 04:30 is after
the 03:30/03:45 database dumps and the apps' own backups, so each Longhorn backup captures fresh
archives. No separate snapshot job — a backup takes a snapshot on its way.

This reverses the Aug-10 plan's decision to leave Longhorn backups out of scope, so its argument
gets answered rather than ignored. That argument was: "a second backup system that produces volume
snapshots the app cannot restore from is not an improvement." It holds for the arrs, which back
themselves up in a format their own restore flow accepts. It does not hold for **Navidrome and
`nextcloud-html`, which have no app-level backup at all** — for those two this is the only backup
that exists. And post-NAS it becomes the only off-host copy of any of it.

Snapshots get no separate schedule. A backup takes a snapshot on its way, and Longhorn snapshots
live on the volume's own replicas — a snapshot-only schedule would be the one form of protection a
node failure takes with it. Longhorn's filesystem-freeze-during-snapshot setting narrows the
consistency gap (filesystem-consistent rather than crash-consistent) but does not close it, which
is the next paragraph's point.

**The per-app backups stay.** Longhorn's backups are volume-level and crash-consistent; the arrs'
System → Backup understands how to quiesce its own database and produces an archive its own restore
flow accepts. `apps/cleanuparr/backup-cronjob.yaml` still has to exist afterwards for the same
reason. The app archives live inside the volumes, so they ride along in the Longhorn backup — that
duplication is free.

Stated plainly: pre-NAS the backup target is the USB disk on worker-01, the same host as most
replicas. It is a second disk, not a second host. The NAS is what makes this a real backup.

## Migration procedure

**Two-stage pilot.** The evaluation's smallest-first ordering and the Aug-10 plan's
representative-first ordering are both right about different things, so both happen:

1. **Cleanuparr is the mechanical rehearsal** — 1.5 MB of unconfigured settings on worker-00, the
   least costly thing in the cluster to get wrong. It proves the procedure: PVC rename, copy Job,
   `existingClaim` swap, and Longhorn's volume-ownership behaviour against the `fsGroup` that
   `apps/cleanuparr/values.yaml` sets because `local-path` creates the volume root-owned.
2. **Lidarr is the measurement pilot and carries the go/no-go gate.** Cleanuparr cannot measure the
   fsync tax — near-zero write traffic, and it runs on worker-00 rather than worker-01 where the
   other seven live. Migrating three volumes before learning whether the tax is acceptable would
   mean three rollbacks if it isn't.

Then the rest, one per merge so a problem is attributable, ending with Sonarr — the busiest writer
and the one with the 996-lock-error history. If the benchmark missed a latency problem, Sonarr finds
it.

**Mechanism: a copy Job, with a fresh app-level backup taken first purely as the rollback.** One
uniform procedure for all eight, which matters because Navidrome, Cleanuparr and `nextcloud-html`
have no restore flow to use — the alternative means maintaining two procedures. Per app: take the
backup, scale to zero in git, run a Job mounting both PVCs that copies `/config`, swap
`existingClaim`, scale back up.

Two constraints on that Job. It mounts an RWO `local-path` PVC whose PV has node affinity, so it
must be **pinned to that node** — worker-01 for seven, worker-00 for Cleanuparr. And the app must be
at zero replicas before it runs; copying a live SQLite database is how you get a corrupt one.

**The old `local-path` PVCs stay in git for two weeks**, matching the `apps/vaultwarden/data-pvc.yaml`
precedent rather than the Aug-10 plan's 24 hours. They have to stay in git regardless — `prune: true`
would otherwise delete them the moment the manifest disappears. The `Retain` policy means even then
the PV survives as `Released`, so rollback is two-layer, but only the in-git PVC makes it a revert
rather than a manual reclaim.

## Monitoring

`ServiceMonitor` labelled `release: monitoring-system` (Prometheus's selector). Use the chart's
`metrics.serviceMonitor` support if present in 1.11.3; otherwise a hand-written manifest against
`longhorn-backend:9500`. Metric names are read off `/metrics` before the rules are written.

`prometheusrule-longhorn.yaml`, in the style of the existing `prometheusrule-*.yaml` files —
comments carrying the *why* and the diagnostic next step:

- **`LonghornVolumeDegraded`** — warning, `for: 30m`. At 2 replicas this is the only warning before
  faulted, and it is the reason the ServiceMonitor exists.
- **`LonghornVolumeFaulted`** — critical, `for: 5m`. The volume is down and the app is already broken.
- **`LonghornNodeStorageFull`** — warning, >80%. Longhorn filling a root filesystem takes k3s with it.

**Backup alerting comes for free, with one caveat.** Longhorn materialises each recurring job as a
Kubernetes CronJob in `longhorn-system`, so the existing generic `CronJobNotSucceeding`,
`CronJobOverdue` and `CronJobJobFailed` rules already cover them. `BackupCronJobMissing`'s
`.+-db-backup` regex does not match them and is deliberately left alone — a per-volume expected
count would need editing on every migration, and `LonghornVolumeDegraded` covers the same ground.

The caveat: a detached volume's CronJob stops succeeding, and the migration scales apps to zero. Expect
those two staleness rules to fire during each migration window. Do not pre-emptively silence
`longhorn-system`; if the noise outlives the migration, that is when it earns an exclusion.

## VPA

**None.** This is a deliberate exception to the every-app-gets-a-VPA convention:

- `instance-manager` pods are created by `longhorn-manager`, not by a controller a VPA can target.
- Restarting one breaks every volume attached on that node, which makes `updateMode: Recreate`
  actively hostile — the same objection applies to the DaemonSets through a different door.

`system/` already has this precedent: `cilium`, `coredns`, `envoy-gateway`, `nfs-provisioner`,
`node-feature-discovery` and `intel-gpu-plugin` carry no `vpa.yaml`. If sizing data is wanted later,
an `updateMode: "Off"` VPA on `longhorn-ui` and `longhorn-manager` is harmless — a want, not a need.

## Host prerequisite

`open-iscsi`, `nfs-common` and `cryptsetup` are installed on all three nodes; `iscsid` is
`disabled` and `inactive` everywhere, and `iscsi_tcp` is not loaded. `ansible/roles/common`
installs the package and never enables the service. Longhorn's v1 engine attaches over iSCSI to
localhost, so this is a hard blocker with a symptom (attach timeout) that reads like a Longhorn bug.

Fix in `roles/common`: `iscsi_tcp` in `/etc/modules-load.d/` for reboot persistence, `modprobe` for
the running kernel, and `iscsid` enabled and started. Ubuntu-only — on Talos the same requirement is
met by the `iscsi-tools` and `util-linux-tools` system extensions, which is recorded in the Talos
audit so the replacement is not lost when `roles/common` goes away.

## The one open question: the fsync tax

Every SQLite commit becomes a synchronous write to two replicas, one of them over 1GbE that also
carries VXLAN and all NFS traffic. These databases are small and quiet, so this should be
invisible — but the arrs are exactly the workload that produced 996 `database is locked` errors the
last time storage was slower than expected.

This is measured, not argued: `fio` with `--fdatasync=1` against both classes on the same node, plus
one full cycle of real Lidarr activity (library refresh, RSS sync, import) watched for lock errors
and queue stalls. `best-effort` data locality is the mitigation; the benchmark is the check that it
worked.

**A bad result is a legitimate outcome.** If it fails, the pilot reverts to `local-path`, the
numbers go into the Talos audit, and the migration stops with all eight volumes still pinned — which
costs a documented ~30-minute manual recovery on an event that has not yet happened. Longhorn stays
installed or is removed; either is fine.

## The other open question: Cilium and iSCSI-to-localhost

Longhorn's v1 engine attaches volumes over iSCSI to localhost, and `bootstrap/values/cilium.yaml`
runs `kubeProxyReplacement: true` with `socketLB.hostNamespaceOnly: false`. The Aug-10 plan found no
documented incompatibility and could not confirm compatibility either. That is still where it
stands.

Prove it with a throwaway 1Gi PVC and a pod that writes and reads a file — attach, write, read,
detach, delete — **before any real data exists.** It is the cheapest test in the plan and the second
most valuable after the fsync benchmark.

If attach hangs, `socketLB.hostNamespaceOnly: true` is the thing to try, but rolling the Cilium
agent DaemonSet is how two agents end up writing the BPF LB maps at once (see the comment at the top
of `bootstrap/values/cilium.yaml`, and `node_cilium_dangling_bpf_backends`). That happens in a
deliberate window, never as a side effect of debugging something else.

## Verify before writing manifests

These are asserted in this document but not confirmed. The first two change the design if wrong; the
rest are check-at-implementation, and each one gets an explicit step in the plan.

1. **Envoy Gateway v1.8 `SecurityPolicy` basicAuth** exists and what secret format it takes. If it
   does not, the UI decision changes shape — fallback is a Tailscale-only Service, then port-forward.
2. **Longhorn 1.11.3 values key names**, particularly `guaranteedInstanceManagerCpu` casing (docs
   show `Cpu`; the setting is `guaranteed-instance-manager-cpu`). **A wrong key is silently ignored**,
   so verification is reading the rendered `Setting` CR for the value 5 — not a `helm template` that
   merely doesn't error. Same class: `persistence.defaultClassReplicaCount` and
   `defaultSettings.defaultReplicaCount` are both real and mean different things; both get set.
3. **Whether the instance-manager pod is created on a node with no attached volume.** The engine
   process certainly runs where a volume attaches; eager per-node creation is what is unconfirmed.
   Does not change the 5% recommendation either way.
4. **`metrics.serviceMonitor` support** in the chart, versus a hand-written manifest.
5. **Metric names** for the three alerts, read off `/metrics`.
6. **Lidarr's real usage.** The evaluation says 35 MB, the Aug-10 plan says ~240 MB — likely
   MediaCover. Neither threatens a 2Gi claim, but one of the two is wrong and this document
   propagated the smaller figure.
7. **`deletingConfirmationFlag` defaults to `false`** — the safety net the ArgoCD section relies on.
8. **`csi.kubeletRootDir`** actual value on these nodes.
9. **The filesystem-freeze-for-snapshot setting's** key name in 1.11.3, if it is used at all.

## Risks accepted

1. **A new failure domain under eight apps.** These volumes gain a dependency on the Longhorn
   control plane, the CSI driver, and iSCSI attach/detach. The pin being removed is itself a form of
   simplicity.
2. **Per-node overhead**, mitigated to ~5% CPU but not eliminated. worker-00 feels it first.
3. **Upgrade discipline.** Treated like Cilium, not like an app — hence the dependency-dashboard gate.
4. **`nextcloud-html` is 15k small files**, the least favourable shape for replicated block storage.
   It is in scope because Longhorn beats both of its current alternatives, and because losing it
   costs a rebuild rather than data — which also makes it a safe thing to be wrong about.
5. **Cleanuparr's `fsGroup`.** `apps/cleanuparr/values.yaml` sets it because `local-path` creates
   the volume root-owned. Longhorn's ownership behaviour must be verified per-app, or the container
   cannot write `/config`.

## Documentation to amend at the end

- **`CLAUDE.md`** Storage section — a **rewrite, not an amendment.** Case (1), SQLite databases,
  becomes `longhorn`. Case (3), reconstructible volumes, has exactly one example — `nextcloud-html` —
  and it moves, leaving the case with nothing in it. What remains is "CNPG clusters stay
  `local-path`, everything else `longhorn`," which is a different rule with a different shape. Budget
  for that rather than expecting a three-line edit. The `local-path` recovery paths written into each
  `config-pvc.yaml` also stop being true.
- **`docs/longhorn-evaluation.md`** — four places, all currently wrong in-repo: the Sizing section
  (lines 51-72) and the Talos replica-count warning (133-140), both superseded by right-sizing and
  three storage nodes; risk #2's claim that excluding worker-00 reduces per-node overhead; and step
  2's "needs a VPA". These are amended in the same branch as the plan, not deferred.
- **`docs/talos-migration-audit.md`** §3 — replace the `local-path`-on-Talos recommendation, and
  fold the `iscsi-tools` extension note into §5.
