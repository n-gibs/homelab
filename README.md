# Homelab

k3s homelab on HP ProDesk Mini PCs. Ansible provisioning, ArgoCD GitOps.

## Stack

k3s + Cilium (VXLAN) + ArgoCD (GitOps) + Envoy Gateway + cert-manager + sealed-secrets + Tailscale (in-cluster subnet router for remote access to services — not used for node SSH)

Observability is kube-prometheus-stack (`system/monitoring-system`) plus Loki + Alloy for logs. Dependency updates are a self-hosted Renovate CronJob (`platform/renovate`) that opens PRs against this repo.

## Nodes

| Hostname | Hardware | Role | IP |
|----------|----------|------|-----|
| worker-00 | HP ProDesk Mini G4 | k3s server + worker (schedulable) | 192.168.30.129 |
| worker-01 | HP ProDesk Mini G9 — i5 12th gen, 16GB RAM, 12TB USB | k3s server + worker, NFS server, media workloads (label, no taint) | 192.168.30.194 |
| worker-02 | HP ProDesk Mini G6 | k3s server + worker (schedulable) | 192.168.30.136 |

All 3 nodes are k3s server+worker (HA etcd control plane) and all 3 are normal scheduling candidates. G9 (worker-01) carries a `homelab.io/media=true` label so media apps select it via nodeSelector; it has no taint, so generic workloads use its spare capacity too. See `.claude/g6-migration.md` for the migration details.

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

See `just --list` for the full set of commands (sealing secrets, wiring up media apps, etc.).

### Post-Bootstrap: Wire Media Apps

Once `apps/` (wave 3) has synced and Sonarr, Radarr, and Prowlarr show healthy in ArgoCD, run:

```bash
just wire-media
```

This sets Sonarr/Radarr root folders and wires Prowlarr → Sonarr/Radarr as linked applications, via each app's REST API. It's a **one-time step** — the config it writes lives in each app's NFS-backed PVC and persists across redeploys and node moves — not a recurring operational task. Safe to re-run any time; it checks before it writes.

Two remaining steps stay fully manual (`just wire-media` prints these as a reminder when it finishes):
- **Jellyfin**: add TV (`/data/media/tv`) and Movies (`/data/media/movies`) libraries via `jellyfin.nik-homelab.dev` → Dashboard → Libraries.
- **Bazarr**: point it at Sonarr (`sonarr.sonarr.svc.cluster.local:8989`) and Radarr (`radarr.radarr.svc.cluster.local:7878`) via `bazarr.nik-homelab.dev` → Settings — Bazarr has no REST API for this, so it can't be scripted.

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
                #   external-dns, nfs-provisioner, vpa, monitoring-system, loki, alloy)
bootstrap/      # one-time helmfile bootstrap (Cilium, ArgoCD, root ApplicationSet)
ansible/        # node provisioning (Ubuntu install, k3s setup) — see ansible/README.md
config/         # sealed secrets that live outside app dirs (gitignored)
```

ArgoCD sync waves: `system` (wave 1) → `platform` (wave 2) → `apps` (wave 3). ArgoCD auto-syncs from `main` — merge to main = deploy.

See [`CLAUDE.md`](CLAUDE.md) for full conventions (adding an app, storage, secrets, networking).
