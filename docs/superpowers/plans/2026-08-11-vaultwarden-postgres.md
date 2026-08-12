# Vaultwarden SQLite → Postgres Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Vaultwarden's database from SQLite on a node-pinned `local-path` volume into a CloudNativePG Postgres cluster, and return `/data` to `nfs` RWX, so the pod can schedule on any node.

**Architecture:** A 3-instance CNPG cluster on `local-path` (durability from streaming replication plus a nightly `pg_dump`, not from the volume). The app reads `DATABASE_URL` straight from the CNPG-generated secret. `/data` keeps only `rsa_key.pem`, `config.json`, `attachments/`, `sends/`, `icon_cache/` and `tmp/`, which are safe on NFS now that no SQLite lives there. The one-time transfer is pgloader, run from a hand-applied Job while the Deployment is held at `replicas: 0` **in git**.

**Tech Stack:** k3s, ArgoCD (auto-sync, `prune: true`, `selfHeal: true`), CloudNativePG, bjw-s `app-template` 5.0.1, pgloader 3.6.x, `vaultwarden/server:1.37.1`, PostgreSQL 18.

**Spec:** `docs/superpowers/specs/2026-08-11-vaultwarden-postgres-design.md`

## Global Constraints

- **Merge to `main` = deploy.** ArgoCD auto-syncs. Verify in-cluster before merging anything, and use one branch per logical change.
- **Never `kubectl apply` a manifest that lives in git.** `selfHeal: true` will fight you. The only hand-applied object in this plan is the migration Job, which is deliberately *not* committed.
- **Never `kubectl scale`.** Same reason. Replica count changes are commits.
- **No `sleep`, anywhere, ever** — not in scripts, not in manifests, not in poll loops. Use `kubectl wait --timeout`, `curl --retry`, or readiness probes.
- **`data-pvc.yaml` must stay in git and unmodified** until Task 10. `local-path` is `reclaimPolicy: Delete`; the moment that file leaves git, ArgoCD prunes the PVC and the provisioner deletes the SQLite database behind it — which is the rollback.
- **CronJob name stays `vaultwarden-db-backup`.** `BackupCronJobMissing` counts CronJobs matching `.+-db-backup` and expects **6**.
- **Never add `Co-Authored-By` trailers**, and never reference Claude or Anthropic in a commit message.
- Namespace is `vaultwarden`; NFS server is `192.168.30.194`, share `/mnt/storage`.
- Expected source row counts, used by every verification step:
  `users=2 ciphers=805 devices=6 archives=28 folders_ciphers=15 folders=1 invitations=1`, everything else `0`. Postgres `__diesel_schema_migrations` must be **46** (SQLite's is 56 and must never be imported).

## File Structure

| File | Responsibility |
|---|---|
| `apps/vaultwarden/postgres.yaml` | **new.** CNPG `Cluster` + `Database`. Task 1. |
| `apps/vaultwarden/data-pvc-nfs.yaml` | **new.** `vaultwarden-data`, `nfs` RWX 5Gi — the claim that removes the node pin. Task 3. |
| `apps/vaultwarden/pg-backup.yaml` | **new.** Backup PVC + `pg_dump`-and-tar CronJob. Task 4. |
| `apps/vaultwarden/backup-cronjob.yaml` | **deleted** in Task 4, replaced by the above. |
| `apps/vaultwarden/values.yaml` | `DATABASE_URL`, `/data` → new claim, `replicas: 0`. Task 5; flipped to `1` in Task 8. |
| `apps/vaultwarden/data-pvc.yaml` | untouched until Task 10. The rollback. |
| `apps/vaultwarden/app.yaml`, `limitrange.yaml`, `vpa.yaml`, `infisical-secret.yaml` | unchanged throughout. |
| `$VWMIG/migrate-job.yaml` (outside the repo) | **never committed.** The three-container migration Job. Task 7. |

---

### Task 1: Stand up the CNPG cluster

Adds a database and nothing else. The app is untouched, so this task cannot break Vaultwarden.

**Files:**
- Create: `apps/vaultwarden/postgres.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: Service `vaultwarden-database-rw` on port 5432; Secret `vaultwarden-database-app` with keys `username`, `password`, `uri`, where `uri` is `postgresql://app:<password>@vaultwarden-database-rw.vaultwarden:5432/app`. Tasks 4, 5 and 7 all depend on these exact names.

- [ ] **Step 1: Branch**

```bash
git checkout main && git pull
git checkout -b feat/vaultwarden-postgres-cluster
```

- [ ] **Step 2: Write `apps/vaultwarden/postgres.yaml`**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: vaultwarden-database
  namespace: vaultwarden
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie

  storage:
    # local-path per the CNPG exception in CLAUDE.md: streaming replication across the
    # three instances, not the volume, is what survives a node failure, and NFS is not a
    # supported CNPG configuration. local-path cannot be expanded in place, so 5Gi is
    # sized once -- against a 1.2M database whose attachments live on the /data volume
    # rather than in Postgres, that is already enormous headroom.
    size: 5Gi
    storageClass: local-path

  # Free: local-path already pins each instance to its node permanently.
  affinity:
    podAntiAffinityType: required

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      # No cpu limit on purpose -- see apps/vaultwarden/limitrange.yaml for the
      # VPA ratio-preservation throttling this avoids.
      memory: 1Gi
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: vaultwarden-database
  namespace: vaultwarden
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  name: app
  owner: app
  cluster:
    name: vaultwarden-database
```

- [ ] **Step 3: Render the chart to prove nothing else changed**

The point is to confirm this file is picked up as a raw manifest and does not collide with a chart-rendered object.

Run:
```bash
helm template vaultwarden app-template \
  --repo https://bjw-s-labs.github.io/helm-charts --version 5.0.1 \
  -f apps/vaultwarden/values.yaml -n vaultwarden | grep -c "kind: Cluster"
```
Expected: `0` — the CNPG Cluster comes from the raw manifest, not the chart.

- [ ] **Step 4: Commit and merge**

```bash
git add apps/vaultwarden/postgres.yaml
git commit -m "feat(vaultwarden): add a CloudNativePG cluster

Three instances on local-path, matching nextcloud, immich and infisical.
Nothing consumes it yet -- the app still runs on SQLite -- so this lands
on its own to keep the cutover diff small."
git push -u origin feat/vaultwarden-postgres-cluster
gh pr create --fill && gh pr merge --merge
```

- [ ] **Step 5: Verify the cluster is healthy before going further**

Run:
```bash
kubectl -n argocd patch app vaultwarden --type merge -p '{"operation":{"sync":{}}}' >/dev/null
kubectl -n vaultwarden wait --for=condition=Ready cluster/vaultwarden-database --timeout=600s
kubectl -n vaultwarden get cluster vaultwarden-database
kubectl -n vaultwarden get pods -l cnpg.io/podRole=instance -o wide
```
Expected: `3` instances, `3` ready, `Cluster in healthy state`, and one pod on each of worker-00, worker-01, worker-02.

- [ ] **Step 6: Verify the secret has the shape later tasks assume**

Run:
```bash
kubectl -n vaultwarden get secret vaultwarden-database-app \
  -o jsonpath='{.data.uri}' | base64 -d | sed -E 's#//([^:]+):[^@]+@#//\1:REDACTED@#'
```
Expected: exactly `postgresql://app:REDACTED@vaultwarden-database-rw.vaultwarden:5432/app`

**STOP.** If the host or database name differs, fix Tasks 4, 5 and 7 before continuing — they hardcode nothing, but the pgloader target is read from this key.

---

### Task 2: Take the pre-cutover backup

This archive is both the pgloader source and the rollback artifact. It **must** be taken before Task 4 merges, because that merge deletes the CronJob that produces it.

**Files:** none — this task is a cluster operation only.

**Interfaces:**
- Consumes: CronJob `vaultwarden-db-backup` (the SQLite version, still in git at this point).
- Produces: `/mnt/storage/backups/vaultwarden/vaultwarden-<stamp>.tar.gz` containing `data/db.sqlite3`, `data/rsa_key.pem` and any other non-excluded `/data` files. Task 7 reads the newest such file.

- [ ] **Step 1: Trigger the existing backup job**

```bash
kubectl -n vaultwarden create job vw-precutover --from=cronjob/vaultwarden-db-backup
kubectl -n vaultwarden wait --for=condition=complete job/vw-precutover --timeout=300s
kubectl -n vaultwarden logs job/vw-precutover
```

- [ ] **Step 2: Verify the snapshot is real, not empty**

Expected in the log, exactly:
```
snapshot: 2 users, 805 ciphers
wrote /backups/vaultwarden-<stamp>.tar.gz (<bytes> bytes)
```

**STOP** if the counts differ from `2 users, 805 ciphers`. That means the source database changed since 2026-08-11 and every expected count in this plan needs re-baselining first — re-read them and update the Global Constraints section before continuing.

- [ ] **Step 3: Record the archive name**

```bash
kubectl -n vaultwarden logs job/vw-precutover | grep '^wrote '
```
Write the filename down. It is the rollback artifact; if anything later goes wrong, this is what gets restored.

- [ ] **Step 4: Clean up the job object**

```bash
kubectl -n vaultwarden delete job vw-precutover
```

---

### Task 3: Add the NFS data claim

A new, empty claim, added alongside the existing `local-path` one. Nothing consumes it yet.

**Files:**
- Create: `apps/vaultwarden/data-pvc-nfs.yaml`

**Interfaces:**
- Produces: PVC `vaultwarden-data`, `nfs`, `ReadWriteMany`, 5Gi. Tasks 5 and 7 mount it by this name.

- [ ] **Step 1: Branch**

```bash
git checkout main && git pull
git checkout -b feat/vaultwarden-postgres-cutover
```

- [ ] **Step 2: Write `apps/vaultwarden/data-pvc-nfs.yaml`**

```yaml
# Replaces vaultwarden-data-local. /data is safe on nfs again because the only reason it
# was ever on local-path -- db.sqlite3 in WAL mode, which SQLite does not support on a
# network filesystem -- has moved into Postgres. What is left is read-once or write-once:
# rsa_key.pem is generated at first boot and never rewritten, config.json is written by
# the /admin panel, and attachments/ and sends/ are created and deleted but never edited
# in place.
#
# RWX and nfs are the point of the whole migration: they are what let the pod schedule on
# any node instead of following a local-path PV's node affinity to worker-00.
#
# Recovery: the vaultwarden-db-backup CronJob tars this volume nightly to
# /mnt/storage/backups/vaultwarden alongside the pg_dump. Restoring rsa_key.pem matters --
# without it every existing session token is invalid and all clients must log in again,
# though no vault data is lost.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data
  namespace: vaultwarden
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 3: Confirm you did not touch the old claim**

Run:
```bash
git status --short apps/vaultwarden/
```
Expected: `?? apps/vaultwarden/data-pvc-nfs.yaml` and **nothing** for `data-pvc.yaml`. If `data-pvc.yaml` appears as modified or deleted, revert it — see Global Constraints.

- [ ] **Step 4: Commit (do not merge yet — Tasks 4 and 5 ride the same branch)**

```bash
git add apps/vaultwarden/data-pvc-nfs.yaml
git commit -m "feat(vaultwarden): add the nfs data claim that unpins the pod"
```

---

### Task 4: Replace the SQLite backup with a Postgres one

**Files:**
- Create: `apps/vaultwarden/pg-backup.yaml`
- Delete: `apps/vaultwarden/backup-cronjob.yaml`

**Interfaces:**
- Consumes: `vaultwarden-database-rw` and secret `vaultwarden-database-app` (Task 1); PVC `vaultwarden-data` (Task 3).
- Produces: CronJob `vaultwarden-db-backup` — the name is load-bearing for the `BackupCronJobMissing` alert — writing `vaultwarden-<stamp>.dump` and `vaultwarden-files-<stamp>.tar.gz` to a `vaultwarden-db-backup` NFS PVC.

- [ ] **Step 1: Write `apps/vaultwarden/pg-backup.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-db-backup
  namespace: vaultwarden
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs
  resources:
    requests:
      storage: 5Gi
---
# Two halves, one job. pg_dump covers the vault; the tar covers rsa_key.pem, config.json,
# attachments/ and sends/, which now live only on the nfs /data volume. Losing
# rsa_key.pem invalidates every session token, so a database-only backup would not be a
# backup of this app.
#
# The tar runs against a live /data with Vaultwarden serving, which is safe ONLY because
# every file under it is write-once: rsa_key.pem is never rewritten, and attachments and
# sends are created and deleted but not edited in place. There is no torn-read risk of the
# kind that forced the old SQLite job to use the online backup API. Do not copy this to an
# app that mutates files in place.
apiVersion: batch/v1
kind: CronJob
metadata:
  # Name must keep the -db-backup suffix: BackupCronJobMissing in
  # system/monitoring-system/prometheusrule-backups.yaml counts CronJobs matching
  # ".+-db-backup" and expects six of them.
  name: vaultwarden-db-backup
  namespace: vaultwarden
spec:
  schedule: "30 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            # Alloy derives the Loki `app` stream label from this; without it these pods
            # fall back to the namespace and land in Vaultwarden's main log stream.
            app.kubernetes.io/name: vaultwarden-db-backup
        spec:
          restartPolicy: OnFailure
          securityContext:
            # Vaultwarden runs as root and its /data files are root-owned.
            runAsUser: 0
            runAsGroup: 0
          containers:
            - name: pg-dump
              image: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
              env:
                - name: PGHOST
                  value: vaultwarden-database-rw
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: vaultwarden-database-app
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: vaultwarden-database-app
                      key: password
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  stamp="$(date +%Y%m%d-%H%M%S)"

                  # A vault with no ciphers is a restore that loses everything, and it
                  # looks identical to a healthy small dump. Count before writing.
                  users="$(psql -d app -Atc 'select count(*) from users')"
                  ciphers="$(psql -d app -Atc 'select count(*) from ciphers')"
                  echo "snapshot: ${users} users, ${ciphers} ciphers"
                  if [ "$users" -eq 0 ]; then
                    echo "0 users -- refusing to write a backup" >&2
                    exit 1
                  fi

                  # Write under a temp name on the same filesystem and rename only once
                  # complete, so a pod killed mid-write cannot leave a truncated file at
                  # the exact name the restore path reaches for.
                  out="/backup/vaultwarden-${stamp}.dump"
                  pg_dump -d app -Fc -f "${out}.tmp"
                  mv "${out}.tmp" "$out"
                  echo "wrote $out ($(stat -c %s "$out") bytes)"

                  # icon_cache is refetched from the web on demand and tmp is scratch.
                  # Everything else is either config or the key that signs access to the
                  # vault. Exclusions rather than a list of names, so attachments/ and
                  # sends/ are picked up automatically once they first appear.
                  files="/backup/vaultwarden-files-${stamp}.tar.gz"
                  tar -czf "${files}.tmp" -C /data \
                    --exclude=icon_cache --exclude=tmp --exclude=.migrated-from-nfs .
                  mv "${files}.tmp" "$files"
                  echo "wrote $files ($(stat -c %s "$files") bytes)"

                  # 14 days, not the 7 used by immich and nextcloud: this is the password
                  # manager, and the archives are ~500K.
                  find /backup -name 'vaultwarden-*.dump' -mtime +14 -delete
                  find /backup -name 'vaultwarden-files-*.tar.gz' -mtime +14 -delete
                  echo "retained: $(ls -1 /backup/vaultwarden-*.dump | wc -l) dumps"
              volumeMounts:
                - name: backup
                  mountPath: /backup
                - name: data
                  mountPath: /data
                  readOnly: true
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  memory: 512Mi
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: vaultwarden-db-backup
            - name: data
              persistentVolumeClaim:
                claimName: vaultwarden-data
```

- [ ] **Step 2: Delete the SQLite backup job**

```bash
git rm apps/vaultwarden/backup-cronjob.yaml
```

- [ ] **Step 3: Confirm the alert's expected count still holds**

Run:
```bash
grep -n '< 6' system/monitoring-system/prometheusrule-backups.yaml
grep -n 'name: vaultwarden-db-backup' apps/vaultwarden/pg-backup.yaml
```
Expected: the alert threshold still reads `< 6`, and `pg-backup.yaml` declares a CronJob named exactly `vaultwarden-db-backup`. Because the name is reused, the rule needs **no** edit. If you renamed the CronJob, stop and rename it back — editing the alert instead means editing a `critical` rule to match a mistake.

- [ ] **Step 4: Commit**

```bash
git add apps/vaultwarden/pg-backup.yaml apps/vaultwarden/backup-cronjob.yaml
git commit -m "feat(vaultwarden): back up Postgres and /data instead of SQLite

Keeps the vaultwarden-db-backup name so BackupCronJobMissing still counts
six. Retention stays at 14 days rather than dropping to the 7 that immich
and nextcloud use, and the job tars /data alongside the dump because
pg_dump does not cover rsa_key.pem -- losing it invalidates every session
token."
```

---

### Task 5: Point the app at Postgres, held at zero replicas

The cutover commit. After this merges, Vaultwarden is **down** until Task 8.

**Files:**
- Modify: `apps/vaultwarden/values.yaml`

**Interfaces:**
- Consumes: secret `vaultwarden-database-app` key `uri` (Task 1); PVC `vaultwarden-data` (Task 3).
- Produces: a Deployment at `replicas: 0` whose pod template mounts `/data` from `vaultwarden-data` and reads `DATABASE_URL` from the CNPG secret.

- [ ] **Step 1: Edit the `controllers.main` block**

Replace the existing `strategy: Recreate` line and its comment with:

```yaml
controllers:
  main:
    # Held at zero for the SQLite -> Postgres migration. Task 8 of
    # docs/superpowers/plans/2026-08-11-vaultwarden-postgres.md sets this back to 1.
    # Shutdown lives in git rather than in a kubectl scale because ArgoCD runs selfHeal
    # and would restart the pod mid-import, on top of a half-loaded database with
    # pgloader still recreating its foreign keys.
    replicas: 0
    # Not required any more now that the database is Postgres and /data is RWX, but a
    # single writer against rsa_key.pem and icon_cache/ is one less thing to reason
    # about, and zero-downtime restarts are not a goal here.
    strategy: Recreate
```

- [ ] **Step 2: Add `DATABASE_URL` to the container env**

In `controllers.main.containers.app.env`, directly above `ADMIN_TOKEN`:

```yaml
          # CloudNativePG generates this secret and its `uri` key is already in exactly
          # the shape Vaultwarden wants: postgresql://app:<password>@<rw-service>:5432/app.
          # Nothing to commit, nothing to seal, and no rotation to wire up -- which is why
          # this one credential does not come from Infisical like ADMIN_TOKEN does.
          DATABASE_URL:
            valueFrom:
              secretKeyRef:
                name: vaultwarden-database-app
                key: uri
```

- [ ] **Step 3: Repoint the persistence block**

Replace the whole `persistence:` block with:

```yaml
persistence:
  data:
    # nfs, not local-path: db.sqlite3 has moved into Postgres, so nothing here needs a
    # local filesystem any more, and RWX is what lets this pod schedule on any node.
    # See data-pvc-nfs.yaml for the rationale and the restore path.
    existingClaim: vaultwarden-data
    globalMounts:
      - path: /data
```

- [ ] **Step 4: Render the chart and check all three changes landed**

Run:
```bash
helm template vaultwarden app-template \
  --repo https://bjw-s-labs.github.io/helm-charts --version 5.0.1 \
  -f apps/vaultwarden/values.yaml -n vaultwarden > /tmp/vw-rendered.yaml
grep -E "replicas:|claimName:|secretKeyRef|key: uri|name: DATABASE_URL" /tmp/vw-rendered.yaml
```
Expected: `replicas: 0`, `claimName: vaultwarden-data`, and a `DATABASE_URL` env entry sourced from `vaultwarden-database-app` key `uri`. There must be **no** reference to `vaultwarden-data-local` anywhere in the rendered output.

- [ ] **Step 5: Confirm no duplicate top-level keys crept in**

A duplicated top-level key in these values silently wins and has eaten an HTTPRoute in this repo before.

Run:
```bash
python3 -c "
import sys,yaml
class D(yaml.SafeLoader): pass
def nodup(loader,node,deep=False):
    keys=[loader.construct_object(k,deep=deep) for k,_ in node.value]
    dupes=[k for k in set(keys) if keys.count(k)>1]
    if dupes: sys.exit(f'DUPLICATE KEYS: {dupes}')
    return yaml.SafeLoader.construct_mapping(loader,node,deep)
D.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,nodup)
yaml.load(open('apps/vaultwarden/values.yaml'),D); print('no duplicate keys')
"
```
Expected: `no duplicate keys`

- [ ] **Step 6: Commit and merge the whole cutover branch**

```bash
git add apps/vaultwarden/values.yaml
git commit -m "feat(vaultwarden): move the database to Postgres and /data back to nfs

SQLite on a local-path volume is what pinned this pod to worker-00.
Postgres alone would not have changed that -- returning /data to the nfs
RWX claim is what actually removes the pin, and it is only safe now that
no SQLite lives on that volume.

Lands at replicas: 0. The migration Job runs against the stopped app and
a follow-up commit starts it."
git push -u origin feat/vaultwarden-postgres-cutover
gh pr create --fill && gh pr merge --merge
```

- [ ] **Step 7: Verify the app is stopped and the new claim is bound**

Run:
```bash
kubectl -n argocd patch app vaultwarden --type merge -p '{"operation":{"sync":{}}}' >/dev/null
kubectl -n vaultwarden wait --for=jsonpath='{.status.phase}'=Bound pvc/vaultwarden-data --timeout=120s
kubectl -n vaultwarden get deploy vaultwarden -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n vaultwarden get pods
kubectl -n vaultwarden get pvc
```
Expected: `0` replicas, no `vaultwarden-*` app pod, `vaultwarden-data` **Bound**, and `vaultwarden-data-local` **still present and Bound** — if it is gone, `data-pvc.yaml` was removed from git and the rollback is destroyed. Stop and restore from the Task 2 archive.

---

### Task 6: Confirm the new /data volume is empty and the database has no schema

A ten-second check that catches the two states which would make Task 7 silently wrong: a pre-populated `/data`, or a database someone already migrated.

**Files:** none.

- [ ] **Step 1: Check both**

```bash
kubectl -n vaultwarden run vw-check --rm -i --restart=Never --image=busybox:1.38.0 \
  --overrides='{"spec":{"containers":[{"name":"vw-check","image":"busybox:1.38.0","command":["ls","-la","/data"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"vaultwarden-data"}}]}}'

kubectl -n vaultwarden exec vaultwarden-database-1 -c postgres -- \
  psql -U postgres -d app -Atc \
  "select count(*) from information_schema.tables where table_schema='public'"
```
Expected: an empty `/data` (only `.` and `..`), and `0` tables.

**STOP** if either is non-empty. A non-empty `/data` means something already wrote there; a non-zero table count means the schema exists and Task 7's `schema` container will be a no-op while `pgloader` may import into a database that already has rows.

---

### Task 7: Run the migration

The only hand-applied object in this plan. It is **not** committed: ArgoCD applies whatever is in git, and a Job in git turns a deliberate one-time migration into something that runs on merge.

Three containers, in order, all against a stopped app.

**Files:**
- Create (outside the repo, **never** `git add`): `$VWMIG/migrate-job.yaml`

**Interfaces:**
- Consumes: the Task 2 archive on the NFS share; PVC `vaultwarden-data` (Task 3); secret `vaultwarden-database-app` key `uri` (Task 1).
- Produces: a populated `public` schema in database `app`, and a seeded `/data` containing `rsa_key.pem`.

- [ ] **Step 1: Write the Job to a path outside the repo**

```bash
export VWMIG="$(mktemp -d)" && echo "writing to $VWMIG/migrate-job.yaml"
```

Write the following to `$VWMIG/migrate-job.yaml`. Anywhere outside the working tree is fine
— what matters is that it never lands under `apps/`.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vaultwarden-sqlite-to-pg
  namespace: vaultwarden
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      initContainers:
        # 1/3 -- seed /data from the pre-cutover archive and stage the database for
        # pgloader. rsa_key.pem must be in place BEFORE the schema container boots
        # Vaultwarden, or Vaultwarden generates a fresh one and every existing session
        # token is invalidated.
        - name: seed
          image: python:3.13-alpine
          command:
            - python
            - -c
            - |
              import glob, json, os, shutil, sqlite3, sys, tarfile

              archives = sorted(glob.glob("/backups/vaultwarden-*.tar.gz"))
              if not archives:
                  sys.exit("no archive in /backups -- run the pre-cutover backup first")
              src = archives[-1]
              print(f"source archive: {src}")
              with tarfile.open(src) as t:
                  t.extractall("/staging", filter="data")

              extracted = "/staging/data"
              # icon_cache is refetched on demand, tmp is scratch, db.sqlite3* is the
              # thing being replaced, and .migrated-from-nfs belongs to the previous
              # migration. Everything else -- rsa_key.pem above all -- comes across.
              skip = {"icon_cache", "tmp", ".migrated-from-nfs"}
              for name in sorted(os.listdir(extracted)):
                  if name in skip or name.startswith("db.sqlite3"):
                      continue
                  s, d = os.path.join(extracted, name), os.path.join("/data", name)
                  print(f"seeding {name}")
                  (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, d)

              if not os.path.exists("/data/rsa_key.pem"):
                  sys.exit("rsa_key.pem did not make it into /data -- refusing to continue")

              db = "/work/db.sqlite3"
              # shutil.move, not os.rename: /staging and /work are separate emptyDir
              # volumes, so a rename across them fails with EXDEV.
              shutil.move(os.path.join(extracted, "db.sqlite3"), db)
              c = sqlite3.connect(db)
              # pgloader cannot read a WAL database; the online-backup snapshot carries
              # the source journal mode across, so reset it on the copy.
              print("journal_mode ->", c.execute("pragma journal_mode=delete").fetchone()[0])
              tables = [r[0] for r in c.execute(
                  "select name from sqlite_master where type='table' "
                  "and name not like 'sqlite_%' order by 1")]
              counts = {t: c.execute(f'select count(*) from "{t}"').fetchone()[0] for t in tables}
              c.close()
              if counts.get("users", 0) == 0:
                  sys.exit("source has 0 users -- refusing to migrate an empty vault")
              print(json.dumps(counts, indent=2, sort_keys=True))
          volumeMounts:
            - {name: work, mountPath: /work}
            - {name: staging, mountPath: /staging}
            - {name: data, mountPath: /data}
            - {name: backups, mountPath: /backups, readOnly: true}
        # 2/3 -- let Vaultwarden build its own schema. Diesel migrations are per-backend,
        # so the Postgres schema has to come from Vaultwarden itself; rows cannot land
        # first. /alive answering means migrations are done and Rocket is up, at which
        # point this container has served its purpose.
        - name: schema
          image: vaultwarden/server:1.37.1
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              /vaultwarden &
              vw=$!
              # --retry, not a poll loop: sleep is banned repo-wide. 60 attempts at 2s
              # is a two-minute ceiling on a boot that takes about one second.
              curl -sf --retry 60 --retry-delay 2 --retry-connrefused \
                -o /dev/null http://localhost/alive
              echo "vaultwarden answered /alive -- schema is built"
              kill -TERM "$vw"
              wait "$vw" 2>/dev/null || true
              echo "vaultwarden stopped"
          env:
            - name: DOMAIN
              value: "https://vault.nik-homelab.dev"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: {name: vaultwarden-database-app, key: uri}
          volumeMounts:
            - {name: data, mountPath: /data}
      containers:
        # 3/3 -- the import. Exactly the command smoke-tested against PG 18 on
        # 2026-08-11: 0 errors, 858 rows, 34 foreign keys recreated.
        - name: pgloader
          image: dimitri/pgloader:latest
          env:
            - name: PGURI
              valueFrom:
                secretKeyRef: {name: vaultwarden-database-app, key: uri}
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              # EXCLUDING the diesel table is not optional: SQLite's migration set has 56
              # rows and Postgres's has 46, and importing one over the other produces
              # duplicate keys that stop Vaultwarden from starting.
              cat > /work/vw.load <<EOF
              load database
                   from sqlite:///work/db.sqlite3
                   into ${PGURI}
                   WITH data only, include no drop, reset sequences
                   EXCLUDING TABLE NAMES LIKE '__diesel_schema_migrations'
              ;
              EOF
              sed -E 's#//([^:]+):[^@]+@#//\1:REDACTED@#' /work/vw.load
              pgloader --verbose /work/vw.load
          volumeMounts:
            - {name: work, mountPath: /work}
      volumes:
        - name: work
          emptyDir: {}
        - name: staging
          emptyDir: {}
        - name: data
          persistentVolumeClaim:
            claimName: vaultwarden-data
        - name: backups
          nfs:
            server: 192.168.30.194
            path: /mnt/storage/backups/vaultwarden
```

- [ ] **Step 2: Confirm it is not in the repo**

Run:
```bash
git status --short
```
Expected: no `migrate-job.yaml` anywhere in the output. If it is there, move it out of the working tree — committing it hands a one-time migration to ArgoCD, which will reapply it on every sync.

- [ ] **Step 3: Apply and wait**

```bash
kubectl apply -f "$VWMIG/migrate-job.yaml"
kubectl -n vaultwarden wait --for=condition=complete job/vaultwarden-sqlite-to-pg --timeout=600s \
  || kubectl -n vaultwarden wait --for=condition=failed job/vaultwarden-sqlite-to-pg --timeout=10s
```

- [ ] **Step 4: Read all three container logs**

```bash
kubectl -n vaultwarden logs job/vaultwarden-sqlite-to-pg -c seed
kubectl -n vaultwarden logs job/vaultwarden-sqlite-to-pg -c schema
kubectl -n vaultwarden logs job/vaultwarden-sqlite-to-pg -c pgloader | tail -45
```

Expected, in order:
- `seed`: `seeding rsa_key.pem`, `journal_mode -> delete`, and a counts block showing `"users": 2` and `"ciphers": 805`.
- `schema`: `vaultwarden answered /alive -- schema is built`, then `vaultwarden stopped`.
- `pgloader`: a summary table ending `Total import time  ✓  858  858`, with **`0` in every `errors` column**.

**STOP** on any non-zero error count. Recovery is in the Rollback section below — the SQLite database is untouched and the Task 2 archive is intact, so nothing is lost.

- [ ] **Step 5: Verify the row counts in Postgres directly**

```bash
for t in users ciphers devices archives folders folders_ciphers invitations __diesel_schema_migrations; do
  printf '%-28s %s\n' "$t" "$(kubectl -n vaultwarden exec vaultwarden-database-1 -c postgres -- \
    psql -U postgres -d app -Atc "select count(*) from \"$t\"")"
done
```
Expected, exactly:
```
users                        2
ciphers                      805
devices                      6
archives                     28
folders                      1
folders_ciphers              15
invitations                  1
__diesel_schema_migrations   46
```

`__diesel_schema_migrations` must be **46**, not 56. 56 means SQLite's migration table was imported and Vaultwarden will refuse to start.

- [ ] **Step 6: Verify replication caught up before starting the app**

```bash
kubectl -n vaultwarden get cluster vaultwarden-database
```
Expected: `3` ready, `Cluster in healthy state`. The import wrote ~850 rows to the primary; the replicas are what make this survive a node failure, so confirm they are in sync rather than assuming.

- [ ] **Step 7: Leave the Job in place for now**

Do not delete it until Task 8 passes — its logs are the record of what happened.

---

### Task 8: Start Vaultwarden and verify

**Files:**
- Modify: `apps/vaultwarden/values.yaml` (one line)

- [ ] **Step 1: Branch and flip replicas**

```bash
git checkout main && git pull
git checkout -b feat/vaultwarden-postgres-start
```

In `apps/vaultwarden/values.yaml`, change `replicas: 0` to `replicas: 1` and replace the "Held at zero" comment with:

```yaml
    # Single writer against rsa_key.pem and icon_cache/. Not strictly required now that
    # the database is Postgres and /data is RWX, but zero-downtime restarts are not a
    # goal and one pod is one less thing to reason about.
    replicas: 1
```

- [ ] **Step 2: Commit and merge**

```bash
git add apps/vaultwarden/values.yaml
git commit -m "feat(vaultwarden): start on Postgres

Migration verified: 858 rows imported with no errors and per-table counts
matching the SQLite source."
git push -u origin feat/vaultwarden-postgres-start
gh pr create --fill && gh pr merge --merge
```

- [ ] **Step 3: Wait for the pod**

```bash
kubectl -n argocd patch app vaultwarden --type merge -p '{"operation":{"sync":{}}}' >/dev/null
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=300s
kubectl -n vaultwarden logs deploy/vaultwarden | tail -20
```
Expected: `Rocket has launched from http://0.0.0.0:80` and **no** `Private key 'data/rsa_key.pem' created correctly` — that line appearing means the seeded key was missed and every session token is now invalid.

- [ ] **Step 4: Verify the app reads migrated data**

```bash
EMAIL=$(kubectl -n vaultwarden exec vaultwarden-database-1 -c postgres -- \
  psql -U postgres -d app -Atc "select email from users limit 1")
kubectl -n vaultwarden exec deploy/vaultwarden -- sh -c \
  "curl -s -X POST http://localhost/identity/accounts/prelogin \
   -H 'Content-Type: application/json' -d '{\"email\":\"$EMAIL\"}'"
```
Expected: JSON with a real `kdfIterations` (600000 on the 2026-08-11 baseline), not a default or an error.

- [ ] **Step 5: Verify the app WRITES — the gap the smoke test left**

The 2026-08-11 smoke test only exercised reads. Do this by hand in the browser at `https://vault.nik-homelab.dev`:

1. Log in. **It must not ask you to re-authenticate from scratch** — a surviving session is the observable proof `rsa_key.pem` came across intact.
2. Confirm the vault shows **805 items** and your one folder.
3. Create a new login item called `migration-canary`.
4. Run `kubectl -n vaultwarden delete pod -l app.kubernetes.io/name=vaultwarden` and wait for the new pod.
5. Reload. `migration-canary` must still be there — that proves the write reached Postgres and not a container filesystem.
6. Delete `migration-canary`.
7. Confirm the count is back to 805:
   ```bash
   kubectl -n vaultwarden exec vaultwarden-database-1 -c postgres -- \
     psql -U postgres -d app -Atc "select count(*) from ciphers"
   ```

- [ ] **Step 6: Verify a full client sync on a second device**

Open the phone client and force a sync. All 805 items present, no re-login prompt.

- [ ] **Step 7: Prove the node pin is actually gone**

This is the goal of the entire project, stated as a check. Everything else could pass while the pod is still stuck on worker-00.

```bash
NODE=$(kubectl -n vaultwarden get pod -l app.kubernetes.io/name=vaultwarden \
  -o jsonpath='{.items[0].spec.nodeName}')
echo "currently on: $NODE"
kubectl cordon "$NODE"
kubectl -n vaultwarden delete pod -l app.kubernetes.io/name=vaultwarden
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=300s
kubectl -n vaultwarden get pod -l app.kubernetes.io/name=vaultwarden -o wide
kubectl uncordon "$NODE"
```
Expected: the new pod is **Running on a different node**. If it is Pending with a volume node-affinity conflict, `/data` is still on `local-path` and the migration did not achieve its goal.

`kubectl uncordon` must run even if the step fails — a cordoned node left behind will quietly starve the scheduler later.

- [ ] **Step 8: Confirm no SQLite came along**

```bash
kubectl -n vaultwarden exec deploy/vaultwarden -- ls -la /data
```
Expected: `rsa_key.pem` present; **no** `db.sqlite3`, `db.sqlite3-wal` or `db.sqlite3-shm`.

- [ ] **Step 9: Trigger the new backup job immediately**

Deleting the old CronJob and creating a new one makes `kube_cronjob_status_last_successful_time` vanish for `vaultwarden-db-backup` until the new one first succeeds. The count drops to 5 and `BackupCronJobMissing` fires after an hour.

```bash
kubectl -n vaultwarden create job vw-firstbackup --from=cronjob/vaultwarden-db-backup
kubectl -n vaultwarden wait --for=condition=complete job/vw-firstbackup --timeout=300s
kubectl -n vaultwarden logs job/vw-firstbackup
kubectl get cronjob -A | grep -c db-backup
```
Expected: `snapshot: 2 users, 805 ciphers`, two `wrote ...` lines (a `.dump` and a `-files-*.tar.gz`), and a CronJob count of **6**.

- [ ] **Step 10: Clean up the migration objects**

```bash
kubectl -n vaultwarden delete job vaultwarden-sqlite-to-pg vw-firstbackup
```

---

### Task 9: Restore drill

Part of the deliverable, not a follow-up. This is the password manager; an unverified restore path is not a restore path. Uses the same harness that smoke-tested pgloader on 2026-08-11.

**Files:** none — throwaway namespace only.

- [ ] **Step 1: Create a throwaway namespace and a one-instance cluster**

```bash
kubectl create ns vw-restore-test
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: vwrestore
  namespace: vw-restore-test
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
  storage:
    size: 2Gi
    storageClass: local-path
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 1Gi}
EOF
kubectl -n vw-restore-test wait --for=condition=Ready cluster/vwrestore --timeout=300s
```

- [ ] **Step 2: Restore the dump written in Task 8 Step 9**

```bash
kubectl -n vw-restore-test delete pod vw-restore --ignore-not-found
kubectl -n vw-restore-test run vw-restore -i --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:18-standard-trixie \
  --overrides='{"spec":{"containers":[{"name":"vw-restore","image":"ghcr.io/cloudnative-pg/postgresql:18-standard-trixie","command":["/bin/bash","-c","set -euo pipefail; d=$(ls -1t /backup/vaultwarden-*.dump | head -1); echo restoring $d; pg_restore -d \"$PGURI\" --no-owner --role=app \"$d\"; echo restored"],"env":[{"name":"PGURI","valueFrom":{"secretKeyRef":{"name":"vwrestore-app","key":"uri"}}}],"volumeMounts":[{"name":"b","mountPath":"/backup"}]}],"restartPolicy":"Never","volumes":[{"name":"b","nfs":{"server":"192.168.30.194","path":"/mnt/storage/backups/vaultwarden"}}]}}'
```

The backup PVC provisions its own subdirectory under the share; if the dump is not visible at that path, find it with
`kubectl -n vaultwarden get pv | grep vaultwarden-db-backup` and use the reported subdirectory.

- [ ] **Step 3: Verify the restored counts**

```bash
for t in users ciphers devices archives; do
  printf '%-12s %s\n' "$t" "$(kubectl -n vw-restore-test exec vwrestore-1 -c postgres -- \
    psql -U postgres -d app -Atc "select count(*) from \"$t\"")"
done
```
Expected: `users 2`, `ciphers 805`, `devices 6`, `archives 28`.

- [ ] **Step 4: Boot Vaultwarden against the restored database**

```bash
kubectl -n vw-restore-test run vw-app --restart=Never --image=vaultwarden/server:1.37.1 \
  --overrides='{"spec":{"containers":[{"name":"vw-app","image":"vaultwarden/server:1.37.1","env":[{"name":"DOMAIN","value":"https://vwrestore.invalid"},{"name":"DATABASE_URL","valueFrom":{"secretKeyRef":{"name":"vwrestore-app","key":"uri"}}}],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","emptyDir":{}}]}}'
kubectl -n vw-restore-test wait --for=condition=Ready pod/vw-app --timeout=180s
EMAIL=$(kubectl -n vw-restore-test exec vwrestore-1 -c postgres -- \
  psql -U postgres -d app -Atc "select email from users limit 1")
kubectl -n vw-restore-test exec vw-app -- sh -c \
  "curl -s -X POST http://localhost/identity/accounts/prelogin \
   -H 'Content-Type: application/json' -d '{\"email\":\"$EMAIL\"}'"
```
Expected: real KDF parameters in the response.

- [ ] **Step 5: Tear down and record the result**

```bash
kubectl delete ns vw-restore-test
```

Then add a dated line to the "Restore drill" section of the spec recording that it passed, and commit on a `docs/` branch.

---

### Task 10: Retire the SQLite volume — 14 days later, not before

**Do not run this task in the same session as Tasks 1–9.** Its whole purpose is to expire after the rollback window.

**Files:**
- Delete: `apps/vaultwarden/data-pvc.yaml`

- [ ] **Step 1: Confirm the rollback window has elapsed and Vaultwarden is healthy**

```bash
kubectl -n vaultwarden get pods -o wide
kubectl -n vaultwarden get cronjob vaultwarden-db-backup \
  -o jsonpath='{.status.lastSuccessfulTime}{"\n"}'
```
Expected: at least 14 days since the Task 8 merge, the app Running, and a recent successful backup.

- [ ] **Step 2: Delete the manifest**

```bash
git checkout main && git pull
git checkout -b chore/vaultwarden-drop-sqlite-volume
git rm apps/vaultwarden/data-pvc.yaml
git commit -m "chore(vaultwarden): drop the retired SQLite volume

local-path is reclaimPolicy Delete, so this commit destroys the pre-migration
SQLite database as ArgoCD prunes the claim. Deliberate, and 14 days after the
cutover -- the nightly pg_dump and /data tar have been the backup since then.
The pre-cutover archive under /mnt/storage/backups/vaultwarden is kept."
git push -u origin chore/vaultwarden-drop-sqlite-volume
gh pr create --fill && gh pr merge --merge
```

- [ ] **Step 3: Confirm the prune happened and the app is unaffected**

```bash
kubectl -n argocd patch app vaultwarden --type merge -p '{"operation":{"sync":{}}}' >/dev/null
kubectl -n vaultwarden get pvc
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=120s
```
Expected: `vaultwarden-data` and `vaultwarden-db-backup` remain; `vaultwarden-data-local` is gone; the app is untouched.

---

## Rollback

Valid at any point up to and including Task 9, because nothing in Tasks 1–8 writes to the SQLite database or its volume.

**If Task 7 fails (import errors, wrong counts):**

The app is already at `replicas: 0` and the vault is down, so there is no time pressure. Truncate and retry:

```bash
kubectl -n vaultwarden delete job vaultwarden-sqlite-to-pg
kubectl -n vaultwarden exec vaultwarden-database-1 -c postgres -- psql -U postgres -d app -c \
  "do \$\$ declare r record; begin
     for r in select tablename from pg_tables where schemaname='public'
              and tablename <> '__diesel_schema_migrations'
     loop execute 'truncate table '||quote_ident(r.tablename)||' cascade'; end loop;
   end \$\$;"
```
Then re-apply the Job. The `seed` container is idempotent apart from re-copying `/data`, which is harmless.

**If the migration must be abandoned entirely:**

```bash
git checkout main && git pull
git log --oneline --merges -5          # find the Task 8 and Task 5 merge commits
git revert --no-edit -m 1 <task-8-merge> <task-5-merge>
git push
```

`-m 1` is required: these are merge commits, and without it `git revert` cannot tell which
parent is mainline and refuses.
ArgoCD restores `existingClaim: vaultwarden-data-local` and `replicas: 1`, and Vaultwarden comes back on a SQLite database that is byte-for-byte what it was before Task 2 — nothing in this plan ever opened it for writing.

Leave `apps/vaultwarden/postgres.yaml` in place; an idle CNPG cluster costs three pods and breaks nothing, and reverting it as well only makes a retry more work.

**If the `local-path` volume is gone as well** (someone removed `data-pvc.yaml` early):

Restore from the Task 2 archive. Recreate the PVC from `data-pvc.yaml` at the reverted revision, set `replicas: 0`, extract `data/db.sqlite3` and `data/rsa_key.pem` from `/mnt/storage/backups/vaultwarden/vaultwarden-<stamp>.tar.gz` into the fresh volume, then set `replicas: 1`.

## What this plan does not do

- **No VPA on the CNPG cluster.** Matches nextcloud and immich. Revisit only if the pods show sustained throttling on the CronJobs dashboard.
- **`icon_cache/` stays on the shared NFS volume** rather than becoming an emptyDir. It is regenerable and small; a second volume earns nothing at this size.
- **No `attachments/` or `sends/` handling beyond the volume**, because neither directory exists yet — they are created the first time someone uploads, and land on the NFS claim automatically.
- **`dimitri/pgloader:latest` is unpinned.** Acceptable for a hand-applied one-shot run under observation. Record the digest from `kubectl -n vaultwarden describe job vaultwarden-sqlite-to-pg` in the spec when Task 7 runs, so a future retry can reproduce it.
