# Longhorn Evaluation

Whether to deploy Longhorn to unpin the `local-path` volumes. Written 2026-08-13, against
k3s v1.36.3 and the current contents of `apps/`.

> This evaluation predates the deployment. For what was actually built and verified, see
> `docs/archive/superpowers/specs/2026-08-13-longhorn-deployment-design.md` (spec) and
> `docs/superpowers/plans/2026-08-13-longhorn-deployment.md` (plan, still active — Task 16 is
> date-gated to 2026-08-27) — those are the implementation of record. Corrections below are marked
> inline; the rest of this document reflects the reasoning at decision time and still holds.

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

**Superseded by measurement.** The "Real data" figures below are database sizes, not volume
sizes — the spec's own table made the same mistake. Actual `/config` sizes, measured 2026-08-13
during migration: sonarr 107M, radarr 112M, lidarr 396M, prowlarr 97M, bazarr 7.3M, navidrome
64.5M, cleanuparr 1.9M, nextcloud-html 885M/28,124 files — mostly `MediaCover` and logs for
lidarr, which is why it is the tightest fit at 19% of its 2Gi claim. Total actual is ~1.67G
against 17Gi of claims once each volume was right-sized down from the 10Gi below at deploy time.

| Volume | Requested | Real data (database size, not volume size) | Can leave SQLite? |
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

Free space on each node's root filesystem, which is where `/var/lib/longhorn` lives:

| Node | Disk | Free | Notes |
|---|---|---|---|
| worker-00 | 115G | 69G | G4, smallest node, history of density problems |
| worker-01 | 466G | 396G | G9, media node |
| worker-02 | 233G | 189G | G6 |

**Superseded by measurement.** The 87Gi figure below came from the spec's sizing table, which
turned out to be database sizes, not volume sizes — the real per-volume figures, measured
2026-08-13 during migration, are an order of magnitude larger for some volumes (lidarr alone is
396M against a claimed 35 MB) but still small in aggregate: ~1.67G of real data against 17Gi of
requested claims, worst case 29% (nextcloud-html). At that scale even worker-00's 69G free holds
three full replicas with room to spare, so the right-sizing decision below — all three nodes as
storage nodes — survives contact with reality; only the reasoning that follows was wrong about
*why* it was safe.

At the default 3 replicas, every node holds a full copy — 87Gi on worker-00 by the (wrong)
requested-size table, which also reserves ~30% of the disk before it will schedule anything. That
looked like it didn't fit.

**Deployed as: `replicaCount: 2`, all three nodes as storage nodes.** Excluding worker-00 was
considered and rejected — see risk #2 below, since it turns out instance-manager pods run on
every node regardless of whether that node stores a replica, so excluding it bought nothing. With
real usage in single-digit-to-low-hundreds of MB per volume, all three nodes have ample room, and
`guaranteedInstanceManagerCPU` at 5% (not excluding a node) is what actually keeps worker-00 from
being squeezed.

The ceiling this buys: with three storage nodes and two replicas, losing one node leaves every
volume degraded but online, and the two surviving replicas rebuild onto the returning node
automatically — no manual intervention, unlike the two-storage-node case this section originally
argued for.

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
   the node that already hits per-UID kernel limits first — that is not free.
   **Correction, verified after deployment: excluding worker-00 as a storage node would not have
   reduced this.** Instance-manager pods are created eagerly on all three nodes regardless of
   whether any volume has a replica scheduled there — confirmed with zero volumes attached at
   install time. worker-00 pays the instance-manager cost either way; the actual mitigation is
   `guaranteedInstanceManagerCPU` at 5%, observed as a 200m CPU request on worker-00 versus 600m
   on the two 12-core nodes.
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

Worth carrying to the NAS: the backup target needed its own export
(`/mnt/storage/longhorn-backups`), separate from the main `/mnt/storage` share, because a pod on
worker-01 reaching its own node's IP is not masqueraded by Cilium — the LAN-scoped export ACL
that works for pods on the other two nodes doesn't see worker-01's pod traffic as coming from an
allowed address otherwise. That export also has to agree with the parent share's squash setting
(`no_root_squash`, here) rather than contradict it — a squashed child export nested under a
non-squashed parent lets NFSv4 clients resolve through the parent and produces mixed root/nobody
ownership on the backup tree, which then blocks `mkdir` for whichever client gets squashed. The
NAS inherits both constraints if it re-creates this export.

Worth knowing rather than acting on: unpinning does not pay off until the NAS exists. Today
worker-01 *is* the NFS server, so losing it takes down the media stack regardless of where the
pods could reschedule. A mobile arr only survives worker-01 dying once storage is off-host. So
Longhorn-first front-loads the work and collects the benefit at step two.

**Talos last still needs the node prerequisites redone.** Longhorn on Talos needs the
`iscsi-tools` and `util-linux-tools` system extensions and a machine-config mount for
`/var/lib/longhorn`, so this work gets redone rather than carried over from the Ansible role.
The replica-count concern this section originally raised — rebuilding a storage node drops a
replica with nowhere to go — does not apply as deployed: with all three nodes as storage nodes
and `replicaCount: 2`, rebuilding any one node as Talos still leaves two storage nodes standing,
and the surviving replicas re-place onto the rebuilt node automatically once it returns. No
manual single-replica window to time-box.

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
2. **Install Longhorn 1.11.3**, `replicaCount: 2`, all three nodes as storage nodes, backup
   target at the current `/mnt/storage`. Verify `csi.kubeletRootDir` against the k3s doc before
   the first install. UI needs an HTTPRoute; deliberately no VPA — Longhorn's own components are
   not a repo-convention app-template deployment.
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
