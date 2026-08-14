# Prompt — move the Jellyfin config volume to Longhorn

The 2026-08-13 migration moved eight volumes to Longhorn and missed this one. `jellyfin.db` is
SQLite on a 20Gi `local-path` volume pinned to worker-01, which is exactly the case CLAUDE.md's
Storage section says belongs on `longhorn`.

Ungated — nothing is waiting on a date. Paste the block below into a Claude Code session in this
repo. Delete this file once the migration is done.

---

```
Move Jellyfin's config volume from local-path to longhorn, following the Migration Runbook in
docs/superpowers/plans/2026-08-13-longhorn-deployment.md (the "Merge A / Copy / Merge B /
Rollback" section, roughly lines 130-250). Eight volumes went through that runbook already;
this is the ninth and the shape is identical. $APP=jellyfin, $NS=jellyfin.

Read apps/jellyfin/config-pvc.yaml and apps/sonarr/config-pvc.yaml first. Sonarr's file is the
target shape: both PVCs declared in one file, old block kept for two weeks as the rollback,
new block carrying the reasoning.

## Facts, measured 2026-08-14

- jellyfin-config-local, 20Gi local-path, Bound, worker-01, holding 889M.
  889M is the PVC alone. `du -sh /config` inside the pod reports 898M because
  /config/data/data/backups is an NFS mount layered inside the config tree — the copy Job
  mounts the PVC directly, so it will not see those 8.8M and the old/new du figures will
  both read 889M, not 898M. Do not chase the difference.
- Size the new PVC 3Gi. 889M today, mostly metadata and MediaCover under /config/data, and
  longhorn expands in place — so unlike the local-path PVC it is not sized once.
- The backup prerequisite is already satisfied: apps/jellyfin/backup-cronjob.yaml calls
  Jellyfin's own POST /Backup/Create nightly and verifies a new archive appeared. Newest is
  jellyfin-backup-20260813204503.zip. Unlike Cleanuparr's CronJob it mounts no PVC, so it
  needs no edit — but take a fresh backup before the copy anyway. That archive is the
  rollback's second layer.
- Jellyfin 10.11.11. Restore path is `--restore-archive` or Dashboard -> Backups -> Restore.

## What this migration does and does not buy

It buys a second replica, so worker-01's NVMe dying degrades the volume instead of destroying
it. It does NOT unpin the pod: the nodeSelector homelab.io/media=true matches worker-01 only,
and the container requests gpu.intel.com/i915 for QuickSync. worker-02 has an i915 but not the
label; worker-00 has the iGPU blacklisted. So do not write "removes the node pin" in the
comment the way the arr PVCs do — for Jellyfin that is false.

## Jellyfin-specific traps

1. The copy Job must not request gpu.intel.com/i915. The runbook's alpine Job doesn't; leave
   it that way. There is one i915 resource on worker-01 and Jellyfin will want it back.
2. Give the copy Job a 1Gi memory limit, not the runbook's 256Mi. Page cache counts against
   the cgroup — a 10GB copy was OOMKilled at 256Mi during the TSDB migration. 889M will
   probably squeak through at 256Mi, which is worse than failing outright.
3. apps/jellyfin/limitrange.yaml defaults an unset memory limit to 512Mi and sets no maximum,
   so an explicit 1Gi limit on the Job is accepted. It also means a Job with no limit at all
   silently gets 512Mi.
4. controllers.main.strategy is already Recreate, so two Jellyfins cannot hold the SQLite
   database at once. Keep it.
5. values.yaml lines 72-79 comment persistence.config as local-path and explain the SQLite
   rationale. Rewrite it in Merge B — a stale comment explaining a class the volume no longer
   uses is how the next person concludes the migration never happened.
6. The tolerations block for homelab.io/media is a no-op (the taint was removed 2026-07-31).
   Not part of this task, but if you touch that block anyway, drop it.

## Verify beyond "pod is Ready"

Ready only proves the container started. Confirm the database actually opened:

- kubectl -n jellyfin exec deploy/jellyfin -- ls -la /config/data/data/  (jellyfin.db present,
  plus -wal and -shm)
- Play something. SQLite-over-a-bad-filesystem shows up on writes, not reads: the NFS failure
  on 2026-08-10 was "SQLite Error 5: 'database is locked'" on POST /Sessions/Playing/Progress,
  so a library listing proves nothing.
- kubectl -n jellyfin logs deploy/jellyfin | grep -i "database is locked"  → expect nothing
- kubectl -n longhorn-system get volumes.longhorn.io  → the new volume attached,
  robustness=healthy, 2 replicas running
- probe_success for https://jellyfin.nik-homelab.dev stays 1 (blackbox has covered it since
  2026-08-14; EndpointDown fires at 5m, so a long restart will page)
- Let one nightly backup CronJob run against the new volume before considering it done.

## After

Leave the old jellyfin-config-local PVC block in git for two weeks as the rollback, then add a
tenth row to docs/superpowers/plans/prune-old-pvcs-prompt.md part 1 with its own gate date
(migration date + 14d). Do not prune it in this session.

Nothing to configure for Longhorn backups — the `daily-backup` RecurringJob (04:30, retain 7)
is in the `default` group, which every existing volume carries as
`recurring-job-group.longhorn.io/default: enabled` without anyone setting it. Verify the new
volume picked it up rather than assume:

    kubectl -n longhorn-system get volumes.longhorn.io <pvc-name> -o jsonpath='{.metadata.labels}'

That is a crash-consistent block backup, which is why the nightly /Backup/Create archive still
matters — it is the application-consistent one.
```

---

## Why this file exists

The volume was missed by the 2026-08-13 migration, and the miss was invisible: the name
`jellyfin-config-local` matches the prune pattern exactly, so on 2026-08-14 it read as a leftover
to delete rather than a volume that never moved. It is called out as a keeper in
`prune-old-pvcs-prompt.md` for that reason.

The runbook is already written and proven on eight volumes, so this prompt is only the
Jellyfin-specific delta: measured sizes, the NFS-inside-/config du discrepancy, the GPU pin that
survives the migration, and the fact that the backup story here is already in place rather than
something to build first.
