# Infisical for Secrets Management — Design

**Date:** 2026-08-10
**Status:** Approved, not implemented

## Goal

Replace sealed-secrets as the source of truth for cluster secrets with a self-hosted
Infisical instance, so that:

1. Plaintext secrets stop living on the laptop in `secrets/.secrets`.
2. Secrets survive a cluster rebuild (Talos migration) without resealing 15 manifests
   against a freshly generated keypair.
3. There is a UI, an audit log, and somewhere to keep secrets that aren't Kubernetes
   secrets at all.

Explicitly **not** a goal: depending on a third party for cluster secrets. Infisical Cloud
was evaluated and rejected — see Alternatives.

## Decision

Self-host Infisical **in the `system` stack at sync wave 0**, ahead of every other
platform and application component. Secrets reach workloads as native Kubernetes Secrets
via the Infisical Kubernetes operator.

The sync path never leaves the cluster: the operator talks to
`http://infisical.infisical.svc.cluster.local:8080` directly. It does not depend on Envoy
Gateway, cert-manager, external-dns, or the internet. The web UI is exposed later via
HTTPRoute and is cosmetic to secret delivery.

## Architecture

### Components

| Path | Chart | Wave | Purpose |
|------|-------|------|---------|
| `system/sealed-secrets/` | `sealed-secrets` | `-1` | Holds exactly one secret: `infisical-secrets` |
| `system/cloudnative-pg/` | `cloudnative-pg` | `-1` | CNPG operator, moved from `platform/` |
| `system/infisical/` | `infisical-standalone` 1.8.0 | `0` | Infisical server + CNPG Cluster + Redis |
| `system/infisical-operator/` | `secrets-operator` 0.11.7 | `0` | Syncs Infisical → k8s Secrets |

Both charts come from `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/`.

**Do not use the `infisical` chart from that repo.** Its latest published version is 0.4.2
(2024-05-07, appVersion 1.17.0) and it still depends on MongoDB. It is a pre-Postgres
artifact that was never removed from the index. The maintained chart is
`infisical-standalone`.

### Boot order

```
sealed-secrets (-1) ─┐
cloudnative-pg (-1) ─┴→ infisical Cluster + Infisical + operator (0) → envoy (1) → cert-manager (2) → …
```

sealed-secrets and CNPG are siblings, not a chain — neither depends on the other. Per-app
ordering uses the `syncWave` key in `app.yaml`, which the root ApplicationSet template
already reads (`system/envoy-gateway` is `"1"`, `cert-manager` `"2"`, `external-dns` `"3"`).

Waves control how quickly first boot converges, not whether it succeeds. A pod whose Secret
does not exist yet sits in `ContainerCreating` and ArgoCD's `selfHeal` retries; a wrong wave
makes the cluster slow to settle, not broken.

### Database

CNPG owns the credential. It generates `infisical-database-app` in-cluster with
`username`/`password`/`host`/`dbname`/`uri` keys, and Infisical consumes the `uri` key
directly:

```yaml
postgresql:
  enabled: false          # disable the bundled Bitnami subchart
infisical:
  useExistingPostgresSecret:
    enabled: true
    existingConnectionStringSecret:
      name: infisical-database-app
      key: uri
```

This is the same pattern `apps/nextcloud/values.yaml` already uses, and it means **no sealed
secret exists anywhere in the database path**. It also sidesteps the Bitnami-subchart
regeneration footgun: `helm template` has no cluster `lookup`, so a chart-generated random
password is re-rolled on every ArgoCD sync and breaks the connection string. An
operator-generated credential is stable across syncs.

The CNPG `Cluster` uses `storageClass: local-path` per the CNPG exception in `CLAUDE.md` —
streaming replication, not the volume, provides node-failure durability, and NFS is not a
supported CNPG configuration.

Redis stays as the bundled subchart with no persistence. Infisical uses it for cache and
queues only; losing it costs a reconnect.

### Bootstrap secret

`infisical-secrets` (the chart's `kubeSecretRef`) holds `ENCRYPTION_KEY`, `AUTH_SECRET`, and
`SITE_URL`. These are Infisical's own application secrets and cannot come from Infisical.
They stay a SealedSecret — one row in `secrets/registry.tsv`.

`ENCRYPTION_KEY` and `AUTH_SECRET` are arbitrary internal values that never have to match an
external system, which is exactly what the registry's `generate:` prefix is for. They are
auto-generated once and cached in `secrets/.secrets.generated`.

**`ENCRYPTION_KEY` must also be copied out of the cluster.** Every secret in Infisical is
encrypted with it. A database backup without it is unrecoverable ciphertext, and both the
sealed manifest and `.secrets.generated` are unavailable after a cluster rebuild — the
sealed-secrets keypair is regenerated, and `.secrets.generated` is gitignored. This is the
single highest-consequence item in the design.

Three copies, each covering a failure the others don't:

1. **Vaultwarden** — the working copy, where you'd look first.
2. **A synced Bitwarden client** (desktop or phone) holding an offline cache of that entry.
   Vaultwarden runs in this cluster, so it is unavailable in precisely the scenario where
   the key is needed; the synced client is what puts a copy outside the cluster's failure
   domain. Vaultwarden alone is not a backup of this key.
3. **An `age`-encrypted copy in a private off-site repo**, with the age passphrase stored in
   Vaultwarden. Covers loss of the house, which the first two do not. The ciphertext is
   useless on its own, so the repo's exposure is not the key's exposure.

GitHub Actions secrets were considered and rejected: they are write-only, so recovering the
value requires a workflow that deliberately defeats Actions' log masking — which would then
let anyone with push access to the repo extract the key. Hard to read when needed, easy to
read when not.

The recovery runbook therefore depends on `age`. Note that dependency where the restore
procedure is written down.

### Ingress

The chart bundles its own ingress-nginx controller. The repo is Gateway API only, so:

```yaml
ingress:
  enabled: false
  nginx:
    enabled: false
```

and a hand-written `httproute.yaml` at `infisical.nik-homelab.dev`, with the standard
Homepage annotations (`gethomepage.dev/group: "Infrastructure"`).

### Infisical org layout

One project `homelab`, one environment `prod`, folders per Kubernetes namespace
(`/sonarr`, `/cert-manager`, `/tailscale`, …).

Shared values get their own folder. The arr API keys are currently the `generate:` hack in
`registry.tsv`, duplicating one value across five rows; in Infisical they become a single
secret under `/shared` consumed via secret references. This is a genuine improvement over
the current model, not a straight port.

### Per-app pattern

Each app directory swaps its `SealedSecret` manifest for an `InfisicalStaticSecret` that
produces a Kubernetes Secret with the **same name and the same keys**, so no `values.yaml`
anywhere changes.

Use `InfisicalStaticSecret` (v1beta1), not `InfisicalSecret` (v1alpha1) — the latter is
deprecated and slated for removal. v1beta1 splits connection and auth into separate reusable
resources:

- One `InfisicalConnection` (address `http://infisical.infisical.svc.cluster.local:8080`)
- One `InfisicalAuth` (universal-auth machine identity)

Both live in the `infisical` namespace. `infisicalAuthRef` takes a name **and** a namespace,
so every namespace references that single pair — no per-namespace credential duplication.

The `InfisicalConnection` and `InfisicalAuth` manifests go in `system/infisical/`, not
`system/infisical-operator/`. The ApplicationSet hardcodes `destination.namespace` to the
directory basename, and these resources must land in `infisical` alongside
`infisical-secrets`. They will fail their first sync until the operator's CRDs exist;
ArgoCD's retry resolves it.

Each new directory also gets a `vpa.yaml` per repo convention.

### Backup

Nightly `pg_dump -Fc` CronJob writing to `/data/backups/infisical/` on the NFS share, 14
retained. Same pattern as `apps/cleanuparr/backup-cronjob.yaml`. The dump is a few MB.

CNPG's native backup (barman) targets S3-compatible object storage; NFS is not a valid
destination, and running MinIO to satisfy it would be more machinery than the thing being
backed up. The CronJob runs long after boot, so its NFS dependency is harmless to the boot
chain.

This makes Infisical the first CNPG cluster in the repo with an actual backup — `nextcloud`
and `immich` currently have none. Extending the same CronJob pattern to them is out of scope
here but worth a follow-up.

## Failure modes

**Infisical down, steady state.** Workloads mount native Kubernetes Secrets and never talk
to Infisical. Everything keeps running indefinitely; only propagation of *changes* stops.
This is silent, so it ships with a Prometheus alert on operator reconcile errors.

**Infisical down, cold start.** Nothing can populate its secrets. This is the real cost of
self-hosting: the boot chain gains a serial dependency (k3s → Cilium → ArgoCD →
sealed-secrets + CNPG → Postgres → Infisical → everything else) that it does not have today.

**Talos rebuild.** Restore the pg_dump and supply the offline `ENCRYPTION_KEY` before
anything else can start. Accepted deliberately as the price of not depending on a third
party.

**Rollback.** SealedSecret manifests remain in git history. Reverting the migration commit
restores them and ArgoCD re-applies.

## Migration sequence

1. Move `platform/cloudnative-pg` → `system/cloudnative-pg`, `platform/sealed-secrets` →
   `system/sealed-secrets`, both at wave `-1`. Verify the existing `nextcloud` and `immich`
   Clusters survive the ApplicationSet handover — the generated Application moves between
   two ApplicationSets, and the template sets no `resources-finalizer`, so resources should
   be orphaned and re-adopted rather than cascade-deleted. **Confirm this before merging**,
   with a database backup taken first.
2. Deploy Infisical + operator at wave 0. Create the project, environment, and machine
   identity through the UI. Store `ENCRYPTION_KEY` in all three places — Vaultwarden, a
   verified synced Bitwarden client, and the age-encrypted off-site copy — before
   proceeding. This gates everything after it.
3. Pilot on `ntfy-webhook-url` (namespace `monitoring-system`): single key, non-critical,
   easy to verify. Confirm the Secret materializes and that changing the value in Infisical
   propagates.
4. Migrate the remaining ~14 registry rows, one namespace at a time, verifying each app
   before moving on. Consolidate the arr API keys into `/shared`.
5. Shrink `registry.tsv` to the single `infisical-secrets` row and delete the superseded
   SealedSecret manifests.
6. Add the backup CronJob and the operator reconcile-error alert.

## Alternatives considered

**Infisical Cloud free tier.** Rejected on the user's call that cluster secrets should not
live on a third party's infrastructure. Worth recording that the dependency would have been
narrower than it sounds: the operator writes native Kubernetes Secrets, so a Cloud outage
would pause secret *updates* without affecting any running workload. It would also have been
strictly less machinery — one revocable API credential, no Postgres, Redis, or backup to
own. The free tier is real (5 identities, unlimited projects, 3 environments) but excludes
secret versioning, point-in-time recovery, and rotation.

**Kubernetes Auth instead of Universal Auth.** Not viable. Infisical validates the service
account token by calling the cluster's TokenReview API, which requires reachability into the
cluster; Gateways are a paid feature. Universal Auth (client ID + secret) is used instead.

**External Secrets Operator with the Infisical provider.** Vendor-neutral and portable
across backends, at the cost of an extra abstraction for a backend there is no plan to
change. Rejected as unnecessary indirection.

**Retiring sealed-secrets entirely** in favour of a manual `kubectl create secret` bootstrap
step. Tempting once only one secret remains, but the `generate:` mechanism makes that row
free to maintain and keeps ArgoCD able to self-heal it. Keeping sealed-secrets.

**Self-hosting outside the cluster** (Docker Compose on a node, or the NAS when it arrives).
Breaks the boot-chain circularity and would survive a Talos rebuild intact, but ships
nothing now and becomes a hand-patched pet outside GitOps.

## Out of scope

- Secret rotation and versioning (EE-licensed features).
- Migrating `seal-argocd-token`, which mints a token at seal time rather than storing a
  static value, and `seal-secret <file>` for one-offs. Both are unaffected.
- Backups for the existing `nextcloud` and `immich` CNPG clusters.
- Storing non-Kubernetes secrets (router credentials, etc.) in Infisical. Supported by the
  design, but not part of this migration.

## To verify at implementation

- `helm search repo` for current `infisical-standalone` and `secrets-operator` versions
  rather than trusting the index read on 2026-08-10.
- That Renovate resolves the Cloudsmith Helm index — this is the first non-standard chart
  host in the repo, and `lscr.io` already required an auth workaround.
- That the Bitnami `redis` subchart still pulls anonymously.
- The ApplicationSet handover behaviour in step 1, before merging.
