# Cleanuparr SQLite → Postgres Implementation Plan

> **STATUS: DEFERRED, not scheduled.** Decided 2026-08-13. This plan existed to unpin
> `cleanuparr-config-local` from its node, and Longhorn does that for free as part of
> `docs/archive/longhorn-evaluation.md` — along with the other six SQLite volumes. The only benefit
> Postgres would still carry is retiring `apps/cleanuparr/backup-cronjob.yaml`, and Longhorn does
> **not** make that CronJob redundant either: Longhorn snapshots are crash-consistent, so a
> WAL-mode SQLite database still needs the online-backup API that CronJob wraps. Running a
> 2-instance Postgres cluster for 1.5 MB of settings to delete ~200 lines of script is not a
> trade worth making.
>
> Kept because the research is done and non-obvious — in particular the upstream documentation
> bug recorded under Task 2. Revisit only if Cleanuparr's SQLite handling becomes a problem in
> its own right, or if the app grows enough that its events database stops being trivial.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Cleanuparr's three SQLite databases into a CloudNativePG cluster and return `/config` to `nfs` RWX, so the pod can schedule on any node instead of following its `local-path` PV to worker-00.

**Why this app first:** Cleanuparr ships a supported, transactional `migrate-to-postgres` subcommand — unlike Servarr, which documents SQLite migration as unsupported. It is also the only app whose SQLite durability depends on a bespoke CronJob (`apps/cleanuparr/backup-cronjob.yaml`, written because Cleanuparr has no built-in backup). Migrating replaces ~200 lines of hand-rolled online-backup script with the standard `pg-backup.yaml` pattern used four times elsewhere. Smallest data, supported path, deletes code — the right rehearsal before touching a 35 MB Lidarr database.

**Architecture:** A CNPG cluster on `local-path` (see the open decision on instance count below). The app reads `DATABASE_PROVIDER=postgres` plus `POSTGRES_*` from the CNPG-generated `cleanuparr-database-app` secret. `/config` survives the migration but stops holding SQLite — it keeps DataProtection keys, `cleanuparr.json`, and logs — so it moves to `nfs` RWX. The transfer runs from a hand-applied Job while the Deployment is held at `replicas: 0` **in git**.

**Tech Stack:** k3s, ArgoCD (auto-sync, `prune: true`, `selfHeal: true`), CloudNativePG, bjw-s `app-template` 5.0.1, `ghcr.io/cleanuparr/cleanuparr:2.10.3`, PostgreSQL 18.

**Upstream reference:** <https://cleanuparr.github.io/Cleanuparr/docs/installation/database> (source of truth for the env vars and the migration subcommand; re-read before starting in case 2.10.x moved).

## Global Constraints

- **Merge to `main` = deploy.** ArgoCD auto-syncs. Verify in-cluster before merging anything, and use one branch per logical change.
- **Never `kubectl apply` a manifest that lives in git.** `selfHeal: true` will fight you. The only hand-applied object in this plan is the migration Job, which is deliberately *not* committed.
- **Never `kubectl scale`.** Replica count changes are commits.
- **No `sleep`, anywhere** — not in scripts, not in manifests, not in poll loops. Use `kubectl wait --timeout`.
- **`config-pvc.yaml` must stay in git and unmodified** until Task 9. `local-path` is `reclaimPolicy: Delete`; the moment that file leaves git, ArgoCD prunes the PVC and the provisioner deletes the SQLite files behind it — which are the rollback.
- **The CronJob must keep the name `cleanuparr-db-backup`.** `BackupCronJobMissing` in `system/monitoring-system/prometheusrule-backups.yaml` counts CronJobs matching `.+-db-backup` and alerts `critical` below **6**. Renaming it trips a page.
- **Never add `Co-Authored-By` trailers**, and never reference Claude or Anthropic in a commit message.
- Namespace is `cleanuparr`; NFS server is `192.168.30.194`, share `/mnt/storage`.
- Source row counts must be captured in Task 3 **before** the migration and used by every later verification step. Current on-disk sizes for sanity: `cleanuparr.db` 467 KB, `events.db` 966 KB (+4.1 MB WAL), `users.db` 102 KB.

## Open decision — settle before Task 1

**How many CNPG instances?** Every other CNPG cluster in this repo runs 3. For Cleanuparr that means 3 Postgres pods and 3 `local-path` PVCs backing 1.5 MB of settings and an events log.

- **2 instances (recommended).** Satisfies the CLAUDE.md `local-path` case (2) cleanly — streaming replication, not the volume, survives a node failure — at two-thirds the footprint. With three nodes and `podAntiAffinityType: required` it schedules fine.
- 3 instances: consistent with the other four clusters, no other benefit here.
- 1 instance: smallest, but it fails the CLAUDE.md rule as written — no replication means `local-path` is once again the only copy, and durability falls entirely to the nightly dump. That is the same durability model Cleanuparr has *today*, so it is not a regression, but it does not advance the goal either. Only pick this if the pod-mobility win alone is the point.

The rest of the plan assumes **2**. Change `spec.instances` in Task 1 if you decide otherwise; nothing else depends on it.

## File Structure

| File | Responsibility |
|---|---|
| `apps/cleanuparr/postgres.yaml` | **new.** CNPG `Cluster` + `Database`. Task 1. |
| `apps/cleanuparr/values.yaml` | `DATABASE_PROVIDER` + `POSTGRES_*` env, `replicas`, `/config` claim swap. Tasks 2, 4, 6, 8. |
| `apps/cleanuparr/pg-backup.yaml` | **new.** Replaces the SQLite CronJob. Name stays `cleanuparr-db-backup`. Task 7. |
| `apps/cleanuparr/backup-cronjob.yaml` | **deleted** in Task 7. |
| `apps/cleanuparr/config-pvc-nfs.yaml` | **new.** RWX `nfs` claim for the post-migration `/config`. Task 8. |
| `apps/cleanuparr/config-pvc.yaml` | untouched until Task 9 — it is the rollback. |
| `system/monitoring-system/prometheusrule-backups.yaml` | header comment only; the `< 6` threshold does not change. Task 7. |

---

## Task 1 — CNPG cluster

- [ ] Create `apps/cleanuparr/postgres.yaml`, modelled on `apps/vaultwarden/postgres.yaml`:
  - `Cluster` `cleanuparr-database`, `instances: 2`, `imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`
  - `storage: {size: 2Gi, storageClass: local-path}` — `local-path` cannot be expanded in place, so size once; 2Gi against 1.5 MB is enormous headroom
  - `affinity.podAntiAffinityType: required`
  - `resources.requests: {cpu: 100m, memory: 256Mi}`, `limits.memory: 1Gi`, **no cpu limit** (VPA ratio preservation — see `apps/vaultwarden/limitrange.yaml`)
  - `argocd.argoproj.io/sync-wave: "-1"` on both objects
  - `Database` `cleanuparr-database`, `spec.name: app`, `spec.owner: app`
- [ ] Commit, merge, let ArgoCD sync.
- [ ] **Verify:** `kubectl -n cleanuparr get cluster cleanuparr-database` reports healthy with 2 ready instances, and `kubectl -n cleanuparr get secret cleanuparr-database-app` exists.
- [ ] **Verify the exporter grant.** Per the `cluster_cnpg_exporter_connect_grant` note, a CNPG cluster can look healthy while emitting no replication metrics without a manual `CONNECT` grant. Apply the same grant used on the other clusters and confirm metrics appear, or this cluster is invisible to monitoring.

## Task 2 — Entrypoint (resolved — verified against the v2.10.3 tag)

No investigation needed; this was confirmed in source before the plan was written. Recorded here so the Job can be built directly.

- `migrate-to-postgres` and `--force` both exist at `v2.10.3` (`Cleanuparr.Api/Commands/MigrateToPostgresCommand.cs`).
- The image is `WORKDIR /app`, `ENTRYPOINT ["/entrypoint.sh"]`, `CMD ["./Cleanuparr"]`, and `entrypoint.sh` ends in `exec "$@"`. **Do not override `command`** — overriding it skips the `UMASK`/`PUID` handling and the `/config` writability precheck. Override `args` only:

  ```yaml
  args: ["./Cleanuparr", "migrate-to-postgres"]
  ```

- [ ] Re-verify the tag still matches if Renovate has bumped `apps/cleanuparr/values.yaml` since 2026-08-13. If the image moved, redo the two checks above against the new tag before continuing.

### The SQLite files are NOT an untouched backup

The upstream docs claim the SQLite files "are only read, never modified or deleted, so they remain in place as a backup." **This is false for v2.10.3.** `SqliteToPostgresMigrator.RunAsync` calls `MigrateSourceSchemaAsync` before copying anything, which runs `Database.MigrateAsync()` against all three SQLite contexts — an in-place schema write. The command's own final line says so: *"Your SQLite databases were upgraded to the current schema in place."*

The practical risk is low while the deployed image is 2.10.3, because the running app applies those same EF migrations at startup, so the files are already at that schema and the step is a no-op. It stops being a no-op if the image is bumped first. Do not rely on it either way — Task 4 takes an explicit copy.

## Task 3 — Capture source row counts

- [ ] With the app still running normally, exec into the pod and record per-table row counts from all three SQLite files (`cleanuparr.db`, `events.db`, `users.db`). Use the `sqlite3` binary if present, otherwise a short read-only Python snippet.
- [ ] Write the counts into this plan under Task 5 so verification has a fixed target. `events.db` grows continuously, so note the timestamp — its count will legitimately differ if the app runs again before the cutover.

## Task 4 — Stop the app in git

- [ ] In `apps/cleanuparr/values.yaml`, set `controllers.main.replicas: 0` with a comment naming this plan and the fact it is temporary.
- [ ] Commit, merge, confirm zero pods: `kubectl -n cleanuparr get pods`.
- [ ] Confirm the `cleanuparr-config-local` PVC is released and note which node it lives on — the migration Job must land there. `kubectl get pv -o wide | grep cleanuparr`.
- [ ] **Take an explicit copy of `/config` before the migration touches it.** Trigger the existing SQLite CronJob once (`kubectl -n cleanuparr create job --from=cronjob/cleanuparr-db-backup pre-migration`) and confirm a fresh archive landed on the NFS share. This is the real rollback — see Task 2 on why the in-place SQLite files are not one. Do this while the app is stopped so the databases are quiescent. Delete the Job afterwards.

## Task 5 — Run the migration (hand-applied Job, not committed)

- [ ] Write the Job to a scratch path **outside the repo** so ArgoCD never sees it.
  - Image `ghcr.io/cleanuparr/cleanuparr:2.10.3`, `args: ["./Cleanuparr", "migrate-to-postgres"]`, **no `command:` override** (Task 2)
  - Mounts `cleanuparr-config-local` at `/config` (RWO node affinity places the pod correctly on its own)
  - `securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}` to match the app
  - Env: `DATABASE_PROVIDER=postgres`, `POSTGRES_HOST=cleanuparr-database-rw`, `POSTGRES_PORT=5432`, `POSTGRES_DB=app`, and `POSTGRES_USER`/`POSTGRES_PASS` via `secretKeyRef` on `cleanuparr-database-app` (`username`/`password`)
  - `restartPolicy: Never`, `backoffLimit: 0` — a partial retry against a half-populated target is worse than a clean failure
- [ ] `kubectl apply -f <scratch path>`, then `kubectl -n cleanuparr wait --for=condition=complete job/cleanuparr-migrate --timeout=10m`.
- [ ] Read the logs. The command prints per-table row counts on success and copies all three schemas in one transaction.
- [ ] **Verify:** logged row counts match Task 3 exactly. Then confirm independently against Postgres — `psql` into `cleanuparr-database-rw` and count rows in the `data`, `events`, and `users` schemas.
- [ ] Delete the Job.

**If it fails:** rollback is Task 4 in reverse — `replicas: 1`, no env change, and the app comes back on SQLite. This works because the migration only *upgrades* the SQLite schema rather than destroying data, and 2.10.3 is the schema the app already runs. If the files are damaged, restore the Task 4 archive into `/config`; that is why it is taken. If the Postgres target ended up partially populated, the command refuses to re-run — use `--force` to wipe and re-import rather than hand-cleaning.

## Task 6 — Point the app at Postgres

- [ ] In `apps/cleanuparr/values.yaml`, add to `controllers.main.containers.app.env`:
  `DATABASE_PROVIDER: postgres`, `POSTGRES_HOST: cleanuparr-database-rw`, `POSTGRES_PORT: "5432"`, `POSTGRES_DB: app`, and `POSTGRES_USER`/`POSTGRES_PASS` via `valueFrom.secretKeyRef` on `cleanuparr-database-app`.
- [ ] Restore `replicas: 1` (delete the Task 4 line and its comment).
- [ ] Commit, merge.
- [ ] **Verify:** pod Ready; UI at `https://cleanuparr.nik-homelab.dev` loads and shows the pre-migration arr connections, API keys, and job settings; log in with the existing account (proves the `users` schema came across); Blacklist Sync still points at the in-cluster ConfigMap path, not the upstream list. Watch logs for a full job cycle — Queue Cleaner writing to `events` is the real proof the write path works, not just reads.

## Task 7 — Replace the backup CronJob

- [ ] Create `apps/cleanuparr/pg-backup.yaml` modelled on `system/infisical/pg-backup.yaml`: an `nfs` RWX PVC named `cleanuparr-db-backup` (1Gi) plus a CronJob **named `cleanuparr-db-backup`** running `pg_dump -d app -Fc`, 14-day retention, `app.kubernetes.io/name` pod label set so Alloy gives it its own Loki stream.
- [ ] Keep the schedule clear of the existing 03:00 dumps to avoid four concurrent jobs on the NFS share.
- [ ] Delete `apps/cleanuparr/backup-cronjob.yaml`.
- [ ] Update the header comment in `system/monitoring-system/prometheusrule-backups.yaml` — it currently says "three Postgres dumps ... Cleanuparr's SQLite backup". The `< 6` expression and the alert description do **not** change, because the name is preserved.
- [ ] Commit, merge.
- [ ] **Verify:** trigger it once — `kubectl -n cleanuparr create job --from=cronjob/cleanuparr-db-backup manual-test` — and confirm a non-trivial `.dump` lands on the NFS share and the logged byte count is plausible. Confirm `count(kube_cronjob_status_last_successful_time{cronjob=~".+-db-backup"})` is still 6 in Prometheus.
- [ ] Delete the manual test Job.

## Task 8 — Move `/config` to NFS

`/config` is still required after the migration — it holds ASP.NET DataProtection keys, `cleanuparr.json`, and logs. Only the `.db` files stop being used. Losing the DataProtection keys invalidates existing sessions (everyone logs in again); it does not lose data. Copy them rather than regenerating.

- [ ] Create `apps/cleanuparr/config-pvc-nfs.yaml`: PVC `cleanuparr-config-nfs`, `storageClassName: nfs`, `accessModes: [ReadWriteMany]`, 2Gi. Include a comment explaining why `/config` is NFS-safe *now* (no SQLite) and naming the recovery path — mirror the tone of `apps/vaultwarden/data-pvc-nfs.yaml`.
- [ ] Set `replicas: 0` in git again, then hand-apply a short Job mounting **both** PVCs that copies everything except `*.db*` from the old volume to the new one. Verify the DataProtection key directory and `cleanuparr.json` arrived.
- [ ] Switch `persistence.config.existingClaim` to `cleanuparr-config-nfs`, restore `replicas: 1`, update the stale comment above it (it currently says "local-path, not nfs — /config is SQLite").
- [ ] Commit, merge.
- [ ] **Verify:** pod Ready and — the actual point of this whole plan — `kubectl -n cleanuparr get pod -o wide` shows it is no longer bound to the old node. Confirm by deleting the pod and watching it reschedule successfully, ideally elsewhere.

## Task 9 — Retire the rollback (date-gated)

**Do not start before 2026-08-27** (two weeks of Postgres running clean), matching the discipline used for `apps/vaultwarden/data-pvc.yaml`.

- [ ] Confirm 14 consecutive successful `cleanuparr-db-backup` runs and no Postgres-related errors in the Loki stream.
- [ ] Delete `apps/cleanuparr/config-pvc.yaml`. ArgoCD prunes the PVC and `local-path` (`reclaimPolicy: Delete`) destroys the SQLite files — this is irreversible and is the last copy of the pre-migration state outside the NFS archives.
- [ ] Remove the now-stale `local-path`/SQLite references from `apps/cleanuparr/config-pvc-nfs.yaml` comments if they still point at the deleted file.
- [ ] Update the `project_cleanuparr_deployed_unconfigured` premise if it still describes SQLite storage.

## Out of scope

- The four arrs and Bazarr. Same destination, but an unsupported migration path — decide separately once this one has proven the pattern.
- Jellyfin and Navidrome. Neither supports Postgres; they stay on `local-path` regardless.
- Longhorn. If this plan plus the arrs lands, Navidrome is the only app left pinned against its will, which is not enough to justify a new storage layer.
- The NAS migration (`docs/nas-migration-checklist.md`). Independent — but note Task 7's backup PVC uses the `nfs` StorageClass, so it follows the NAS automatically.
