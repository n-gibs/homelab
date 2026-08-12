# Homelab

k3s homelab on HP ProDesk Mini PCs. Ansible provisioning, ArgoCD GitOps.

## Stack

k3s + Cilium (VXLAN) + ArgoCD (GitOps) + Envoy Gateway + cert-manager + Infisical + Tailscale (in-cluster subnet router for remote access to services — not used for node SSH)

Application secrets come from a self-hosted Infisical (`system/infisical`), synced into
Kubernetes Secrets by its operator — see [`system/infisical/README.md`](system/infisical/README.md)
for the recovery runbook. sealed-secrets is still installed but now covers only the two
bootstrap values Infisical can't hold for itself.

Observability is kube-prometheus-stack (`system/monitoring-system`) plus Loki + Alloy for logs. Dependency updates are a self-hosted Renovate CronJob (`platform/renovate`) that opens PRs against this repo.

## Nodes

| Hostname | Hardware | CPU | RAM | Storage | Role | IP |
|----------|----------|-----|-----|---------|------|-----|
| worker-00 | HP ProDesk Mini G4 | i3-8100T (8th gen, 4C/4T) | 16GB | 128GB NVMe | k3s server + worker (schedulable) | 192.168.30.129 |
| worker-01 | HP ProDesk Mini G9 | i5-12500T (12th gen, 6C/12T) | 24GB | 512GB NVMe + 12TB USB HDD | k3s server + worker, NFS server, media workloads (label, no taint) | 192.168.30.194 |
| worker-02 | HP ProDesk Mini G6 | i5-10500T (10th gen, 6C/12T) | 16GB | 256GB NVMe | k3s server + worker (schedulable) | 192.168.30.136 |

worker-01 is the largest node in the cluster on every axis, which is why media lands there and why
it hosts the NFS export. worker-00 is the smallest — 4 cores, no hyperthreading — and is the first
node to feel scheduling pressure.

All 3 nodes are k3s server+worker (HA etcd control plane) and all 3 are normal scheduling candidates. G9 (worker-01) carries a `homelab.io/media=true` label so media apps select it via nodeSelector; it has no taint, so generic workloads use its spare capacity too. See [`docs/archive/g6-migration.md`](docs/archive/g6-migration.md) for the migration details.

**Planned: move the 12TB drive to a dedicated NAS.** Today the 12TB USB disk hangs off worker-01,
which makes that one node both the NFS server and the busiest workload host — a single point of
failure for every `nfs` PVC. Moving it to a NAS separates storage from compute: the NFS server address stops being a node IP, worker-01
becomes an ordinary (if large) media node, and `local-path` volumes get a genuinely independent
second machine behind their backups rather than a second disk on the same box. Nothing in this repo
assumes the move yet — `192.168.30.194` is still hardcoded as the NFS server in media app values
and in `system/nfs-provisioner/`, so that's the surface to change when it happens.

Scheduling changes with it. Today 14 apps carry a hard `nodeSelector` on `homelab.io/media=true`,
which pins them to worker-01 whether or not they need it. Once storage is off the node, only
**Jellyfin** should still favour worker-01 — the i5-12500T is much the strongest transcoder in the
cluster — and it should be a *preference* (`preferredDuringSchedulingIgnoredDuringExecution` node
affinity), not a hard pin, so it can still start if that node is down. Everything else drops the
selector and schedules freely.

Two things to know before doing that. Most of those apps keep a `local-path` config PVC, which pins
the pod to whichever node the volume was provisioned on regardless of the selector — removing the
`nodeSelector` will not actually free them, so treat the two as separate moves. And Jellyfin has no
`/dev/dri` passthrough configured today, so "strongest transcoder" currently means CPU only; wiring
up QuickSync would make the worker-01 preference matter far more than it does now.

---

## Provisioning Nodes

See [`ansible/README.md`](ansible/README.md) for full setup: inventory, vault, and `just provision`. SSH access is over the LAN IP directly (`192.168.30.0/24`).

## Bootstrapping the Cluster

After nodes are provisioned and k3s is up, bootstrap Cilium, ArgoCD, and the root ApplicationSets:

```bash
just bootstrap-diff    # dry-run
just bootstrap         # applies bootstrap/helmfile.yaml
```

This installs, in order: Cilium (CNI), Gateway API CRDs, ArgoCD, and the root chart that generates ArgoCD `ApplicationSet`s for `system/`, `platform/`, and `apps/`. From there, ArgoCD auto-syncs everything else from `main`.

**Bootstrap charts do not auto-apply.** Everything in `bootstrap/` is helmfile, not ArgoCD, so
when Renovate bumps a version there and you merge it, the repo moves and the cluster does not —
run the matching recipe (`just bootstrap-cilium`, `just bootstrap-argocd`, …) to converge. For a
Cilium **minor** bump, follow [the upstream upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/):
run the preflight check first to pre-pull the image (pass `k8sServiceHost`/`k8sServicePort`, since
this cluster is kube-proxy-free), go to the latest patch of the current minor before jumping, and
watch `CiliumAgentDuplicate` while the DaemonSet rolls — see the comment at the top of
`bootstrap/values/cilium.yaml` for why that alert is the one to watch.

See `just --list` for the full set of commands (sealing secrets, wiring up media apps, etc.).

### Post-Bootstrap: Wire Media Apps

Once `apps/` (wave 3) has synced and Sonarr, Radarr, Lidarr, and Prowlarr show healthy in ArgoCD, run:

```bash
just wire-media
```

This sets Sonarr/Radarr/Lidarr root folders and wires Prowlarr → Sonarr/Radarr/Lidarr as linked applications, via each app's REST API. It's a **one-time step**, not a recurring operational task — but the config it writes lives in each arr's `local-path` config PVC, so it does **not** survive losing the node that volume is on; re-run it after a restore. Safe to re-run any time; it checks before it writes.

Three remaining steps stay manual (`just wire-media` prints these as a reminder when it finishes):
- **Jellyfin**: add TV (`/data/media/tv`), Movies (`/data/media/movies`), and Music (`/data/media/music`) libraries via `jellyfin.nik-homelab.dev` → Dashboard → Libraries.
- **Bazarr**: point it at Sonarr (`sonarr.sonarr.svc.cluster.local:8989`) and Radarr (`radarr.radarr.svc.cluster.local:7878`) via `bazarr.nik-homelab.dev` → Settings — Bazarr has no REST API for this, so it can't be scripted.
- **Lidarr**: `just tune-lidarr-quality` applies the FLAC quality thresholds and custom formats.

### Post-Bootstrap: Wire the Seedbox

Private-tracker grabs go to a remote seedbox; public grabs stay on the in-cluster qBittorrent behind gluetun. `just wire-seedbox` configures the arrs' download clients for that split, and `just sync-seedbox` triggers the rclone copy to NFS on demand (it also runs on a CronJob). See [`apps/rclone-seedbox/README.md`](apps/rclone-seedbox/README.md) for host details, seed reaping, and the no-shell debugging trick.

---

## OS Install

Ubuntu Server 26.04 LTS — installed manually from USB.

1. Download the Ubuntu 26.04 LTS Server minimal ISO
2. Flash to USB: `sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=1m status=progress`
3. Boot the node from USB (HP ProDesk: **F10** → select USB)
4. Follow the installer: set hostname, enable OpenSSH, skip snaps
5. Reboot, remove USB

---

## Repo Structure

```
apps/           # user-facing applications (arr stack, jellyfin, immich, nextcloud, vaultwarden, etc.)
platform/       # cluster platform services (sealed-secrets, tailscale, cloudnative-pg, renovate)
system/         # low-level cluster infrastructure (cert-manager, coredns, envoy-gateway,
                #   external-dns, infisical, infisical-operator, kube-system, metrics-server,
                #   nfs-provisioner, vpa, monitoring-system, loki, alloy)
bootstrap/      # one-time helmfile bootstrap (Cilium, ArgoCD, root ApplicationSet)
ansible/        # node provisioning (Ubuntu install, k3s setup) — see ansible/README.md
config/         # manifests rendered from templates by `just build-config` (gitignored)
secrets/        # registry.tsv for the two `just seal` rows; values are gitignored
docs/           # docs/audits/ current investigations, docs/archive/ shipped work kept for the "why"
```

[`docs/archive/`](docs/archive/README.md) holds write-ups for work that's already done — the G6 HA
migration, the 12TB drive's heat investigation, the 2026-07-28 DNS outage follow-ups. They explain
why the cluster is shaped the way it is; the repo itself is the source of truth for current state.

ArgoCD sync waves: `system` (wave 1) → `platform` (wave 2) → `apps` (wave 3). ArgoCD auto-syncs from `main` — merge to main = deploy.

The one exception is `system/coredns/`, which has no `app.yaml` on purpose so the stack
ApplicationSets skip it — its objects must land in `kube-system`, so a standalone Application in
`bootstrap/root/` deploys it instead. Adding an `app.yaml` there would create a second, competing
Application; see [`CLAUDE.md`](CLAUDE.md) for the detail.

See [`CLAUDE.md`](CLAUDE.md) for full conventions (adding an app, storage, secrets, networking).
