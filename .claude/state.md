# Homelab State

Last updated: June 2026

## Hardware

| Hostname | Hardware | Status | Role |
|----------|----------|--------|------|
| worker-01 | G9 — i5 12th gen, 16GB RAM | Running | k3s agent, 12TB USB drive, NFS server |
| control-plane-01 | G4 | Running | k3s server only (control-plane taint) |
| control-plane-02 | G6 | Running | k3s server + worker (no taint) |
| SilverPeak FWA-ASP1012 | — | OPNsense installed | Edge router/firewall |

## Network

- Hardware in office closet
- Subnet: 192.168.30.0/24 (VLAN), worker-01 at 192.168.30.194
- Pod CIDR: 10.42.0.0/16 (k3s default)
- Service CIDR: 10.43.0.0/16

## Cluster Design

- G4 (control-plane-01): pure control plane, no workloads, default k3s control-plane taint kept
- G9 (worker-01): worker node, label `homelab.io/storage=true`, general workloads + media
- G6 (control-plane-02): k3s server + worker, no control-plane taint (`host_vars/control-plane-02.yml`)
- 12TB USB on G9 → NFS server at `/mnt/storage` → all media apps mount from 192.168.30.194

## Stack

k3s + Cilium (VXLAN tunnel mode) + ArgoCD + Envoy Gateway + cert-manager + external-secrets + sealed-secrets + Tailscale

## Media Stack

All 5 media apps (jellyfin, sonarr, radarr, qbittorrent, prowlarr) pinned to G9 via `homelab.io/storage=true` nodeSelector.

NFS share: `192.168.30.194:/mnt/storage` mounted at `/data` in all media pods.
- `/data/downloads` — qBittorrent download dir
- `/data/media/tv` — Sonarr managed library
- `/data/media/movies` — Radarr managed library

### qBittorrent / Gluetun VPN

- Provider: Mullvad WireGuard (official gluetun provider, not custom)
- Implementation: userspace (required for Cilium eBPF compat)
- MTU: 1170 (physical 1500 → VXLAN -50 → pod eth0 1280 → route 1230 → WG overhead -60)
- DNS: gluetun built-in DNS disabled (`DNS_SERVER=off`), uses cluster CoreDNS (10.43.0.10:53) for musl libc compat
- Allowed IPs: 0.0.0.0/0 only (IPv4, prevents IPv6 route failure)
- qBittorrent bound to tun0 interface (Tools → Options → Advanced → Network interface)
- NFS permissions: initContainer chmods `/data/downloads` and `/data/media` on every pod start

## Outstanding TODOs

### Blockers (must do before `just bootstrap`)
- [x] Fill G4 IP → `ansible/inventory.yml:7`
- [x] Fill `.secrets` — Cloudflare token, Vaultwarden token, Let's Encrypt email
- [x] Replace `TODO@example.com` → `system/cert-manager/cluster-issuer.yaml:7,24`

### Post-bootstrap
- [x] `just seal-cloudflare-token`
- [ ] `just seal-vaultwarden-token`
- [x] Wire Tailscale OAuth creds → `platform/tailscale/values.yaml`
- [x] Set VPN provider + seal gluetun creds → `apps/qbittorrent/values.yaml`

### When G6 arrives
- [x] Fill G6 IP
- [x] Uncomment `control-plane-02` in `ansible/inventory.yml`
- [x] Uncomment NFS client play in `ansible/site.yml`

## Next Up

- Fix Tailscale operator 403 permission error
- Vaultwarden token sealing
- FlareSolverr Turnstile captcha failures (1337x indexer)
