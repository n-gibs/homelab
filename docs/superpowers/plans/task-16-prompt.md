# Task 16 prompt — retire the retained local-path PVCs

**Run on or after 2026-08-27.** Paste the block below into a Claude Code session in this repo.

Gate: two weeks past each Merge B (all landed 2026-08-13) **and** a clean 24h Sonarr watch
(Task 15 Step 7). Delete this file once Task 16 is done.

---

```
Run Task 16 of the Longhorn migration:
docs/superpowers/plans/2026-08-13-longhorn-deployment.md

It retires the eight retained local-path PVC blocks (the *-config-local PVCs in
apps/{sonarr,radarr,lidarr,prowlarr,bazarr,navidrome,cleanuparr}/config-pvc.yaml plus
nextcloud-html in apps/nextcloud/html-pvc.yaml). Gated on two weeks past each Merge B
(all landed 2026-08-13) plus a clean 24h Sonarr watch.

READ THE STATUS NOTE AT THE TOP OF THE PLAN FIRST. The critical correction:

**The old local-path PVs are reclaimPolicy: Delete, not Retain.** The plan's Steps 3-4
assume Retain and describe reclaiming "Released" PVs afterwards. There will be none.
Removing a PVC block from git -> ArgoCD prunes it -> the data is destroyed immediately,
with no second layer. The two weeks of git history is the ONLY rollback, not the outer
of two. Step 4 ("reclaim the released PVs") has nothing to act on; the prune itself
frees the disk.

So treat Step 2 as load-bearing, not a formality:
- Confirm all 8 Longhorn volumes are robustness=healthy
- Confirm EVERY volume has a Completed backup:
  kubectl -n longhorn-system get backups.longhorn.io
  Watch for state=Error — a backup Job reports condition=complete even when the Backup
  CR failed and the backupstore is empty (this happened twice during the migration).
  There is now a LonghornBackupFailed alert for this, but verify directly anyway.
- Only then delete the old PVC blocks, one commit per app.

Also re-check the #13152 replica leak while you're there (Longhorn 1.11.3 lacks
1.12.0's fix; this cluster runs best-effort locality + a daily recurring job):
  kubectl -n longhorn-system get replicas.longhorn.io --no-headers | wc -l
Baseline at migration was 16 replicas / 8 volumes = exactly 2x, no drift. Materially
above 2x means upgrade to 1.12.1 — NOT abandon best-effort, which is the fsync-tax
mitigation. There is a LonghornReplicaLeak alert now too.

Note: reclaimPolicy Retain on the LONGHORN class means deleting a Longhorn PVC leaves
its volume alive and still being backed up nightly. That bit twice during testing. If
you delete any Longhorn volume, also:
  kubectl -n longhorn-system delete volumes.longhorn.io <name>

After Task 16 completes, move the plan to docs/archive/superpowers/plans/ and add an
index row to docs/archive/README.md — it's only still in docs/superpowers/plans/
because the archive convention forbids docs with open items.
```

---

## Why this file exists

Task 16 is the one irreversible step in the migration, and the plan it belongs to is wrong about the
safety net. The prompt above front-loads that correction so it is read *before* Steps 3–4 rather
than discovered after the prune.

Supporting detail, if needed: the execution ledger at
`.superpowers/sdd/2026-08-13-longhorn-deployment/progress.md` (git-ignored) records all nineteen
defects found during the migration with live evidence. Keep it until Task 16 is done.
