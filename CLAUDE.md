# Homelab — Claude Code Instructions

## Hardware

| Node | Hardware | Role |
|------|----------|------|
| worker-00 | HP ProDesk Mini G4 | k3s server + worker (schedulable) |
| worker-01 | HP ProDesk Mini G9 — i5 12th gen, 16GB RAM, 12TB USB | k3s server + worker, NFS server, media workloads (`homelab.io/media=true` label, no taint) |
| worker-02 | HP ProDesk Mini G6 | k3s server + worker (schedulable) |

All 3 nodes are k3s server+worker (HA etcd control plane) and all 3 are normal scheduling
candidates. G9 (worker-01) carries a `homelab.io/media=true` label so media apps select it;
it has no taint, so generic workloads use its spare capacity too. See
`.claude/g6-migration.md` for the original migration plan.

## Stack

k3s (3-node HA) + Cilium (VXLAN) + ArgoCD (GitOps) + Envoy Gateway + cert-manager + sealed-secrets + Tailscale

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
platform/       # cluster platform services (sealed-secrets, tailscale, cloudnative-pg)
system/         # low-level cluster infrastructure (cilium, cert-manager, nfs-provisioner, vpa)
bootstrap/      # one-time helmfile bootstrap (Cilium, ArgoCD, root ApplicationSet)
ansible/        # node provisioning (Ubuntu install, k3s setup)
config/         # sealed secrets that live outside app dirs (cert-manager cloudflare token)
```

ArgoCD sync waves: `system` (wave 1) → `platform` (wave 2) → `apps` (wave 3)

ArgoCD auto-syncs from `main` branch. Merge to main = deploy.

**Exception — `system/coredns/`.** The three stack ApplicationSets are git *file* generators
globbing `<stack>/*/app.yaml`, and they hardcode `destination.namespace` to the directory
basename. `system/coredns/` deliberately has no `app.yaml`, so they skip it: it is raw
manifests with no Helm chart, and its objects must land in `kube-system` to back the
existing `kube-dns` Service. It is deployed instead by a standalone Application in
`bootstrap/root/templates/coredns-ha.yaml`, so changes there need `just bootstrap-root`
once; the manifests themselves auto-sync from `main` as usual. Do not add an `app.yaml`
to that directory — it would generate a second, competing Application pointed at
namespace `coredns`.

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
    updateMode: "Recreate"
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

All persistent storage uses the `nfs` StorageClass. Never use `local-path` in new apps — data won't survive node failure. The one exception is a replicated CloudNativePG cluster, where replication provides that durability; see the Rules section.

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

Media apps pin to G9 with a nodeSelector on its label. No toleration is needed — worker-01
carries no taint:
```yaml
controllers:
  main:
    pod:
      nodeSelector:
        homelab.io/media: "true"
```

worker-01 used to carry a `homelab.io/media=true:PreferNoSchedule` taint as well. It was
removed on 2026-07-31: a taint only repels, and the nodeSelector above is what actually
attracts media, so all the taint did was keep the highest-RAM node in the cluster (22.6G vs
14.9G on worker-02) idle while worker-02 filled to 58% memory. Existing media apps still
carry a matching `tolerations:` block; it is now a harmless no-op, so don't copy it into new
apps and feel free to drop it when touching one for another reason.

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

Sealing is table-driven — see `secrets/README.md`. To add a secret: add its plaintext value to `secrets/.secrets` (or mark it `generate:VAR` in the registry if it's an arbitrary internal value, not one from an external system), add a row to `secrets/registry.tsv`, then run `just seal <secret-name>`. No new Justfile recipe needed.

## Common Commands

```bash
just provision          # Run Ansible against all nodes
just bootstrap          # Bootstrap Cilium + ArgoCD + root ApplicationSet
just bootstrap-diff     # Dry-run bootstrap
just seal <name>        # Seal a secret from secrets/registry.tsv (omit name to reseal all)
just todos              # Show remaining TODOs in repo
```

## Rules

- **No `sleep` commands** in scripts or manifests. Use `kubectl wait`, `--timeout`, or readiness probes instead.
- **Never use `Ingress`**. All routing uses Gateway API `HTTPRoute` only.
- Never use `local-path` StorageClass for new PVCs, **except** for replicated databases (CloudNativePG clusters with 2+ instances), where streaming replication — not the volume — provides node-failure durability. NFS is not a supported CNPG configuration. Note `local-path` cannot be expanded in place, so size those volumes correctly up front.
- Never commit `secrets/.secrets`, `secrets/.secrets.generated`, `.vault_pass`, `pub-cert.pem`, or anything in `config/` (gitignored).
- Chart versions in `app.yaml` are managed by Renovate — don't pin to `latest`.
- Server-side apply only for ArgoCD managed resources (avoids annotation conflicts).
- Never add `Co-Authored-By` lines to commit messages.
