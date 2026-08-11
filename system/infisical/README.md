# Infisical

Source of truth for application secrets. All 20 app secrets (32 keys) live here and
are synced into the cluster as ordinary Kubernetes Secrets by the Infisical secrets
operator via `InfisicalStaticSecret` CRs. SealedSecrets is retired for everything
except the two bootstrap rows that can't come from Infisical itself — see
`secrets/README.md`.

## Resources

- Infisical Deployment + Service: `infisical-infisical-standalone-infisical`
  (namespace `infisical`, ClusterIP, plain HTTP `:8080`)
- Operator Deployment: `infisical-opera-controller-manager` (namespace
  `infisical-operator`; the chart truncates the release name to 15 chars)
- Database: CNPG cluster `infisical-database`, 3 instances, namespace `infisical`.
  App credentials in Secret `infisical-database-app`.
- Project slug: `homelab-ef-28` (Infisical appends a random suffix at creation).
  Environment slug: `prod`.
- Secret path convention: `/<namespace>/<secret-name>`, e.g.
  `/monitoring-system/ntfy-webhook-url`. Nested by namespace *and* secret name
  deliberately — a per-namespace-only scheme collided when two Secrets in one
  namespace both used the key `url`, and that collision caused a live
  misconfiguration during the migration. Key names inside each secret are
  unchanged from the Kubernetes Secret they replaced.

## Adding a secret

See the "Secrets" section of the root `CLAUDE.md` — add the value in the
Infisical UI, then commit an `InfisicalStaticSecret` manifest (copy
`system/monitoring-system/infisical-secret.yaml`).

## Cold-start ordering

This is the constraint that matters most for a cluster rebuild (or the Talos
migration): Infisical must be healthy **before** anything that needs a secret
from it. The dependency chain:

```
CNPG operator
  → infisical-database Cluster
  → infisical-secrets bootstrap SealedSecret (carries ENCRYPTION_KEY; can't come from Infisical)
  → Infisical itself
  → the operator + its InfisicalAuth machine identity
  → every InfisicalStaticSecret
  → the workloads
```

cert-manager, external-dns, and Tailscale all draw credentials from Infisical
now, so a cold start where Infisical is down before them means no TLS
certificates, no DNS records, and no remote access. The other half of this,
which is what makes it survivable: every workload that's already running keeps
working, because the Kubernetes Secrets the operator already produced are
ordinary Secrets that persist independently of Infisical being up.

Recovery order after total loss: restore the bootstrap SealedSecret from a key
copy → restore the database dump → bring Infisical up → the operator
repopulates all 20 Secrets automatically.

## Backups

CronJob `infisical-db-backup` (namespace `infisical`) runs daily at 03:00,
`pg_dump -Fc` from image `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`,
retention via `find -mtime +14 -delete`. It writes to PVC `infisical-db-backup`
(1Gi, RWX, `nfs` StorageClass), which the nfs-subdir provisioner lands at
`192.168.30.194:/mnt/storage/infisical/infisical-db-backup/` — namespace/pvc-name.
Filenames are `infisical-<YYYYmmdd-HHMMSS>.dump`.

`BackupCronJobMissing` (`system/monitoring-system/prometheusrule-backups.yaml`)
matches CronJobs on `.+-db-backup` and expects 4 of them — renaming this job
needs to keep that suffix. Staleness of secret delivery itself (not the backup)
is covered separately by `InfisicalSecretStale` / `InfisicalSecretMetricsMissing`
in `prometheusrule-infisical.yaml`.

### The ENCRYPTION_KEY

The database dumps are worthless without it: it encrypts every secret value at
rest, so a restore without it yields rows nobody can read. There are three
copies — Vaultwarden, a synced Bitwarden client, and an age-encrypted off-site
file (32 bytes; the `age` binary is a dependency of the recovery path).
`secrets/.secrets.generated` also holds a copy but **must not be relied on** —
it's the copy that won't exist after a rebuild.

Verify the off-site copy against the live key by comparing hashes, never by
printing either value:

```bash
age -d infisical-encryption-key.age | tr -d '\n' | shasum -a 256
kubectl -n infisical get secret infisical-secrets -o jsonpath='{.data.ENCRYPTION_KEY}' | base64 -d | shasum -a 256
```

## Restore rehearsal

Verified against a scratch Postgres, not a live overwrite — the dump is
mounted read-only, nothing gets deleted. The dump is already on the NFS share,
so this deliberately skips scp'ing it through a workstation first.

```bash
kubectl create namespace infisical-restore-test
```

Pod manifest — `postgres:18-trixie`, not the CNPG operand image: the CNPG image
isn't built to self-initialize from `POSTGRES_PASSWORD` the way the official
image's entrypoint is. pg_dump/pg_restore's major version must be >= the
server's (18.4 live), which the `18` tag satisfies.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: scratch-pg
  namespace: infisical-restore-test
spec:
  containers:
    - name: postgres
      image: postgres:18-trixie
      env:
        - name: POSTGRES_PASSWORD
          value: scratch
        - name: PGDATA
          value: /pgdata/pg
      volumeMounts:
        - name: pgdata
          mountPath: /pgdata
        - name: backup
          mountPath: /backup
          readOnly: true
  volumes:
    - name: pgdata
      emptyDir: {}
    - name: backup
      nfs:
        server: 192.168.30.194
        path: /mnt/storage/infisical/infisical-db-backup
        readOnly: true
```

```bash
kubectl -n infisical-restore-test wait --for=condition=Ready pod/scratch-pg --timeout=300s

kubectl -n infisical-restore-test exec scratch-pg -- bash -c '
  set -euo pipefail
  d=$(ls -1t /backup/infisical-*.dump | head -1)
  createdb -U postgres app
  pg_restore -U postgres -d app --no-owner --no-privileges "$d"'
```

`--no-owner --no-privileges` is required: the dump's objects are owned by the
CNPG `app` role, which doesn't exist in a scratch Postgres.

Row-count parity is the real test — "the tables exist" is the weak version of
this check:

```bash
Q="select (select count(*) from secrets_v2) sec, (select count(*) from secret_folders) folders, (select count(*) from projects) proj, (select count(*) from identities) ids"
kubectl -n infisical-restore-test exec scratch-pg -- psql -U postgres -d app -tAc "$Q"
kubectl -n infisical exec infisical-database-1 -c postgres -- psql -d app -tAc "$Q"
```

The live query must run as the `postgres` superuser via local socket — `psql -U
app` fails with "Peer authentication failed".

```bash
kubectl delete namespace infisical-restore-test
```

**Verified 2026-08-11:** 704 base tables restored; row counts identical to live
(`secrets_v2` 32, `secret_folders` 40, `projects` 1, `identities` 1). An earlier
`pg_restore -l` check on the same dump reported 7064 TOC entries, 726 TABLE DATA.
