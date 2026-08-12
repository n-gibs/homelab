# Vaultwarden: SQLite → CloudNativePG Postgres

**Date:** 2026-08-11
**Status:** approved, not executed

## Goal

Let the Vaultwarden pod schedule on any node.

Today it cannot. `/data` is `vaultwarden-data-local`, a 5Gi `local-path` PVC whose PV
carries node affinity to worker-00, and the pod follows it. That volume is `local-path`
because it holds `db.sqlite3` in WAL mode, and SQLite over NFS does not work — the
constraint that forces the pin.

Moving the database into Postgres removes SQLite from `/data`, which lets `/data` go back
to `nfs` RWX, which is what actually removes the pin.

**Postgres alone does not achieve the goal.** If `/data` stays on `local-path` the pod
stays pinned and all this buys is three more pods. Retiring `vaultwarden-data-local` is
part of the change, not a follow-up.

## What is on disk today

Verified 2026-08-11 against the running pod:

```
/data
├── db.sqlite3          1167360   ← moves to Postgres
├── db.sqlite3-shm        32768   ← goes away
├── db.sqlite3-wal            0   ← goes away
├── .migrated-from-nfs        0   ← scaffolding from today's NFS→local-path move
├── rsa_key.pem            1679   ← must survive: losing it invalidates every session token
├── icon_cache/                   ← refetched from the web on demand
└── tmp/                          ← scratch
```

No `config.json` (admin config is env-only today), no `attachments/`, no `sends/` — those
directories appear the first time someone uploads. Row counts in the SQLite database:

| table | rows |
|---|---|
| `users` | 2 |
| `ciphers` | 805 |
| `devices` | 6 |
| `archives` | 28 |
| `folders_ciphers` | 15 |
| `folders` | 1 |
| `invitations` | 1 |
| everything else | 0 |

These are the numbers the post-migration verification compares against.

## Prior art in this repo

`apps/nextcloud/`, `apps/immich/` and `system/infisical/` each run a 3-instance CNPG cluster
on `local-path` with a `pg_dump` CronJob writing to the NFS share. This follows that
pattern rather than inventing one. The jellyfin and bazarr migrations earlier today
established the one-time-migration initContainer with a sentinel file written last, and
that pattern is reused here for seeding the new volume.

## Architecture

```
vaultwarden Deployment (replicas 1, strategy Recreate, no nodeSelector, no node pin)
├── DATABASE_URL ──► vaultwarden-database-rw   CNPG Cluster, 3 instances, local-path 5Gi
└── /data ─────────► vaultwarden-data          nfs, RWX, 5Gi
                       rsa_key.pem · config.json · attachments/ · sends/ · icon_cache/ · tmp/
```

`data-pvc.yaml` and the `vaultwarden-data-local` PVC are deleted.

### Where durability comes from

CNPG's own volumes are `local-path`, per the CNPG exception in CLAUDE.md — NFS is not a
supported CNPG configuration, and `local-path` pins each instance to its node permanently,
which is why `podAntiAffinityType: required` costs nothing.

So node-failure durability for the database comes from **streaming replication across three
instances**, not from the volume. Disk-failure durability comes from the nightly `pg_dump`
onto worker-01's USB disk, a different disk from the NVMe behind `local-path`.

`/data` on `nfs` is safe now only because no SQLite lives there. `rsa_key.pem` is read once
at boot; attachments and sends are plain file I/O with no locking requirements.

## Decisions

### 1. Migration mechanism: pgloader

Vaultwarden runs diesel migrations per backend, so the Postgres schema must be created by
Vaultwarden itself before any rows land. The path is the one in the
[official wiki](https://github.com/dani-garcia/vaultwarden/wiki/Using-the-PostgreSQL-Backend):
boot Vaultwarden once against the empty database, stop it, then pgloader the rows in.

**The image supports the backend.** Verified, not assumed:
`/vaultwarden` in `vaultwarden/server:1.37.1` links `libpq.so.5`.

**pgloader against PG 18 was smoke-tested end to end on 2026-08-11**, because the wiki only
claims PG 16. A throwaway namespace, a 1-instance CNPG cluster, a throwaway Vaultwarden, and
the real database taken from the nightly backup archive:

| check | result |
|---|---|
| pgloader 3.6.x → PG 18 | 0 errors, 858 rows, 34 foreign keys recreated |
| row counts vs SQLite | exact match on all seven non-empty tables |
| `__diesel_schema_migrations` | PG kept its own 46; SQLite's 56 correctly excluded |
| Vaultwarden 1.37.1 on the migrated DB | `Rocket has launched`, no errors |
| reads migrated rows | `POST /identity/accounts/prelogin` → `200 OK`, real KDF params from the migrated `users` row |

The load file, unchanged from what was tested:

```
load database
     from sqlite:///work/db.sqlite3
     into postgresql://app:<password>@vaultwarden-database-rw.vaultwarden:5432/app
     WITH data only, include no drop, reset sequences
     EXCLUDING TABLE NAMES LIKE '__diesel_schema_migrations'
;
```

Notes that matter:

- `EXCLUDING ... '__diesel_schema_migrations'` is not optional. The SQLite and Postgres
  backends have different migration sets (56 vs 46). Importing SQLite's over Postgres's
  produces duplicate keys and Vaultwarden refuses to start.
- `pragma journal_mode=delete` must be applied to the extracted copy before pgloader reads
  it. The wiki calls for disabling WAL; the online-backup snapshot carries the source
  header across.
- The wiki's `ALTER SCHEMA 'bitwarden' RENAME TO 'public'` line is **omitted** — with a
  SQLite source pgloader targets `public` already, and the line was not needed in testing.

Rejected alternatives:

- **Hand-written Python `sqlite3` → `psycopg` script.** No new image and full control, but
  it means inventing the type-coercion rules (0/1 → bool, BLOB → bytea) for a password
  vault. A silently-wrong column is worse than a failed job. Held as fallback only.
- **Empty database plus per-user Bitwarden JSON re-import.** No tooling at all, but it
  discards 2FA/WebAuthn registrations, sends, password history, org structure and every
  device token. Data loss on a password manager.

### 2. What is left on disk: `/data` returns to `nfs`

New PVC `vaultwarden-data`, `storageClass: nfs`, `ReadWriteMany`, 5Gi. This is the decision
that removes the node pin. `local-path` is rejected here — keeping it would leave the pod
pinned and make the whole migration pointless.

`icon_cache/` and `tmp/` ride along on the same volume rather than earning their own
manifests. `icon_cache` is refetched on demand and would qualify for an emptyDir, but that
is one more volume for no gain at this size.

`replicas: 1` and `strategy: Recreate` are kept. Neither is required any more — RWX and
Postgres both tolerate two pods — but a single writer against `rsa_key.pem` and
`icon_cache/` is one less thing to reason about, and zero-downtime restarts are not a goal.

### 3. Backups

`backup-cronjob.yaml` (SQLite online-backup) is deleted and replaced by `pg-backup.yaml`,
following `apps/nextcloud/pg-backup.yaml`: an `nfs` RWX PVC named `vaultwarden-db-backup`
plus a CronJob that runs `pg_dump -Fc` against `vaultwarden-database-rw` using credentials
from the CNPG-generated secret.

**The CronJob keeps the name `vaultwarden-db-backup`.** `BackupCronJobMissing` in
`system/monitoring-system/prometheusrule-backups.yaml` counts CronJobs matching
`.+-db-backup` and expects 6. Reusing the name keeps the count at 6 and the rule needs no
edit.

Two deliberate departures from the nextcloud/immich template:

- **Retention is 14 days, not 7** — matching what Vaultwarden has today rather than
  downgrading a password manager to the media-app retention.
- **The same job also tars `/data`**, excluding `icon_cache` and `tmp`, into the same
  archive directory. `pg_dump` covers the database and nothing else, but `rsa_key.pem`,
  `config.json`, `attachments/` and `sends/` are now the other half of the app's state and
  live only on NFS. One CronJob covering both halves keeps the name, the alert count, and
  the restore story in one place.

Schedule stays `30 4 * * *`. It does not collide with immich (03:30) or nextcloud (03:45).

**Transient to handle at cutover:** deleting the old CronJob and creating the new one makes
`kube_cronjob_status_last_successful_time` disappear for `vaultwarden-db-backup` until the
new job first succeeds. The count drops to 5 and `BackupCronJobMissing` fires after 1h.
Trigger the new job by hand immediately after the cutover merge.

The pre-migration archives in `/mnt/storage/backups/vaultwarden/` are **not** deleted — they
are the SQLite-era rollback artifact. The new PVC provisions its own subdirectory, so the
two do not collide.

### 4. Secrets: no Infisical entry needed

CNPG generates `vaultwarden-database-app` in the namespace. Its `uri` key is already in
exactly the shape Vaultwarden's `DATABASE_URL` wants — verified against
`nextcloud-database-app`, which reads
`postgresql://app:<password>@nextcloud-database-rw.nextcloud:5432/app`.

```yaml
DATABASE_URL:
  valueFrom:
    secretKeyRef:
      name: vaultwarden-database-app
      key: uri
```

Nothing is committed, nothing round-trips through Infisical, and there is no rotation to
wire up — CNPG owns the credential end to end. `infisical-secret.yaml` is unchanged and
still supplies `ADMIN_TOKEN` only.

## File changes in `apps/vaultwarden/`

| file | change |
|---|---|
| `postgres.yaml` | **new** — CNPG `Cluster` (3 instances, 5Gi local-path, `podAntiAffinityType: required`, sync-wave `-1`) and `Database` |
| `pg-backup.yaml` | **new** — `nfs` RWX PVC + `pg_dump` CronJob named `vaultwarden-db-backup` |
| `backup-cronjob.yaml` | **deleted** — replaced by `pg-backup.yaml` |
| `data-pvc.yaml` | **deleted** — the node pin |
| `values.yaml` | `DATABASE_URL` from the CNPG secret; `/data` → new `nfs` PVC; one-time seed initContainer |
| `app.yaml` | unchanged |
| `limitrange.yaml` | unchanged — CNPG pods set explicit resources, so the defaults do not apply to them |
| `vpa.yaml` | unchanged — targets the Deployment; the CNPG cluster gets no VPA, matching nextcloud and immich |
| `infisical-secret.yaml` | unchanged — `ADMIN_TOKEN` only |

## Execution sequence

Every step reads the old `local-path` volume and never writes it. That is what keeps
rollback free.

**Branch 1 — `feat/vaultwarden-postgres-cluster`.** Add `postgres.yaml` only. No app change,
so nothing can break. Merge, then confirm `kubectl -n vaultwarden get cluster` shows 3/3 and
`Cluster in healthy state` before going further.

**Branch 2 — `feat/vaultwarden-postgres-cutover`.** All remaining file changes. Around the
merge:

1. Scale the Deployment to 0.
2. `kubectl -n vaultwarden create job vw-precutover --from=cronjob/vaultwarden-db-backup`.
   Confirm it logs the expected `2 users, 805 ciphers`. This archive is both the pgloader
   source and the rollback artifact.
3. Merge. ArgoCD creates `vaultwarden-data` on `nfs`; the seed initContainer extracts the
   archive over `/data`, skipping `db.sqlite3*`, `icon_cache`, `tmp` and
   `.migrated-from-nfs`, and writes its sentinel last. `rsa_key.pem` is therefore in place
   **before** Vaultwarden first boots, so it never generates a replacement.
4. Let the pod start. Diesel builds the schema. Verify:
   `select count(*) from __diesel_schema_migrations` is 46 and `select count(*) from ciphers`
   is 0. Scale to 0.
5. Run the pgloader Job (manifest in the plan; not committed, since a Job in git re-runs on
   every ArgoCD sync). Confirm `0 errors` and `858` rows.
6. Scale to 1. Verify.

**Branch 3 — `chore/vaultwarden-drop-migration-scaffolding`.** Remove the seed initContainer
once verification passes, matching the bazarr and jellyfin cleanup commits.

## Verification

Not merged until all of these pass:

1. **Row counts.** Every table in the Postgres database matches the SQLite table above.
   Zero rows in `ciphers` at step 4 and 805 at step 6 — both directions, so a no-op import
   cannot pass silently.
2. **The app reads the data.** `POST /identity/accounts/prelogin` for a known user returns
   `200` with the real KDF parameters, not a default.
3. **A real client login and full sync**, on desktop and on phone. Sessions should survive
   without re-login, which is the observable proof `rsa_key.pem` came across intact.
4. **No `db.sqlite3` on the new volume**, and the pod has no `nodeSelector` and no node
   affinity — the goal, stated as a check.
5. **Reschedule test.** Delete the pod and confirm it comes back Ready, then cordon its
   node and delete it again and confirm it starts on a different node. This is the only
   check that actually demonstrates the pin is gone.
6. **The new backup CronJob has succeeded once**, so `BackupCronJobMissing` sees 6.

## Rollback

Valid at every point until the old PVC is deleted: revert the branch. ArgoCD restores
`existingClaim: vaultwarden-data-local` and Vaultwarden comes back on a SQLite database that
is bit-identical to now, because nothing in this sequence writes to it.

`vaultwarden-data-local` is kept for **14 days** after cutover, and
`/mnt/storage/backups/vaultwarden/` is not pruned by hand. Deleting the PVC is a separate,
later commit.

## Restore drill

Part of this work, not a follow-up. Vaultwarden is the password manager; an unverified
restore path is not a restore path.

After cutover, take the first `pg_dump` produced by the new CronJob and, in a throwaway
namespace: create a 1-instance CNPG cluster, `pg_restore` the dump into it, seed `/data`
from the same night's tar, boot `vaultwarden/server:1.37.1` against it, and confirm the row
counts and a `prelogin` `200`. Tear the namespace down.

This is the same harness used to smoke-test pgloader on 2026-08-11, so it is known to work
and costs one session step. Record the result here when it runs.

## Open risks

- **pgloader is unsupported by upstream.** The wiki says so plainly. Mitigated by having
  actually run it against this exact database and image, and by a rollback that does not
  depend on it.
- **`dimitri/pgloader:latest` is an unpinned, infrequently-released image.** Acceptable for
  a one-shot job that is run once under observation and never committed. Record the digest
  used in the plan.
- **Three more Postgres pods on a cluster that hit CPU throttling earlier today.** Memory
  requests are at 29/42/49% per node and this adds ~768Mi of requests, so there is room —
  but the LimitRange work from 2026-08-11 is recent and worth a second look at pod resources
  after the cluster is up.
