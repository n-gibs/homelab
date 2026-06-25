# Homelab — Claude Code Instructions

## Hardware

| Node | Hardware | Role |
|------|----------|------|
| control-plane-01 | HP ProDesk Mini G4 | k3s server only (control-plane taint, no workloads) |
| worker-01 | HP ProDesk Mini G9 — i5 12th gen, 16GB RAM, 12TB USB | k3s agent, NFS server, all media workloads |
| control-plane-02 | HP ProDesk Mini G6 | **Ordered — not yet provisioned** |

When G6 arrives, all 3 nodes convert to k3s server+worker with G9 tainted `homelab.io/storage=true:PreferNoSchedule`. See `.claude/g6-migration.md` for full plan.

## Stack

k3s (currently 2-node, 3-node when G6 arrives) + Cilium (VXLAN) + ArgoCD (GitOps) + Envoy Gateway + cert-manager + sealed-secrets + Tailscale

## Network

Cluster lives on its own dedicated interface and subnet on an OPNsense firewall.
- Subnet: `192.168.30.0/24` (VLAN, separate OPNsense interface)
- Pod CIDR: `10.42.0.0/16`, Service CIDR: `10.43.0.0/16`
- Public DNS: `*.nik-homelab.dev` via Cloudflare + external-dns
- NFS server: `192.168.30.194` (worker-01), share at `/mnt/storage`

Any firewall rules, network policies, or IP references must use the `192.168.30.0/24` subnet. Do not assume cluster nodes are on the default network.

## Repo Structure

```
apps/           # user-facing applications (arr stack, jellyfin, vaultwarden, etc.)
platform/       # cluster platform services (external-secrets, sealed-secrets, tailscale)
system/         # low-level cluster infrastructure (cilium, cert-manager, nfs-provisioner, vpa)
bootstrap/      # one-time helmfile bootstrap (Cilium, ArgoCD, root ApplicationSet)
ansible/        # node provisioning (Ubuntu install, k3s setup)
config/         # sealed secrets that live outside app dirs (cert-manager cloudflare token)
```

ArgoCD sync waves: `system` (wave 1) → `platform` (wave 2) → `apps` (wave 3)

ArgoCD auto-syncs from `main` branch. Merge to main = deploy.

## Adding an App

Use the `/add-app` command — it covers placement, required files, patterns, and secrets.

## App File Pattern

Every app directory needs three files:

**`app.yaml`** — Helm chart source (parsed by Renovate for auto-updates):
```yaml
chartName: app-template
chartRepo: https://bjw-s-labs.github.io/helm-charts
chartVersion: 5.0.1
```

**`values.yaml`** — Helm values using bjw-s `app-template` v5 schema.

**`vpa.yaml`** — VerticalPodAutoscaler (all apps get VPA):
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: <app>
  namespace: <app>
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <app>
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

## Storage

All persistent storage uses the `nfs` StorageClass. Never use `local-path` in new apps — data won't survive node failure.

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

Media apps mount the shared NFS data volume directly:
```yaml
  data:
    type: nfs
    server: 192.168.30.194
    path: /mnt/storage
    globalMounts:
      - path: /data
```

NFS path layout on worker-01:
- `/data/downloads` — qBittorrent download dir
- `/data/media/tv` — Sonarr managed library
- `/data/media/movies` — Radarr managed library

Media apps must pin to G9 via nodeSelector:
```yaml
controllers:
  main:
    pod:
      nodeSelector:
        homelab.io/storage: "true"
```

## Media Stack — qBittorrent / Gluetun VPN

- Provider: Mullvad WireGuard via gluetun (official provider, not custom)
- Implementation: userspace WireGuard (required — Cilium eBPF is incompatible with kernel WireGuard)
- MTU: `1170` (accounts for VXLAN + WireGuard overhead stacking)
- DNS: gluetun built-in DNS disabled (`DNS_SERVER=off`), upstream resolver points directly to cluster CoreDNS `10.43.0.10:53` via plain UDP (musl libc compat)
- Firewall outbound subnets: `10.0.0.0/8,192.168.0.0/16` bypass the VPN — required so pod/service CIDR traffic (CoreDNS, cluster services, NFS) reaches the cluster network instead of going through the tunnel
- Allowed IPs: `0.0.0.0/0` only — no IPv6 (prevents IPv6 route failure in Cilium)
- qBittorrent bound to `tun0` interface: Tools → Options → Advanced → Network interface
- NFS permissions: initContainer chmods `/data/downloads` and `/data/media` on every pod start

## Networking (in-cluster)

Ingress via Envoy Gateway HTTPRoutes. All user-facing apps need a route:
```yaml
route:
  main:
    enabled: true
    kind: HTTPRoute
    hostnames:
      - myapp.nik-homelab.dev
    parentRefs:
      - name: homelab
        namespace: envoy-gateway-system
```

Add Homepage dashboard annotations to the route for service discovery:
```yaml
    annotations:
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: "My App"
      gethomepage.dev/description: "Short description"
      gethomepage.dev/group: "Media"   # or "Infrastructure"
      gethomepage.dev/icon: "myapp.png"
      gethomepage.dev/href: "https://myapp.nik-homelab.dev"
```

## Secrets

Secrets are sealed with `kubeseal` using `pub-cert.pem` in repo root. Never commit plaintext secrets.

```bash
kubectl create secret generic my-secret \
  --namespace myapp \
  --from-literal=key="$VALUE" \
  --dry-run=client -o yaml | \
kubeseal --cert pub-cert.pem -o yaml > apps/myapp/my-secret.yaml
```

Source values from `.secrets` (gitignored). Add new `just seal-*` targets in `Justfile` for repeatability.

## Common Commands

```bash
just provision          # Run Ansible against all nodes
just bootstrap          # Bootstrap Cilium + ArgoCD + root ApplicationSet
just bootstrap-diff     # Dry-run bootstrap
just seal-<app>-token   # Seal a secret for an app
just todos              # Show remaining TODOs in repo
```

## Rules

- **No `sleep` commands** in scripts or manifests. Use `kubectl wait`, `--timeout`, or readiness probes instead.
- **Never use `Ingress`**. All routing uses Gateway API `HTTPRoute` only.
- Never use `local-path` StorageClass for new PVCs.
- Never commit `.secrets`, `.vault_pass`, `pub-cert.pem`, or anything in `config/` (gitignored).
- Chart versions in `app.yaml` are managed by Renovate — don't pin to `latest`.
- Server-side apply only for ArgoCD managed resources (avoids annotation conflicts).
