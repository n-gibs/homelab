# Nextcloud Deployment — Design

Date: 2026-07-31
Status: approved, not implemented

## Goal

Deploy Nextcloud to the homelab k3s cluster as a **document store** — file sync and share, reachable at
`nextcloud.nik-homelab.dev`. Official `nextcloud/nextcloud` Helm chart, ArgoCD-managed like every other
app.

Explicitly not an office suite, not a photo library (Immich owns that), not a mail client.

## Why this needs more than the usual app directory

Three reasons it isn't a three-file `apps/<name>/` drop:

1. It needs a database. Postgres via CloudNativePG, mirroring `apps/immich/`.
2. Its storage splits three ways across two storage classes, each tier chosen for a different failure
   mode (see Storage).
3. The chart's Prometheus integration is subtly broken for this cluster and has to be replaced with a
   hand-written ServiceMonitor (see Metrics).

`apps/immich/` is the closest analog in the repo — same shape, same operator, same NFS pattern. Copy
from it rather than inventing.

## Architecture

```
apps/nextcloud/                       (ArgoCD sync wave 3, ns: nextcloud)
├── app.yaml                          chart nextcloud 9.2.5 (appVersion 34.0.2)
├── values.yaml
├── vpa.yaml                          → Deployment/nextcloud
├── postgres.yaml                     CNPG Cluster + Database   (sync-wave -1)
├── pg-backup.yaml                    nightly pg_dump CronJob + NFS PVC
├── data-pv.yaml                      static NFS PV + PVC       (sync-wave -1)
├── html-pvc.yaml                     local-path PVC            (sync-wave -1)
├── servicemonitor.yaml               scoped to the exporter only
└── prometheusrule.yaml               one alert (NextcloudDown)
```

Rendered objects: `Deployment/nextcloud`, `Deployment/nextcloud-metrics`, `Service/nextcloud`,
`Service/nextcloud-metrics`, `CronJob/nextcloud-cron`, `CronJob/nextcloud-db-backup`,
`HTTPRoute/nextcloud`, plus the CNPG `Cluster`/`Database`.

Edits outside the app directory:

- `renovate.json` — pull `nextcloud` into its own PR group.
- `ansible/roles/nfs_server/defaults/main.yml` — add `nextcloud` to `nfs_subdirs`.
- `apps/homepage/values.yaml` — two `HOMEPAGE_VAR_*` env entries.
- `secrets/registry.tsv` — two rows.

Namespace comes from the stack ApplicationSet (directory basename → `nextcloud`). No namespace
manifest.

## Key decisions

### Chart — official, HTTPS repo, no Renovate comment

```yaml
chartName: nextcloud
chartRepo: https://nextcloud.github.io/helm/
chartVersion: 9.2.5
```

Per the repo's `feedback_prefer_official_helm_chart` rule, the official chart beats the default
`app-template`. It also has **native `httpRoute` support** (`httpRoute.enabled`, `parentRefs`,
`hostnames`) plus optional `wellKnown` CardDAV/CalDAV `RequestRedirect` rules — so no Ingress, and none
of the nginx server-snippet rewriting the chart's README assumes.

**No `# renovate:` comment.** `renovate.json`'s first custom manager already matches the bare
`chartName` / `chartRepo: https://` / `chartVersion` triple. Adding a comment would make the *second*
manager match the same file too, yielding two dependencies for one chart. Immich needs the comment only
because its repo is OCI, which the first manager's `https://`-anchored regex deliberately excludes.

### Database — CNPG, 3 instances, `local-path`, no extensions

`postgres.yaml` is `apps/immich/postgres.yaml` with immich→nextcloud and the vector machinery removed:
no `shared_preload_libraries`, no `vchord` extension image, no `Database.extensions` list. A document
store needs plain Postgres.

Kept from Immich: `instances: 3`, `local-path` storage, `podAntiAffinityType: required`,
`ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`.

Dropped: the `homelab.io/media` toleration. The `PreferNoSchedule` taint it compensated for was removed
2026-07-31; the toleration is now a no-op.

Storage is **10Gi per instance**, not Immich's 20Gi. A document-store DB is metadata only — 10Gi is
roughly two orders of magnitude of headroom. Sized deliberately because `local-path` **cannot be
expanded in place**; growing it later means a rebuild.

### Credentials — the CNPG secret is reused directly

`externalDatabase.existingSecret` points straight at the CNPG-generated `nextcloud-database-app`
secret. Its `username` / `password` / `host` / `dbname` keys map 1:1 onto the chart's `usernameKey` /
`passwordKey` / `hostKey` / `databaseKey`. **No sealed secret for the database at all** — verified by
rendering; the Deployment's `POSTGRES_*` env vars reference `nextcloud-database-app` directly.

One sealed secret is needed, `nextcloud-admin`, for the initial admin account.

### Storage — three tiers, three failure modes

| Tier | Mount | Storage | Size | Rationale |
|---|---|---|---|---|
| Postgres | — | `local-path` ×3 | 10Gi | Replication is the durability, per the CLAUDE.md CNPG exception |
| App tree | `/var/www/html` | `local-path` | 10Gi | **Documented exception** — see below |
| File data | `/nc-data` | static NFS PV | 500Gi | The only irreplaceable tier |

#### App tree on `local-path` — the exception, and why

CLAUDE.md forbids `local-path` outside replicated databases. This is a deliberate, documented second
exception.

The `nfs` StorageClass provisions under `/mnt/storage` on worker-01's **12TB USB spinning disk**,
exported `sync` (`ansible/roles/nfs_server/tasks/main.yml:41`). Nextcloud's app tree is ~15k small PHP
files, rsynced out of the container image on first boot and `stat`-ed on every request. Thousands of
small files, synchronous writes, USB HDD — that combination is the pathological case. First boot would
look like a hang; steady-state page loads would be measurably worse.

The tree is safe to put on a node-local disk because **it is reconstructible**: it's image contents plus
`config.php` plus any custom apps. The two tiers that actually matter — the database and the data dir —
are durable independently.

**Cost, stated plainly:** the PVC pins the pod to one node. Acceptable because `replicaCount: 1` with a
`Recreate` strategy means the pod was never going to float anyway. If that node is drained or cordoned,
Nextcloud is down until it returns — the same exposure CNPG already accepts.

**Recovery if that node dies permanently:** delete the `nextcloud-html` PVC and let the tree rebuild
from the image on next start. The DB and the data dir are untouched. Expect to re-enter nothing; the
entrypoint reinstalls against the existing database.

#### File data on a static NFS PV

`data-pv.yaml` follows `apps/immich/library-pv.yaml` exactly: hand-written PV at
`192.168.30.194:/mnt/storage/nextcloud`, `nfsvers=4.1`, RWX, `persistentVolumeReclaimPolicy: Retain`,
`storageClassName: ""`, with a matching PVC bound by `volumeName`. Both carry `sync-wave: "-1"`.

A static PV rather than a dynamic `nfs` PVC so the data lives at a **known, human-readable path** on
worker-01 — `/mnt/storage/nextcloud` — instead of a provisioner-generated `nextcloud/nextcloud-data`
directory. This matters for the backup project (below) and for any manual recovery.

#### Data directory relocated to `/nc-data` — nesting eliminated

```yaml
nextcloud:
  datadir: /nc-data
```

By default the chart mounts the data volume at `/var/www/html/data` — *inside* the app-tree volume. With
the app tree now on `local-path` and the data on NFS, that would mean a `local-path`-parent /
NFS-child nested mount. Kubelet orders nested mounts by path depth and the chart nests volumes by design
already, so it very likely works — but "very likely" was the only unverified assumption left in this
design, and it did not need to be.

`nextcloud.datadir` drives the data volume's `mountPath` directly (`deployment.yaml:218`), so setting it
to a top-level path makes the two volumes **siblings instead of parent and child**. Verified by
rendering: the mount moves to `/nc-data`, `NEXTCLOUD_DATA_DIR` follows automatically, and the cron pod
gets the same treatment. Nothing is left to find out at deploy time.

`subPath: data` is unchanged, so files still land at `/mnt/storage/nextcloud/data` on worker-01 — the
on-disk layout the backup project will find is exactly as described elsewhere in this spec.

Free side benefit: a data directory outside the webroot is Nextcloud's own documented security
recommendation. It removes any dependence on `.htaccess` rules to keep `data/` from being served.

### Data directory permissions — ansible creates, init container chowns

Two steps, no manual SSH:

1. Add `nextcloud` to `nfs_subdirs` in `ansible/roles/nfs_server/defaults/main.yml`, then
   `just provision`. This creates `/mnt/storage/nextcloud` as `nobody:nogroup` — the NFS PV cannot
   mount a path that doesn't exist. (The role's subdir loop hardcodes `nobody:nogroup`; that's fine,
   step 2 fixes ownership.)
2. `nextcloud.extraInitContainers` runs a `chown 33:33` over the data volume on every pod start —
   the same pattern `apps/qbittorrent/` uses for its download dirs.

```yaml
nextcloud:
  extraInitContainers:
    - name: fix-data-perms
      image: busybox:1.37
      command: ["sh", "-c", "mkdir -p /nc/data && chown 33:33 /nc /nc/data"]
      volumeMounts:
        - name: nextcloud-data
          mountPath: /nc
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 50m, memory: 64Mi}
```

Why an init container is required at all: the pod's `fsGroup: 33` **does not apply to NFS volumes**, so
without this the entrypoint cannot write into the data dir. The chown succeeds because the export
carries `no_root_squash` and the init container runs as root.

`extraInitContainers` is templated as raw YAML (`deployment.yaml:294`), so it can declare its own
`volumeMounts` against the pod-level `nextcloud-data` volume. Verified.

### Node placement — pinned to worker-01

```yaml
nodeSelector:
  homelab.io/media: "true"
```

Two reasons. First, the `local-path` app tree pins the pod to *whichever* node it happens to land on
first — leaving that to chance risks worker-00, the known density hotspot. Pinning makes the choice
deliberate. Second, worker-01 **is** the NFS server, so file I/O to `/mnt/storage` stays local instead
of crossing the network.

Reusing the existing `homelab.io/media=true` label rather than inventing a second one: the label
already means "worker-01" in this repo, and adding a parallel label for the same node would be two
names for one fact. No toleration — worker-01 carries no taint since 2026-07-31.

Accepted cost: Nextcloud competes with the media stack for worker-01's capacity. It has the most free
RAM in the cluster (22.6G vs 14.9G on worker-02), so there is room today.

### Resources and VPA — ratio-aware

```yaml
resources:
  requests: {cpu: 250m, memory: 768Mi}
  limits:   {cpu: "1",  memory: 2Gi}
```

The chart ships `resources: {}`, so these are mandatory per the CLAUDE.md YAML rule.

The ratios are deliberately tight (1:4 CPU, 1:2.7 memory). The repo's `vpa_ratio_shrinks_cpu_limit`
finding is that VPA preserves the request:limit ratio, so a request VPA decides to lower drags the
limit down with it. A 1:20 ratio (`100m` / `2`) would mean VPA observing an idle Nextcloud and dropping
the request to `50m` silently cuts the ceiling to `1` core — throttling hardest exactly when a burst
arrives. `vpa.yaml` sets `minAllowed: {cpu: 100m, memory: 512Mi}` to bound the ratchet from below and
`maxAllowed: {cpu: 2, memory: 3Gi}`.

`vpa.yaml` targets `Deployment/nextcloud` in `Recreate` mode, per repo convention. **No VPA on the CNPG
cluster** — CNPG owns those pods' lifecycle and VPA eviction would fight the operator's rollout, same
reasoning as the Immich spec.

Accepted wrinkle: VPA in `Recreate` mode can evict the pod mid-upload. The sync client retries.

### No Redis

Single replica, APCu as local cache, transactional file locking falls back to Postgres. Fine at
homelab scale for a document store.

Not using the chart's bundled Redis specifically because it pulls `bitnamilegacy/redis` — a
deprecated registry — and provisions two persistent Redis PVCs for a pure cache.

Set `nextcloud.defaultConfigs.redis.config.php: false`. The chart emits `REDIS_URL` referencing
`$(REDIS_HOST)` unconditionally even with Redis disabled; it's harmless (`redis.config.php` no-ops
without `REDIS_HOST`) but writing no Redis config at all is cleaner than relying on that.

**Upgrade path if sync feels slow under concurrent clients:** a small valkey Deployment plus
`nextcloud.externalRedis`. One file, no data migration.

### Background jobs — CronJob, not sidecar

`cronjob.enabled: true` with `type: cronjob` — renders `CronJob/nextcloud-cron` running
`php -f /var/www/html/cron.php` every 5 minutes.

Not `type: sidecar`: the sidecar runs `crond`, which needs root in the app pod.

This is effectively mandatory. Without it Nextcloud shows a permanent admin-panel warning and previews,
trash expiry, and file scanning never run.

### PHP and previews — tuned for documents

```yaml
phpConfigs:
  uploads.ini: |
    upload_max_filesize = 4G
    post_max_size = 4G
    memory_limit = 1G
    max_execution_time = 3600
configs:
  previews.config.php: |-
    <?php
    $CONFIG = array('enable_previews' => true, 'enabledPreviewProviders' => array(
      'OC\Preview\PNG','OC\Preview\JPEG','OC\Preview\GIF','OC\Preview\HEIC',
      'OC\Preview\TXT','OC\Preview\MarkDown','OC\Preview\PDF'));
```

PDF, text, and Markdown previews are the point for a document store. No video preview providers —
that's Jellyfin's job and `ffmpeg` previews are expensive.

### Metrics — exporter yes, chart's ServiceMonitor no

`metrics.enabled: true` renders a `nextcloud-exporter` (`xperimental/nextcloud-exporter:0.9.1`)
Deployment on port 9205. It authenticates with `NEXTCLOUD_USERNAME`/`NEXTCLOUD_PASSWORD` read from the
**same `nextcloud-admin` secret** — no serverinfo token to mint manually, no extra sealed secret.
Enabling metrics also auto-appends the in-cluster service DNS to `NEXTCLOUD_TRUSTED_DOMAINS`, so the
exporter's requests aren't rejected as untrusted.

Our Prometheus has `serviceMonitorSelectorNilUsesHelmValues: false` and `ruleSelectorNilUsesHelmValues:
false` (`system/monitoring-system/values.yaml:113-116`), so it discovers ServiceMonitors and
PrometheusRules cluster-wide with no `release:` label needed.

**The chart's ServiceMonitor is unusable here.** Verified by rendering. Its selector is only
`name` + `instance` + `app.kubernetes.io/monitor: enabled`, and `templates/service.yaml` stamps
`app.kubernetes.io/monitor: enabled` on the **main Nextcloud Service unconditionally** — not just the
metrics one. Both Services also expose a port literally named `http`. So one ServiceMonitor matches
both and scrapes:

- `nextcloud-metrics:9100/metrics` → the exporter. Correct.
- `nextcloud:8080/metrics` → Apache document root. Nextcloud's openmetrics endpoint lives under
  `/index.php/apps/serverinfo/`, not `/metrics`. Permanently down.

kube-prometheus-stack's default `general.rules` ships `TargetDown`, which fires when >10% of a job's
targets are down — so this would mean a permanently-firing alert. There is no values knob to remove the
label from the main Service.

Therefore `prometheus.serviceMonitor.enabled: false` and a hand-written `servicemonitor.yaml`, following
`system/monitoring-system/argocd-servicemonitor.yaml`:

```yaml
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nextcloud
      app.kubernetes.io/instance: nextcloud
      app.kubernetes.io/component: metrics    # the discriminator the chart omits
  endpoints:
    - port: http                              # metrics svc 9100 → targetPort 9205
      path: /metrics
      interval: 60s
```

**The chart's rules are off entirely** — `prometheus.rules.enabled: false`. Of the three it ships, only
`nextcloud: not reachable` is worth having; the other two, `nextcloud_system_update_available > 0` and
`nextcloud_apps_updates_available_total > 0`, latch the moment upstream releases anything and stay
firing until you upgrade. A permanently-firing warning defeats the alerting hygiene established in
`monitoring_alerting_inside_blast_radius`.

Rather than enabling the chart's rule template with `defaults.enabled: false` and one `additionalRules`
entry, the single alert we want lives in `prometheusrule.yaml` alongside the ServiceMonitor we already
had to hand-write. One mechanism for both monitoring objects, matching how
`system/monitoring-system/prometheusrule-*.yaml` are written:

```yaml
- alert: NextcloudDown
  expr: 'avg without(endpoint,container,pod,instance) (nextcloud_up{namespace="nextcloud"}) < 1'
  for: 10m
  labels: {severity: warning}
  annotations:
    summary: "Nextcloud is not reachable by its metrics exporter"
```

`severity: warning` routes through the existing Alertmanager tree. Also set
`metrics.info: {apps: false, update: false}` — those two series exist only to feed the alerts we just
declined, so there's no reason to have the exporter poll for them.

Useful series once running: `nextcloud_users_total`, `nextcloud_files_total`,
`nextcloud_free_space_bytes`, `nextcloud_database_size_bytes`, `nextcloud_active_users_total`.

Grafana dashboard is a follow-up, not part of this spec — same ConfigMap + `grafana_dashboard` label
pattern as `system/monitoring-system/dashboard-temperatures.yaml`, using a community dashboard chosen
from grafana.com at the time.

### Exposure — LAN and Tailscale only

```yaml
httpRoute:
  enabled: true
  hostnames: [nextcloud.nik-homelab.dev]
  parentRefs: [{name: homelab, namespace: envoy-gateway-system}]
  rules:
    - matches: [{path: {type: PathPrefix, value: "/"}}]
      timeouts: {request: 3600s}
```

Same as every other app, and — as the Immich spec establishes — **this is not public access**.
`external-dns` publishes a real Cloudflare record with `proxied: false` pointing at the Envoy Gateway LB
IP from `192.168.30.200/29`, which is RFC1918. The name resolves from anywhere; only LAN clients and
Tailscale peers can reach it. Public DNS exists for the DNS-01 wildcard cert and clean hostnames.

Consequence for a document store: desktop and mobile sync work at home, or off-network only while
Tailscale is connected. Session history notes phone Tailscale is unreliable behind Visible's CGNAT
(`project_tailscale_remote_access_phone_nat`), so off-network sync may stall. Files queue and sync
later — nothing is lost.

Accepted as-is. Putting a document store on the internet deserves its own design pass (public-exposure
pattern, tunnel credentials, registration lockout, rate limiting), not a bullet here.

The `timeouts.request: 3600s` is for large uploads outliving Envoy's default stream timeout. Envoy
Gateway imposes no request-body size limit by default, so 4G uploads should pass; if they cut off
mid-transfer, the lever is a `ClientTrafficPolicy`, not the HTTPRoute.

### Backups — database yes, files deferred

`pg-backup.yaml` is `apps/immich/pg-backup.yaml` with immich→nextcloud, a 5Gi backup PVC, and schedule
`45 3 * * *` — staggered off Immich's `30 3` so two `pg_dump`s don't hit the USB disk together. Roughly
7 days retained.

CNPG's native backup path is the barman-cloud plugin, which needs S3-compatible object storage that
doesn't exist in this cluster. Same reasoning as the Immich spec: MinIO to back up one small database is
disproportionate.

**File data has no backup. This is a known gap, deliberately deferred** to a planned larger
drive-backup project that will cover `/mnt/storage` as a whole — including `photos` and `media`, which
have the same exposure. Backing up only Nextcloud's subtree now would be solving a third of the problem
in a way that project would immediately replace.

Three things make the deferral safe to live with rather than merely acknowledged:

**1. It's tracked by existing tooling, not by memory.** `data-pv.yaml` carries a `TODO:` comment naming
the gap, which `just todos` (`Justfile:343` — greps `TODO` across `apps/`, `system/`, `platform/`,
`ansible/`) surfaces on demand. The gap shows up in the repo's own todo listing until the backup project
closes it, so it can't quietly become permanent:

```yaml
# TODO: /mnt/storage/nextcloud has no off-host backup. Documents here may be the
# only copy. Covered by the planned /mnt/storage backup project, which also owns
# photos/ and media/. Until then the desktop sync client is the second copy.
```

**2. In-app recovery already works.** Nextcloud's `versions` and `trashbin` apps are enabled by default,
so accidental deletion and bad edits — by far the likeliest way to lose a document — are recoverable
from the UI with no infrastructure at all. The uncovered failures are drive failure, fire, and theft.

**3. The desktop client is the interim second copy.** This is an operational practice, not a
configuration: run the Nextcloud desktop client on at least one machine with a full local sync, and the
12TB drive failing costs you the server rather than the documents. It's the same reasoning the Immich
spec used for photos originating on phones, made explicit here because documents have no equivalent
natural second home.

That third point is a real dependency on behaviour, so state it plainly: **until the backup project
lands, do not treat this as the only copy of anything that matters.**

### Upgrade safety — own Renovate group, and a pre-merge dump

Nextcloud refuses to skip major versions; 34→36 in one jump wedges the upgrade and needs manual `occ`
recovery. Two mitigations.

**Own Renovate group.** A `packageRule` pulls `nextcloud` out of the shared `helm charts` group so its
bump always arrives as its own PR, never buried in a batch of six unrelated charts where a two-major
jump reads as one line in a diff. `automerge` stays false, as everywhere.

**Pre-merge dump.** The `occ` upgrade runs in the entrypoint on pod start. If it fails you have a
crashlooping pod and a dump that may be ~24h old. Before merging any Nextcloud version bump:

```bash
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-backup nextcloud-preupgrade-$(date +%s)
```

Also worth a comment in `app.yaml` stating the no-skip rule, so the constraint is visible at the point
of edit rather than only in this document.

### Homepage widget

Standard `gethomepage.dev/*` annotations on the HTTPRoute — group `Infrastructure`, icon
`nextcloud.png`. The widget needs a username and an **app password**, which can only be minted after
first login, so wiring it is a follow-up commit exactly as the Immich API key was.

Note the annotation values need `'{{ "{{HOMEPAGE_VAR_X}}" }}'` quoting **if** this chart runs route
annotations through `tpl`. The bjw-s chart does, which is why Immich needs it. Confirm with
`helm template` at implementation time; if this chart doesn't `tpl` annotations, use the bare
`{{HOMEPAGE_VAR_X}}` form.

## Secrets

Two rows in `secrets/registry.tsv`:

```
nextcloud-admin           nextcloud  apps/nextcloud/admin.yaml           username=NEXTCLOUD_ADMIN_USER,password=NEXTCLOUD_ADMIN_PASSWORD
nextcloud-homepage-creds  homepage   apps/homepage/nextcloud-creds.yaml  username=NEXTCLOUD_ADMIN_USER,password=NEXTCLOUD_HOMEPAGE_APP_PASSWORD
```

`NEXTCLOUD_ADMIN_USER` and `NEXTCLOUD_ADMIN_PASSWORD` go in `secrets/.secrets` as real values — **not**
`generate:`, because these are credentials you log in with, not arbitrary internal shared secrets.

`NEXTCLOUD_HOMEPAGE_APP_PASSWORD` is minted post-install, so it's added in the follow-up commit.

**Rotation rule:** change the admin password by editing `secrets/.secrets` and resealing, never in the
Nextcloud UI. `NEXTCLOUD_ADMIN_PASSWORD` is only applied at install time, so a UI-side change desyncs
the secret — and because the metrics exporter authenticates with that same secret, the first symptom is
the exporter returning 401 and `NextcloudDown` firing, which points at entirely the wrong thing.

## Rollout

1. Add `nextcloud` to `nfs_subdirs`, run `just provision`. Confirm `/mnt/storage/nextcloud` exists on
   worker-01.
2. Add `NEXTCLOUD_ADMIN_*` to `secrets/.secrets`, add the registry row, `just seal nextcloud-admin`.
3. Write `apps/nextcloud/` (9 hand-written files; `admin.yaml` is a tenth, generated by `just seal` in
   step 2) plus the `renovate.json` group rule.
4. Validate locally: `helm template nextcloud nextcloud/nextcloud --version 9.2.5 -n nextcloud -f
   apps/nextcloud/values.yaml` renders, the Deployment's `POSTGRES_*` env references
   `nextcloud-database-app`, and only our own ServiceMonitor is present.
5. Commit and push to `main`. If the new Application doesn't appear, refresh the **ApplicationSet** —
   per `argocd_appset_refresh_for_chart_bumps`, an Application refresh is a no-op for this.
6. Watch CNPG first (`sync-wave: -1`): all 3 instances Ready before the app pod starts. First boot then
   runs the installer against an empty database — expect it to be slow.

   **`startupProbe` must be enabled explicitly in `values.yaml`.** The chart ships it disabled while
   `livenessProbe` is enabled with `initialDelaySeconds: 10`, `periodSeconds: 10`,
   `failureThreshold: 3` — roughly a 40-second budget before liveness starts killing a pod that is
   still installing. With chart defaults the first boot crashloops mid-install and never completes.
   Set `startupProbe.enabled: true` with `failureThreshold: 60` for a 10-minute budget.

## Post-deploy verification

- `https://nextcloud.nik-homelab.dev` serves the login page; admin credentials work.
- Upload a file; confirm it appears under `/mnt/storage/nextcloud/data/` on worker-01, and that
  `/nc-data` inside the pod is the NFS mount while `/var/www/html` is the local-path one
  (`kubectl exec -- df -h /nc-data /var/www/html`).
- Pod is running on worker-01; `nextcloud-html` PVC bound on that node.
- Settings → Administration → Overview shows no "background jobs have not run" warning after ~15min.
- Prometheus targets: exactly **one** `nextcloud-exporter` target, Up. Two targets, or one Down, means
  the chart's ServiceMonitor leaked in. `nextcloud_up == 1` queries clean.
- Exporter logs contain no 401 (would mean the admin secret doesn't match).
- Next morning: `nextcloud-db-backup` wrote a dump to its PVC.

## Follow-ups (separate commits, not this spec)

- Mint the Homepage app password, seal it, wire the two `HOMEPAGE_VAR_*` entries.
- Grafana dashboard ConfigMap for the exporter.
- Valkey + `externalRedis`, if concurrent sync proves slow.
- `/mnt/storage` backup project — covers this app's file data along with photos and media.

## Out of scope

Collabora / Office (heavy, needs its own hostname and route), imaginary preview generation, SMTP mail,
S3 primary storage, public internet exposure, multi-replica HA.
