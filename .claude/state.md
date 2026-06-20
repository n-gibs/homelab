# Homelab State

Last updated: June 2026

## Hardware

| Hostname | Hardware | Status | Role |
|----------|----------|--------|------|
| worker-01 | G9 — i5 12th gen, 16GB RAM | Ubuntu installed | k3s agent, 12TB USB drive |
| control-plane-01 | G4 | Ubuntu NOT installed yet | k3s server only (control-plane taint) |
| control-plane-02 | G6 | Arriving this week — commented out in inventory | k3s server + worker (no taint) |
| SilverPeak FWA-ASP1012 | — | OPNsense NOT installed yet | Edge router/firewall |

## Network

- All hardware currently in living room
- Running ethernet to office closet this week
- Will move hardware to closet after ethernet run
- Current subnet: 192.168.1.0/24, worker-01 at 192.168.1.28

## Cluster Design

- G4 (control-plane-01): pure control plane, no workloads, default k3s control-plane taint kept
- G9 (worker-01): worker node, label `homelab.io/storage=true`, general workloads + media
- G6 (control-plane-02): k3s server + worker, no control-plane taint (`host_vars/control-plane-02.yml`)
- 12TB USB on G9 → NFS server at `/mnt/storage` → all media apps mount from 192.168.1.28

## Media App Scheduling

All 5 media apps (jellyfin, sonarr, radarr, qbittorrent, prowlarr) have:
```yaml
controllers:
  main:
    pod:
      nodeSelector:
        homelab.io/storage: "true"
```
This pins them to G9. No taint — other pods can also schedule on G9.

## Stack

k3s + Cilium + ArgoCD + Envoy Gateway + cert-manager + external-secrets + sealed-secrets + Tailscale

## Outstanding TODOs

### Blockers (must do before `just bootstrap`)
- [ ] Fill G4 IP → `ansible/inventory.yml:7`
- [ ] Fill `.secrets` — Cloudflare token, Vaultwarden token, Let's Encrypt email
- [ ] Replace `TODO@example.com` → `system/cert-manager/cluster-issuer.yaml:7,24`

### Post-bootstrap
- [ ] `just seal-cloudflare-token`
- [ ] `just seal-vaultwarden-token`
- [ ] Wire Tailscale OAuth creds → `platform/tailscale/values.yaml`
- [ ] Set VPN provider + seal gluetun creds → `apps/qbittorrent/values.yaml:21`

### When G6 arrives
- [ ] Fill G6 IP
- [ ] Uncomment `control-plane-02` in `ansible/inventory.yml`
- [ ] Uncomment NFS client play in `ansible/site.yml`

## Next Up

OPNsense install on SilverPeak FWA-ASP1012
