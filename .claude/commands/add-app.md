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

Add persistence if needed. First check **whether the app stores state in SQLite** — most self-hosted
apps do. If so the config volume must be `local-path`, not `nfs`: SQLite over NFS deadlocks. Declare
it as its own manifest (`config-pvc.yaml`, no `sync-wave` annotation, rationale and recovery path in
a comment — copy `apps/sonarr/config-pvc.yaml`) and consume it by name:

```yaml
persistence:
  config:
    existingClaim: <app>-config-local
    globalMounts:
      - path: /config
```

A `local-path` config volume also needs a backup to NFS before it ships — the app's own scheduled
backup pointed at `/data/backups/<app>/`, or a CronJob if it has none
(`apps/cleanuparr/backup-cronjob.yaml`).

Otherwise, `nfs`:
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

## Step 4 — Seal any secrets

If the app needs secrets, add a row to `secrets/registry.tsv`:

```
<secret-name>    <appname>    <stack>/<appname>/<secret-name>.yaml    key=ENV_VAR
```

Add the plaintext value to `secrets/.secrets` (and the var name to `secrets/.secrets.example`) — or use `key=generate:ENV_VAR` instead if it's an arbitrary internal value with no external source (e.g. an API key the app itself will consume). Then run `just seal <secret-name>`. See `secrets/README.md` for details.

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
- [ ] Storage class chosen per volume: `local-path` for SQLite config (with a backup to NFS), `nfs` otherwise
- [ ] nodeSelector `homelab.io/media: "true"` if accessing `/data` on NFS (no toleration — worker-01 is untainted)
- [ ] Secrets sealed and committed, var name added to `secrets/.secrets.example`
- [ ] Row added to `secrets/registry.tsv` if secrets needed
- [ ] If arr-stack app: added to `wire-media` recipe in `Justfile` (root folder and/or Prowlarr application link)
