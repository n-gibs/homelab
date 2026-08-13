# Longhorn Evaluation

Whether to deploy Longhorn to unpin the `local-path` volumes. Written 2026-08-13, against
k3s v1.36.3 and the current contents of `apps/`.

## The question

Nine PVCs use `local-path`, excluding the CloudNativePG clusters. Each one binds its pod to a
single node through the PV's node affinity, so the app cannot reschedule if that node dies.
Longhorn replaces `local-path` with replicated block storage, which removes the pin without
changing anything the application sees — it is still a block device with a real filesystem, so
SQLite works normally.

Two cheaper options were evaluated first and mostly rejected:

- **Move the apps to Postgres.** Works for Cleanuparr (supported `migrate-to-postgres`
  subcommand — see `docs/superpowers/plans/2026-08-13-cleanuparr-postgres.md`). Rejected for the
  arrs: Servarr documents SQLite migration as unsupported, the procedure is pgloader plus 37
  hand-written `setval()` calls per app, Postgres 18 is explicitly outside the documented path,
  and — decisively — *"Postgres databases are NOT backed up by Sonarr."* Migrating throws away
  the built-in backup that CLAUDE.md's storage rule relies on for durability. Jellyfin and
  Navidrome cannot use Postgres at all.
- **Leave everything pinned.** Costs nothing today. See "Do nothing" below — it is a more
  serious option than it sounds.

## What is actually pinned

| Volume | Requested | Real data | Can leave SQLite? |
|---|---|---|---|
| `sonarr-config-local` | 10Gi | 19.5 MB | Postgres, unsupported migration |
| `radarr-config-local` | 10Gi | 4.3 MB | Postgres, unsupported migration |
| `lidarr-config-local` | 10Gi | 35 MB | Postgres, unsupported migration |
| `prowlarr-config-local` | 10Gi | 13.5 MB | Postgres, unsupported migration |
| `bazarr-config-local` | 5Gi | 1.9 MB | Postgres, but see Bazarr issues #2161/#2585 |
| `jellyfin-config-local` | 20Gi | 15.5 MB | **No** — experimental plugin only |
| `navidrome-config-local` | 10Gi | 10 MB | **No** — SQLite-only upstream |
| `cleanuparr-config-local` | 2Gi | 1.5 MB | **Yes, supported** — separate plan exists |
| `nextcloud-html` | 10Gi | ~15k files | n/a — not a database, it is the PHP app tree |
| **Total** | **87Gi** | | |

The CNPG cluster volumes (`immich-database-*`, `nextcloud-database-*`, `infisical-database-*`,
`vaultwarden-database-*` — 12 PVCs, 105Gi) **stay on `local-path` and must not move to
Longhorn.** Postgres streaming replication already provides the node-failure durability;
replicating again at the block layer doubles write amplification to solve a solved problem.

Note the gap between requested and real: 87Gi of claims against well under 1Gi of actual data.
Longhorn thin-provisions, so consumption tracks real usage, but its *scheduler* places replicas
using the requested size. Sizing below uses the requested figures because that is what
constrains placement.

## Sizing

Free space on each node's root filesystem, which is where `/var/lib/longhorn` would live:

| Node | Disk | Free | Notes |
|---|---|---|---|
| worker-00 | 115G | 69G | G4, smallest node, history of density problems |
| worker-01 | 466G | 396G | G9, media node |
| worker-02 | 233G | 189G | G6 |

At the default 3 replicas, every node holds a full copy — 87Gi on worker-00, which also reserves
~30% of the disk before it will schedule anything. It does not fit.

**Recommended: `replicaCount: 2`, with worker-00 excluded as a storage node.** Replicas land on
worker-01 and worker-02, both of which have ample room. worker-00 still *runs* workloads and can
still *mount* Longhorn volumes over the network — it just does not store replicas. This also
stops the smallest node from capping cluster-wide storage capacity.

The ceiling that buys you: with two storage nodes and two replicas, losing one node leaves every
volume degraded but online, with nowhere to rebuild until it returns. That is strictly better
than today (where losing worker-01 takes the volume offline entirely) and strictly worse than a
3-node replica set. For a homelab with a nightly backup underneath, it is the right trade.

## Prerequisites

Checked on all three nodes 2026-08-13:

| Requirement | State |
|---|---|
| `open-iscsi` installed | ✅ present on all three |
| `iscsid` enabled and running | ❌ **`disabled` / `inactive` on all three** |
| `nfs-common` | ✅ present (needed only for RWX/backup target) |
| `cryptsetup` | ✅ present (needed only for encrypted volumes) |
| Kubernetes ≥ 1.25 | ✅ v1.36.3 |

So the only node-level work is enabling and starting `iscsid` — a few lines in
`ansible/roles/common`, not a package install. Longhorn's V1 volumes depend on `iscsiadm` on the
host; without the daemon running, volumes fail to attach.

**Version: pin 1.11.3, not 1.12.0.** Upstream's release table marks 1.11.3 as the only current
*stable* release; 1.12.0 is latest but carries no stable designation yet. Renovate manages
`chartVersion` per repo convention, so add it with that in mind.

**k3s-specific:** Longhorn has a dedicated "CSI on K3s" doc covering the kubelet root directory,
which is not the default path on k3s. Verify `csi.kubeletRootDir` before the first install rather
than debugging attach failures afterwards.

## Risks

1. **A new failure domain under seven apps at once.** Today a `local-path` volume fails only if
   its node's NVMe fails. After Longhorn, every one of these volumes also depends on the Longhorn
   control plane, the CSI driver, and iSCSI attach/detach working correctly. The pin you are
   removing is also a form of simplicity.
2. **Per-node overhead.** Longhorn runs an instance-manager pod per node with meaningful RAM
   cost, plus the manager DaemonSet and CSI plugins. On worker-00 — 16GB, 4 cores, no HT, and
   the node that already hits per-UID kernel limits first — that is not free. Excluding it as a
   storage node reduces but does not eliminate this.
3. **Upgrade discipline.** Longhorn upgrades are a documented, ordered procedure with
   version-specific "important notes" per release. This is not a chart Renovate should bump
   unattended; treat it like Cilium, not like an app.
4. **SQLite on replicated block storage is fine, but not free.** Every SQLite commit becomes a
   synchronous write to two replicas over the network. These databases are small and low-traffic,
   so this should be invisible — but "should be" is doing work in that sentence, and the arrs are
   exactly the workload that produced 996 "database is locked" errors last time storage got
   slower than expected.
5. **Do not retire the app-level backups.** Longhorn snapshots and backups are volume-level and
   crash-consistent, not application-consistent. The arrs' System → Backup understands how to
   quiesce their own databases; Longhorn does not. Keep both.

## Interaction with the NAS and Talos

**Decided order: Longhorn → NAS → Talos.**

Longhorn and the NAS have no hard dependency in either direction. The one touch point is the
backup target, which wants NFS or S3: going Longhorn-first means pointing it at the current
`/mnt/storage` and repointing it after the NAS lands. One setting, no drama.

Worth knowing rather than acting on: unpinning does not pay off until the NAS exists. Today
worker-01 *is* the NFS server, so losing it takes down the media stack regardless of where the
pods could reschedule. A mobile arr only survives worker-01 dying once storage is off-host. So
Longhorn-first front-loads the work and collects the benefit at step two.

**Talos last has a real consequence for replica count.** Longhorn on Talos needs the
`iscsi-tools` system extension and a machine-config mount for `/var/lib/longhorn`, so the node
prerequisites get redone rather than carried over. More importantly, with `replicaCount: 2` and
worker-00 excluded, there are only two storage nodes — rebuilding either one as Talos drops a
replica and leaves every volume single-replica with nowhere to rebuild until that node returns.
Before starting the Talos migration, either temporarily admit worker-00 as a third storage node
(sizing permitting, which after Cleanuparr and with real usage in the tens of MB it likely does)
or accept and time-box a single-replica window per node. Do not discover this mid-rebuild.

The Talos audit's own hard blocker — worker-01 running `nfs-kernel-server`, which Talos cannot do
as a host service — is removed by the NAS at step two. That is what makes this order coherent:
each step unblocks the next. See `docs/talos-migration-audit.md`.

## Do nothing

The honest baseline. Leaving all nine volumes pinned costs zero effort and zero new failure
modes. What it costs is recovery time on a node failure: restoring an arr means recreating the
PVC and unpacking the newest backup archive, which is documented in each `config-pvc.yaml` and
takes minutes, not hours. Jellyfin should stay on worker-01 anyway for 12th-gen QuickSync.

Put plainly: Longhorn converts a ~30-minute manual recovery that happens approximately never into
an automatic one, at the cost of a permanent new layer under seven apps. That is a real trade,
not an obvious win.

## Plan

Longhorn goes first, ahead of the NAS. Steps:

1. **Enable `iscsid` via Ansible** on all three nodes. Already-installed package, service is
   `disabled`/`inactive`. Longhorn cannot attach volumes without it.
2. **Install Longhorn 1.11.3**, `replicaCount: 2`, worker-00 excluded as a storage node, backup
   target at the current `/mnt/storage`. Verify `csi.kubeletRootDir` against the k3s doc before
   the first install. UI needs an HTTPRoute and a VPA per repo convention.
3. **Migrate volumes one at a time, smallest first** — Cleanuparr (1.5 MB) and Bazarr (1.9 MB)
   before Lidarr (35 MB) — app scaled to zero in git, copy Job, `existingClaim` swap. Keep each
   old `local-path` PVC in git for two weeks as the rollback, exactly as
   `apps/vaultwarden/data-pvc.yaml` is being held. The smallest volume is the rehearsal for the
   rest; there is no need for a separate one.
   Keep the app-level backups running throughout; Longhorn's are crash-consistent, not
   application-consistent — which is precisely why `apps/cleanuparr/backup-cronjob.yaml` still
   has to exist after the move.
4. **Leave Jellyfin last, or never.** Its pin is wanted — 12th-gen QuickSync lives on worker-01,
   and its config PV is what actually enforces that.
5. **NAS**, then repoint the Longhorn backup target at it.
6. **Talos** — re-read the replica-count warning above before touching the first node.

**Cleanuparr → Postgres is not on this path.** It was scoped as a way to unpin that volume, and
Longhorn unpins it for free. The only benefit Postgres would still carry is retiring the bespoke
`backup-cronjob.yaml`, which is not worth running a 2-instance Postgres cluster for 1.5 MB of
settings. The plan stays filed at
`docs/superpowers/plans/2026-08-13-cleanuparr-postgres.md` as a researched option, not a
scheduled task.

Reality check to keep in view while doing this: the thing being bought is converting a
~30-minute documented manual recovery, on an event that has not yet happened, into an automatic
one. That is a legitimate thing to want. It is not an emergency, so if step 4 starts fighting
back on a particular app, leaving that one pinned is a perfectly good outcome.
