# Add App

Add a new application to the homelab GitOps repo.

## Step 1 — Determine placement

| Directory | Use for |
|-----------|---------|
| `apps/`     | User-facing applications (media, tools, dashboards) |
| `platform/` | Cluster platform services (operators, secret backends, networking addons) |
| `system/`   | Low-level infrastructure (CNI, ingress controllers, storage provisioners, monitoring) |

When unsure, ask. Wrong placement breaks sync wave ordering.

## Step 2 — Find the Helm chart and latest versions

Prefer well-known charts:
- User apps → bjw-s `app-template` (`https://bjw-s-labs.github.io/helm-charts`)
- Platform/system → upstream chart from the project (cert-manager, external-secrets, etc.)

**Get the latest chart version** — always resolve before writing `app.yaml`:

```bash
# Add repo if not already present
helm repo add <reponame> <repourl>
helm repo update

# Get latest version
helm search repo <reponame>/<chartname> --output yaml | grep version | head -2
```

For bjw-s app-template specifically:
```bash
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
helm repo update
helm search repo bjw-s/app-template
```

**Get the latest image tag** — never use `latest` as a tag (Renovate can't track it):

```bash
# Docker Hub images
curl -s "https://hub.docker.com/v2/repositories/<org>/<image>/tags/?page_size=5&ordering=last_updated" \
  | python3 -c "import sys,json; [print(t['name']) for t in json.load(sys.stdin)['results']]"

# GitHub Container Registry (ghcr.io) — check the project's releases page
# LinuxServer images — check https://fleet.linuxserver.io or the image's Docker Hub tags
```

For LinuxServer (`lscr.io/linuxserver/*`) images, pin to a specific version tag rather than `latest`. Check the image's GitHub releases or Docker Hub tags page.

**Check if the chart has a built-in HTTPRoute** before defaulting to app-template's `route:` block:

```bash
helm show values <reponame>/<chartname> | grep -i "route\|httproute" | head -20
```

Never use `Ingress`. Always use `HTTPRoute` (Gateway API). If the chart only supports `ingress:`, disable it and use app-template's `route:` block instead. If the chart has native HTTPRoute support, use that.

## Step 3 — Create the directory and files

Create `<stack>/<appname>/` with these files:

### `app.yaml` (chart source — Renovate parses this)

```yaml
chartName: app-template
chartRepo: https://bjw-s-labs.github.io/helm-charts
chartVersion: <latest>
```

For non-app-template charts, add `syncWave` if placement order matters:
```yaml
syncWave: "1"
```

### `values.yaml` (Helm values)

Minimum structure for an app-template app:

```yaml
controllers:
  main:
    containers:
      app:
        image:
          repository: <image>
          tag: "<pinned-version>"   # resolved in Step 2 — never use "latest"

service:
  main:
    controller: main
    ports:
      http:
        port: <port>

route:
  main:
    annotations:
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: "<Name>"
      gethomepage.dev/description: "<Short description>"
      gethomepage.dev/group: "Media"        # or "Infrastructure"
      gethomepage.dev/icon: "<name>.png"
      gethomepage.dev/href: "https://<name>.nik-homelab.dev"
    enabled: true
    kind: HTTPRoute
    hostnames:
      - <name>.nik-homelab.dev
    parentRefs:
      - name: homelab
        namespace: envoy-gateway-system
```

If the chart has a **built-in HTTPRoute** (found in Step 2), configure it via the chart's own values and add the Homepage annotations there. Never use `Ingress` — if the chart only supports ingress, disable it (`ingress.enabled: false`) and use app-template's `route:` block instead.

Add persistence if needed. First decide **how the app keeps state** — this is a decision, not a
default:

- **CNPG Postgres cluster** if the app supports Postgres natively *and* the workload justifies
  running one: concurrent writers, a multi-user app, a large or fast-growing dataset, or an app
  with known SQLite contention (Vaultwarden migrated to Postgres 2026-08-12 for this reason — see
  `apps/vaultwarden/postgres.yaml` for the pattern, or `apps/immich/postgres.yaml`,
  `apps/nextcloud/`). Durability comes from streaming replication across instances, which is why
  a CNPG cluster's own volume is the **one remaining `local-path` case** — replicating again at
  the block layer would double write amplification to solve a problem replication already solves,
  and neither `nfs` nor `longhorn` is a supported CNPG configuration. This only pays for itself
  with 2+ instances (`spec.instances`); a single-instance CNPG cluster has none of the replication
  benefit and all of the operational cost of running Postgres, so don't reach for it just because
  an app *can* speak Postgres.
- **SQLite on `longhorn`** otherwise — the default for a typical single-user self-hosted app, and
  what the arrs, Bazarr, Navidrome and Cleanuparr use today. Two replicas, so losing a node
  degrades the volume instead of taking it offline; binds `Immediate`, not
  `WaitForFirstConsumer`; expands in place, so size it for what the app holds today rather than
  guessing at growth. The real cost: Longhorn's fdatasync p99 measured ~4× `local-path`'s (2.93 ms
  vs 0.73 ms) — invisible for these workloads but not free. See
  `system/longhorn-system/README.md` for the full benchmark and the settings that fail silently.
  Declare the PVC as its own manifest (`config-pvc.yaml`, no `sync-wave` annotation, rationale and
  recovery path in a comment) and consume it by name. `apps/sonarr/config-pvc.yaml` shows the
  pattern but is **not** a clean copy-me template right now — it still carries the retained
  `local-path` PVC from Sonarr's own migration, due to go away 2026-08-27.

```yaml
persistence:
  config:
    existingClaim: <app>-config
    globalMounts:
      - path: /config
```

**App-level backups are required regardless of storage class**, and this is unchanged by the
Longhorn migration. Longhorn's own nightly backup (see `system/longhorn-system/README.md`) is
crash-consistent, not application-consistent — it's a safety net under the volume, not a
substitute for the app quiescing its own database. **Check the app's settings for a built-in
backup feature first and prefer it** — the arrs' System → Backup pointed at
`/data/backups/<app>/`. It quiesces its own database, writes an archive its own restore flow
accepts, and adds no manifest to maintain. Only write a CronJob when the app has no backup feature
at all (`apps/cleanuparr/backup-cronjob.yaml` — Cleanuparr has none).

For bulk data genuinely shared between pods (media, backups) — never a database — use `nfs`:
```yaml
persistence:
  config:
    type: persistentVolumeClaim
    storageClass: nfs
    size: 1Gi
    accessMode: ReadWriteMany
    globalMounts:
      - path: /config
```

For media apps that need the shared data volume, add the nodeSelector, toleration, and NFS mount:
```yaml
controllers:
  main:
    pod:
      # worker-01 carries no taint, so no toleration is needed — just the selector.
      nodeSelector:
        homelab.io/media: "true"
    containers:
      ...

persistence:
  data:
    type: nfs
    server: 192.168.30.194
    path: /mnt/storage
    globalMounts:
      - path: /data
```

### `vpa.yaml` (required for all apps)

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: <appname>
  namespace: <appname>
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <appname>
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: 10m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

## Step 4 — Add any secrets to Infisical

Secrets come from Infisical, not `secrets/registry.tsv` — that registry is down to the two
bootstrap rows Infisical can't hold for itself, and adding an app is not a registry change.

1. In the Infisical UI, create the secret at path `/<appname>/<secret-name>` in project
   `homelab-ef-28`, environment `prod`. The path is namespace **and** secret name: two Secrets
   in one namespace sharing a key name collide otherwise. Key names inside it match what the
   app expects to consume.
2. Commit `<stack>/<appname>/infisical-secret.yaml` — copy
   `system/monitoring-system/infisical-secret.yaml` and change the path, name and namespace.

No `just seal`, no plaintext in `secrets/.secrets`, no `.secrets.example` entry. See
`system/infisical/README.md`.

### Arr-stack apps: wire root folders / Prowlarr links

If this app is part of the arr stack (Sonarr, Radarr, Lidarr, etc.) and needs a root folder set or to be linked into Prowlarr as an application, add it to the `wire-media` recipe in `Justfile`: an `ensure_root_folder` call (root folder path) and/or an `ensure_prowlarr_app` call (implementation name, config contract, base URL, sync categories) — follow the existing Sonarr/Radarr calls in that recipe as the pattern. This is a manual, one-time step per app (see `secrets/README.md` and the `wire-media` recipe itself for context) — it won't run automatically just because the app directory exists.

## Step 5 — Verify ArgoCD will pick it up

The root ApplicationSet in `bootstrap/root/values.yaml` auto-discovers directories in `system/`, `platform/`, and `apps/`. No registration needed — ArgoCD syncs automatically when merged to `main`.

## Step 6 — Commit and watch

```bash
git add <stack>/<appname>/
git commit -m "feat(<appname>): add <appname>"
git push
```

Watch sync: `kubectl get application -n argocd` or check ArgoCD UI at `argocd.nik-homelab.dev`.

## Checklist

- [ ] Correct stack directory (apps/platform/system)
- [ ] `app.yaml` with pinned chart version (resolved via `helm search repo`, not `latest`)
- [ ] Image tag pinned to specific version (not `latest`), resolved from Docker Hub / GHCR / LinuxServer fleet
- [ ] Chart inspected for built-in HTTPRoute — use it if present, otherwise use app-template `route:`
- [ ] Homepage annotations on the route
- [ ] `vpa.yaml` present
- [ ] Storage decided per volume: CNPG + `local-path` only if Postgres is justified (2+ instances, real concurrency/scale need), `longhorn` for SQLite config otherwise, `nfs` for shared bulk data
- [ ] App-level backup to `/data/backups/<app>/` exists regardless of storage class — app's built-in backup if it has one, CronJob only if not
- [ ] nodeSelector `homelab.io/media: "true"` if accessing `/data` on NFS (no toleration — worker-01 is untainted)
- [ ] Secrets created in Infisical at `/<appname>/<secret-name>` and an `infisical-secret.yaml` committed
- [ ] If arr-stack app: added to `wire-media` recipe in `Justfile` (root folder and/or Prowlarr application link)
