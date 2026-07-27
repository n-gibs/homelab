# Immich Deployment — Design

**Date:** 2026-07-27
**Status:** Approved, not yet planned
**Branch:** `feat/immich`

## Goal

Deploy Immich (self-hosted photo and video backup) to the homelab k3s cluster via
GitOps, using the official Helm chart. Phones back up to it over LAN and Tailscale.
Library starts empty — no migration or import in scope.

## Why this needs more than the usual app directory

Every existing app in `apps/` is stateless-plus-a-config-PVC. Immich is the first
app that needs a real database, and specifically a PostgreSQL instance with the
VectorChord extension. The official chart does not and will not create one:

> You need to deploy a suitable postgres instance with the vectorchord extension
> yourself. It is recommended to use cloudnative-pg.
> — `immich-app/immich-charts` README

That makes this two deliverables: a new platform-level Postgres operator, and the
app itself.

## Architecture

```
phone / browser
      │
      ▼
Envoy Gateway  ──  immich.nik-homelab.dev  (LAN + Tailscale only, no public route)
      │
      ▼
immich-server ──────────► immich-database-rw   (CNPG, 3 instances, local-path)
      │        metadata
      ├───────► immich-valkey                  (job queues, emptyDir)
      │
      └───────► /mnt/storage/photos            (NFS: originals, thumbs, encoded video)
```

### Component 1 — `platform/cloudnative-pg/` (sync wave 2)

CloudNativePG operator, official chart.

| Field | Value |
|---|---|
| `chartName` | `cloudnative-pg` |
| `chartRepo` | `https://cloudnative-pg.github.io/charts` |
| `chartVersion` | `0.29.0` (operator 1.30.0) |

Operator only — no `Cluster` resources here. HTTPS chart repo, so the existing
Renovate custom manager picks it up with no changes.

Placed in `platform/` (wave 2) rather than `system/` so it is reconciled before
anything in `apps/` (wave 3) tries to create a `Cluster`. It is shared
infrastructure: the parked AFFiNE and n8n designs both want Postgres.

Operator 1.30.0 is required, not incidental — it provides the declarative
extension-image support used below. Verified directly against the `Cluster` and
`Database` CRDs shipped in chart `0.29.0`: `postgresql.extensions[].image`,
`.extension_control_path`, and `.dynamic_library_path` all exist and are not
feature-gated.

### Component 2 — `apps/immich/` (sync wave 3)

| File | Purpose |
|---|---|
| `app.yaml` | OCI chart source |
| `values.yaml` | Helm values: server, valkey, route, DB wiring |
| `library-pv.yaml` | Static NFS `PersistentVolume` + `PersistentVolumeClaim` for the photo library |
| `postgres.yaml` | CNPG `Cluster` + `Database` |
| `pg-backup.yaml` | Nightly `pg_dump` `CronJob` + its backup PVC |
| `vpa.yaml` | VPA for the Immich server deployment |

Everything except `app.yaml` and `values.yaml` is applied by the ApplicationSet's
third source (`directory.exclude: '{app.yaml,values.yaml}'`), which is the same
mechanism `vpa.yaml` already uses across the repo.

## Key decisions

### Chart delivery — OCI, no template changes

The HTTP Helm repo for `immich-charts` has been removed. The chart is OCI-only:

```yaml
chartName: immich
chartRepo: ghcr.io/immich-app/immich-charts
chartVersion: 0.13.1
```

ArgoCD consumes public OCI Helm charts through the ordinary `repoURL` + `chart`
fields with the `oci://` scheme omitted, so `bootstrap/root/templates/stack.yaml`
needs no modification. Verified against the ArgoCD Helm user guide.

### Immich image tag — not overridden

Chart `0.13.1` has `appVersion: v3.0.0` and defaults
`controllers.main.containers.main.image.tag` to `v3.0.0`. Upstream notes the chart
does not release on every Immich release, so this tag can lag.

Accepted. One version knob (`chartVersion`) instead of two. If the lag becomes a
problem — a security fix we need before the chart ships — pin `image.tag`
explicitly in `values.yaml` at that point and add a Renovate `docker` manager for
`ghcr.io/immich-app/immich-server`.

### Postgres — CNPG, 3 instances, `local-path`

`spec.instances: 3`, each with a `local-path` PVC on its own node. Streaming
replication provides the durability the volume does not.

**Why 3 and not 2.** Two instances would give Immich alone the same node-failure
survival for two-thirds the footprint, and on mini PCs that is a real
consideration. Three is chosen deliberately: this cluster is getting a database
platform, not just a database for a photo app. The parked AFFiNE and n8n designs
both want Postgres, and building the quorum now means they attach to a cluster
that is already correctly sized rather than triggering a resize of live
infrastructure. The cost — three Postgres pods before a second consumer exists —
is accepted with that in mind.

This is a platform decision and does not follow from the storage choice below.
If it is ever revisited, dropping to `instances: 2` is a one-line change and the
`local-path` rationale still holds.

This contradicts the current `CLAUDE.md` rule, so **the rule gets amended as part
of this work** rather than silently violated:

> Never use `local-path` StorageClass for new PVCs — *except* for replicated
> databases (CloudNativePG clusters with 2+ instances), where replication, not the
> volume, provides node-failure durability. NFS is not a supported CNPG
> configuration.

The reason for the original ban is that a single-replica app on `local-path` loses
its data when the node dies. Replication removes that reason. NFS was rejected
because CNPG does not support it and Postgres on NFS invites fsync and locking
problems.

Initial volume size: 10Gi. With machine learning disabled there are no CLIP
embeddings, so the database holds metadata only and will stay small.

### Postgres extensions — declarative extension images

Upstream's reference manifest no longer uses a custom Postgres image. It layers
the extension in via CNPG's declarative extension support:

```yaml
imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
postgresql:
  shared_preload_libraries: ["vchord.so"]
  extensions:
    - name: vchord
      image:
        reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1
      dynamic_library_path: [/usr/lib/postgresql/18/lib]
      extension_control_path: [/usr/share/postgresql/18/]
```

A companion `Database` resource declares the extensions Immich needs — `vector`,
`vchord`, `cube`, `earthdistance` — each `ensure: present`.

Benefit over the older `cloudnative-vectorchord` image approach: the base Postgres
image stays stock and CNPG-supported, and the extension version is bumped
independently.

**Cluster prerequisite.** CNPG mounts these extension images as Kubernetes *image
volumes*, so the kubelet must support that volume source. All three nodes run
`v1.36.2+k3s1`, well past the point where image volumes are available by default —
verified against the live cluster, not assumed. If this were an older cluster the
fallback would be a Postgres image with vchord baked in
(`tensorchord/cloudnative-vectorchord`); that fallback is not needed here.

### Credentials — none sealed

CNPG generates the `app` user, the `app` database, and the secret
`immich-database-app` containing its password. `values.yaml` reads it:

```yaml
DB_PASSWORD:
  valueFrom:
    secretKeyRef:
      name: immich-database-app
      key: password
```

No entry in `secrets/registry.tsv`, no `kubeseal` step. This matches the decision
already recorded in the AFFiNE design: a credential that only two in-cluster
components ever see should be generated in-cluster, not round-tripped through a
sealed secret.

`DB_HOSTNAME` points at the `immich-database-rw` service, which CNPG keeps aimed at
the current primary.

### Photo library — static NFS PV at a known path

The chart requires `immich.persistence.library.existingClaim`, so an inline `nfs`
volume of the kind the media apps use is not an option — it must be a PVC.

A hand-written PV bound to `192.168.30.194:/mnt/storage/photos` with a matching
PVC, rather than a dynamic `nfs` StorageClass claim. The dynamic provisioner would
place the library in a generated path like
`/mnt/storage/immich-immich-library-pvc-<uuid>`, which is hostile to direct
`rsync`, manual inspection, and future migration work.

`accessMode: ReadWriteMany` — the server and, if machine learning is enabled later,
the ML pod both read it.

Directory creation goes through Ansible: add `photos` to `nfs_subdirs` in
`ansible/roles/nfs_server/defaults/main.yml` and run `just provision`. The export
is `no_root_squash` and the Immich container runs as root, so it can write into a
`nobody:nogroup 0755` directory — no initContainer `chmod` needed, unlike the
media stack.

### Machine learning — disabled

`machine-learning.enabled: false`, plus `machineLearning.enabled: false` in the
Immich configuration so the server does not queue jobs for a service that is not
there.

There is no GPU in the cluster. CPU-only CLIP inference and face detection on
mid-range mini PCs would contend with the media stack for the same limited CPU,
and the feature is not required to upload, browse, or organise photos. Face
grouping and semantic search are the cost.

Re-enabling later is a values change plus a model-cache PVC (`~10Gi`, RWX) so
models are not re-downloaded on every restart.

### Valkey — enabled in-chart, `emptyDir`

`valkey.enabled: true`, persistence left at the chart default of `emptyDir`.

Immich uses it as a job queue. A restart loses queued jobs; Immich re-queues them
on the next scan. A PVC for that is not worth the manifest.

### Backups — nightly `pg_dump` to NFS

A `CronJob` running `pg_dump` into a small `nfs` PVC, retaining roughly 7 days.

CNPG's native backup path is the barman-cloud plugin, which requires
S3-compatible object storage that does not exist in this cluster. Deploying MinIO
to back up one small metadata database is disproportionate.

What this covers: accidental deletion, logical corruption, a bad upgrade —
restorable with `psql`. What it does not: point-in-time recovery. Acceptable,
because the irreplaceable data is the photo files on NFS, and worst case Immich
can re-scan them into a fresh database (losing albums and sharing config, which is
exactly what the dump protects).

### Exposure — same as every other app

```yaml
route:
  main:
    enabled: true
    kind: HTTPRoute
    hostnames: [immich.nik-homelab.dev]
    parentRefs:
      - name: homelab
        namespace: envoy-gateway-system
```

Plus the standard Homepage annotations (group: Media, icon `immich.png`).

This is not public access. `external-dns` publishes a real Cloudflare record with
`proxied: false` pointing at the Envoy Gateway LB IP from `192.168.30.200/29` —
RFC1918. The name resolves from anywhere; only LAN clients and Tailscale peers can
reach it. The public DNS exists for the Let's Encrypt DNS-01 wildcard cert and
clean hostnames.

Consequence for mobile backup: the phone uploads on home wifi, or off-network only
while Tailscale is connected. Session history notes phone Tailscale is unreliable
behind Visible's CGNAT, so off-network backups may stall until it reconnects.
Photos queue locally and upload later — nothing is lost, but backup is not
continuous.

This is a known, accepted gap in the app's primary purpose. The decision is to
ship private and find out whether backups actually stall in practice before
building anything: the route change is small either way, and putting a photo
library on the internet deserves its own design pass — public-exposure pattern,
tunnel credentials, registration lockout, rate limiting — not a bullet in this
spec. Expect a follow-up spec for Cloudflare Tunnel if real use shows the
Tailscale path is too unreliable.

### VPA — server only

`vpa.yaml` targets the Immich server `Deployment` in `Recreate` mode, per the repo
convention.

No VPA on the CNPG cluster: CNPG owns the lifecycle of those pods, and VPA
evicting them to resize would fight the operator's own rollout logic. CNPG has its
own resource management.

One accepted wrinkle: VPA in `Recreate` mode can evict the server mid-upload. The
client retries.

### Metrics — off

`immich.metrics.enabled: false`. Turn on the ServiceMonitors when there is an
actual dashboard to feed.

## Renovate

The existing custom manager hardcodes `datasourceTemplate: helm`, which cannot
resolve an OCI reference. A second manager is needed for OCI chart repos —
matching `app.yaml` files whose `chartRepo` carries no `https://` scheme, using the
`docker` datasource with `depName` composed as `{chartRepo}/{chartName}`.

The existing HTTPS manager must keep matching HTTPS repos only, so the two do not
both claim the same file.

## Pre-checks

**1. Free disk on all three nodes — RESOLVED, with a prerequisite task.**

Measured: worker-01 has 400GB free and worker-02 has 174GB free, both fine.
worker-00 had only **13GB free of 57GB**, which would have put a 20Gi `local-path`
volume past the kubelet's 10% disk-pressure eviction threshold and started
evicting Grafana, Envoy, and Cilium.

The cause is not a full disk. Ubuntu's installer allocated only half the 116GB
NVMe to the root logical volume, leaving **58GB unallocated in the volume group**.
The node also looks fuller than it is because `common` configures containerd's
native snapshotter, which stores a full copy of every image layer instead of
sharing them via overlayfs — 23 images occupy 32GB.

Resolution: extend the root LV to claim the whole volume group (`lvextend` +
`resize2fs`, online, no data movement, no reboot), taking worker-00 to ~114GB with
~71GB free. This becomes Task 1 of the implementation plan and is added to the
Ansible `common` role guarded on available free extents, so it is idempotent and
survives a node rebuild. Image pruning was rejected as a temporary fix.

The 3-instance decision therefore stands as made, and volume sizing is 20Gi per
instance. This matters because `local-path` has `ALLOWVOLUMEEXPANSION=false` —
undersizing cannot be corrected in place later.

**2. The generated server deployment name — deferred to execution.**

VPA's `targetRef` needs the exact name. It is captured from a rendered template
(`helm template`) during the plan rather than guessed from how the chart composes
`{{ .Release.Name }}-server`.

## Rollout

1. Ansible: add `photos` to `nfs_subdirs`, `just provision`.
2. `platform/cloudnative-pg/` merged to `main`; confirm the operator is healthy
   and its CRDs are established.
3. `apps/immich/` merged to `main`.

During the initial Immich sync the server will crashloop until Postgres finishes
bootstrapping and the extensions are installed. ArgoCD `selfHeal` resolves this
without intervention. This is expected, not a failure.

Per the repo's working agreement, `main` reflects applied state — each step is
merged only once the previous one is confirmed live.

## Post-deploy verification

- Admin account created, first photo uploads and renders a thumbnail.
- File lands under `/mnt/storage/photos` on worker-01 with a sane path.
- `psql` into the cluster: `\dx` lists `vchord`, `vector`, `cube`,
  `earthdistance`.
- CNPG reports 3 healthy instances, one primary, spread across nodes.
- Mobile app connects over LAN and over Tailscale; background backup completes.
- **Large video upload.** A multi-GB upload is a different request shape from the
  Jellyfin streaming that works today. If it fails partway, the fix is an
  `HTTPRoute` request timeout or a `BackendTrafficPolicy` on the Immich route —
  not configured pre-emptively, because guessing at limits that may not exist adds
  config nobody can justify later.
- `pg_dump` CronJob produces a non-empty dump on its first scheduled run.

## Out of scope

- Google Photos / Takeout migration (needs `immich-go`, its own spec)
- Importing any existing folder as an External Library
- Public internet exposure of the Immich hostname
- Machine learning, GPU acceleration
- Object storage (MinIO) and CNPG point-in-time recovery
- Migrating AFFiNE or n8n onto the new CNPG operator
