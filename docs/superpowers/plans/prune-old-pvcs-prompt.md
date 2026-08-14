# Prune prompt — retire the PVCs left behind by the Longhorn and CNPG migrations

Supersedes `task-16-prompt.md`, which covered only the Longhorn half, and absorbs the last
open item of `monitoring-audit-continuation-prompt.md` (part 2 below) — the other two items
of that prompt shipped on 2026-08-14.

**Gates.** Three dates. Run the Vaultwarden PVC on or after **2026-08-26**; the eight Longhorn
ones on or after **2026-08-27**; the Prometheus TSDB PV on or after **2026-08-28**. Part 3 is
ungated. Doing everything in one session on/after 08-28 is fine and is the least error-prone
order. Delete this file once the prune is done.

Three separate populations, and they do not behave the same way:

| Part | What | Count | Reclaim policy | Deleting it means |
|---|---|---|---|---|
| 1 | Longhorn/CNPG migration leftovers | 9 PVCs | **Delete** | remove the PVC block from git; ArgoCD destroys the data immediately |
| 2 | Prometheus TSDB on NFS | 1 PV | **Retain** | `kubectl delete pv` **and** `rm -rf` the directory on worker-01 |
| 3 | Released NFS PVs from the 2026-08-06 arr migration | 15 PVs | **Retain** | same as part 2 — object plus directory |

Parts 2 and 3 are the inverse of part 1: there the PVC delete is the point of no return, here
`kubectl delete pv` frees nothing on disk at all and quietly leaves the bytes behind forever.

## Part 1 — the nine migration PVCs (gates 2026-08-26 / 2026-08-27)

Paste the block below into a Claude Code session in this repo.

---

```
Prune the PVCs left behind by two completed migrations: Longhorn (Task 16 of
docs/superpowers/plans/2026-08-13-longhorn-deployment.md) and the Vaultwarden
Postgres move (Task 10 of docs/superpowers/plans/2026-08-11-vaultwarden-postgres.md).
Read the status note at the top of the Longhorn plan first.

## The nine PVCs to remove — and nothing else

  apps/bazarr/config-pvc.yaml        bazarr-config-local        5Gi   worker-01
  apps/cleanuparr/config-pvc.yaml    cleanuparr-config-local    2Gi   worker-00
  apps/lidarr/config-pvc.yaml        lidarr-config-local       10Gi   worker-01
  apps/navidrome/config-pvc.yaml     navidrome-config-local    10Gi   worker-01
  apps/prowlarr/config-pvc.yaml      prowlarr-config-local     10Gi   worker-01
  apps/radarr/config-pvc.yaml        radarr-config-local       10Gi   worker-01
  apps/sonarr/config-pvc.yaml        sonarr-config-local       10Gi   worker-01
  apps/nextcloud/html-pvc.yaml       nextcloud-html            10Gi   worker-01
  apps/vaultwarden/data-pvc.yaml     vaultwarden-data-local     5Gi   worker-00

Each file declares BOTH the old and the new PVC. Remove only the old block; the
Longhorn one stays. (apps/vaultwarden/data-pvc.yaml declares only the old one, so
that whole file goes; the live volume lives in data-pvc-nfs.yaml.)

## DO NOT TOUCH — these look like leftovers and are not

- vaultwarden-data (nfs, 5Gi). STILL MOUNTED by the running Vaultwarden pod at
  /data. Only the SQLite *database* moved to Postgres; attachments, sends, icon
  cache and the RSA keys still live here. values.yaml:78 points at it. The
  Postgres move retired vaultwarden-data-local, not this.
- jellyfin-config-local (local-path, 20Gi, worker-01). NEVER MIGRATED — the
  jellyfin pod is running on it right now (values.yaml:77). The name matches the
  prune pattern and it is not in scope. See the note at the bottom of this prompt.
- Every *-database-N PVC on local-path (immich, infisical, nextcloud,
  vaultwarden). CNPG volumes are local-path deliberately; see CLAUDE.md Rules.

## BLOCKER — fix this before pruning cleanuparr

apps/cleanuparr/backup-cronjob.yaml:153 still mounts claimName:
cleanuparr-config-local. The app itself moved to cleanuparr-config (longhorn) on
2026-08-13, so every nightly backup since then has snapshotted the DEAD volume.
Two consequences:
  1. Deleting the PVC breaks the CronJob — its pods go unschedulable.
  2. There is currently no valid Cleanuparr backup, so the pre-prune verification
     below cannot pass for it either.
Fix the claimName to cleanuparr-config, let a run succeed, verify the archive is
non-empty and recent, THEN prune. Separate commit, ahead of the prune commits.

## The correction that matters most

**All nine old PVs are reclaimPolicy: Delete, not Retain.** (Verified: the only
Retain PV in vaultwarden is vaultwarden-data, which you are not touching.) The
Longhorn plan's Steps 3-4 assume Retain and describe reclaiming "Released" PVs
afterwards. There will be none. Removing a PVC block from git -> ArgoCD prunes it
-> the data is destroyed immediately, with no second layer. Git history is the
ONLY rollback, not the outer of two. Step 4 has nothing to act on; the prune
itself frees the disk.

So treat verification as load-bearing, not a formality. Before deleting anything:

- All Longhorn volumes robustness=healthy:
    kubectl -n longhorn-system get volumes.longhorn.io
- EVERY volume has a Completed backup:
    kubectl -n longhorn-system get backups.longhorn.io
  Watch for state=Error. A backup Job reports condition=complete even when the
  Backup CR failed and the backupstore is empty — this happened twice during the
  migration. There is a LonghornBackupFailed alert now; verify directly anyway.
- For Vaultwarden, confirm the CNPG cluster is 3/3 and a pg-backup has run, since
  vaultwarden-data-local is the last copy of the pre-migration SQLite database.
- Confirm nothing mounts the nine claims:
    kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $n |
      .spec.volumes[]? | select(.persistentVolumeClaim) |
      "\($n) \(.persistentVolumeClaim.claimName)"' | sort -u
  Expect hits only for jellyfin-config-local and vaultwarden-data (both keepers),
  plus cleanuparr-config-local until the CronJob fix above lands.

Only then delete the old PVC blocks, one commit per app, and watch ArgoCD sync
each one before moving to the next.

## Also while you are in there

Re-check the #13152 replica leak (Longhorn 1.11.3 lacks 1.12.0's fix; this
cluster runs best-effort locality plus a daily recurring job):
    kubectl -n longhorn-system get replicas.longhorn.io --no-headers | wc -l
Baseline at migration was 16 replicas / 8 volumes = exactly 2x, no drift.
Materially above 2x means upgrade to 1.12.1 — NOT abandon best-effort, which is
the fsync-tax mitigation. There is a LonghornReplicaLeak alert now too.

Note: reclaimPolicy Retain on the LONGHORN class means deleting a Longhorn PVC
leaves its volume alive and still backed up nightly. That bit twice during
testing. Irrelevant to this prune (all nine are local-path or NFS), but if you
delete any Longhorn volume for another reason, also:
    kubectl -n longhorn-system delete volumes.longhorn.io <name>

## After

Move both plans to docs/archive/superpowers/plans/ and add index rows to
docs/archive/README.md — they are only still in docs/superpowers/plans/ because
the archive convention forbids docs with open items. Delete this prompt file.
```

---

## Part 2 — the Prometheus TSDB PV (gate 2026-08-28)

`pvc-9dbb49b1-67bc-4e50-9cde-31a9db461985`, 20Gi, `Released`, `Retain`, holding **11GB** at
`worker-01:/mnt/storage/monitoring-system/prometheus-…-prometheus-0`. It is the rollback for
PR #56, the NFS-to-longhorn TSDB move, and it is the alerting path's own history.

Confirm the new volume has earned it before deleting:

- `prometheus_tsdb_wal_corruptions_total` still 0
- the longhorn volume `attached`, robustness `healthy`, both replicas `running`
- `time() - prometheus_tsdb_lowest_timestamp_seconds` at or near the full 10d retention
  window — i.e. the TSDB re-accumulated a complete window on longhorn rather than still
  living on the blocks the migration Job copied
- no `EndpointDown`, `CiliumUnreachableNodes` or storage alert fired in the interim

Then both halves: `kubectl delete pv` releases the object, and the directory on worker-01 has
to go separately. Say which you did.

## Part 3 — 15 Released NFS PVs from the 2026-08-06 arr migration (ungated)

These predate everything above: they are what the arrs left on NFS when SQLite-on-NFS was
abandoned. All 15 are `Released` + `Retain`, none is referenced anywhere in git, and none has
had a claim since 2026-08-06. Nothing gates them; they are grouped here so `kubectl get pv`
stops being 60 rows of which a quarter are ghosts.

    bazarr/bazarr                    3.3M     prowlarr/prowlarr-nfs-config      12M
    bazarr/bazarr-nfs-config         1.1M     qbittorrent/qbittorrent-nfs       16M
    jellyfin/jellyfin                891M     radarr/radarr                    107M
    jellyfin/jellyfin-nfs            387M     radarr/radarr-nfs-config          87M
    lidarr/lidarr                    239M     recyclarr/recyclarr-nfs-config    74M
    navidrome/navidrome               45M     sonarr/sonarr                    106M
    prowlarr/prowlarr                 97M     sonarr/sonarr-nfs                 71M
    vaultwarden/vaultwarden-nfs      7.2M

All paths are under `/mnt/storage/` on worker-01. **Delete the named subdirectory, never the
parent** — `/mnt/storage/qbittorrent/` and `/mnt/storage/recyclarr/` also contain the live
`qbittorrent` and `recyclarr` NFS volumes, and `/mnt/storage/jellyfin/` sits next to a
directory tree Jellyfin still reads. The two-per-app pattern (`sonarr` and `sonarr-nfs`) is
from two separate attempts at the same migration, not one live and one dead.

Total across parts 2 and 3: ~13GB on the 12TB drive, which is not the point — the point is
that 16 `Released` PVs make the next storage audit read a screen of objects that mean nothing.

## Why this file exists

The prune is the one irreversible step in both migrations, and the Longhorn plan is wrong about the
safety net. The prompt front-loads that correction so it is read *before* the delete rather than
discovered after it.

The three "do not touch" entries and the Cleanuparr blocker were found by surveying live PVCs and
pod mounts on 2026-08-14, not by reading the plans — the plans do not mention any of them. Naming is
the trap: `vaultwarden-data` sounds retired and is live, `jellyfin-config-local` sounds retired and
is live, and `cleanuparr-config-local` is dead but still has a CronJob pointed at it.

Reclaimed on success: 72Gi of requested capacity from part 1, 62Gi of it on worker-01, plus
~13GB of real bytes and 16 dead PV objects from parts 2 and 3.

Parts 2 and 3 were added on 2026-08-14 by surveying live PVs rather than by reading any plan.
Part 3 in particular is in no document anywhere — the arr NFS migration on 2026-08-06 left 15
`Released` PVs and nobody wrote them down, which is exactly how the 33-day silent etcd gap
happened in the monitoring audit. The pattern is the same: the leftover is invisible because
nothing is looking, not because anything is wrong.

## Separately: Jellyfin never moved to Longhorn

`jellyfin-config-local` is a 20Gi local-path volume pinned to worker-01, holding `jellyfin.db`
(SQLite). It is exactly the case CLAUDE.md's Storage section says belongs on `longhorn`, and it was
missed by the 2026-08-13 migration — the seven arrs and `nextcloud-html` moved, Jellyfin did not.
Not part of this prune. Worth its own small migration, following the same shape as
`apps/sonarr/config-pvc.yaml`.

Supporting detail, if needed: the execution ledgers at
`.superpowers/sdd/2026-08-13-longhorn-deployment/progress.md` and
`.superpowers/sdd/2026-08-11-vaultwarden-postgres/progress.md` (git-ignored) record every defect
found during the two migrations with live evidence. Keep them until the prune is done.
