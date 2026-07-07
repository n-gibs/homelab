# Homelab

k3s homelab on HP ProDesk Mini PCs. Ansible provisioning, ArgoCD GitOps.

## Stack

k3s + Cilium (VXLAN) + ArgoCD (GitOps) + Envoy Gateway + cert-manager + sealed-secrets + Tailscale (remote admin access)

## Nodes

| Hostname | Hardware | Role | IP |
|----------|----------|------|-----|
| worker-00 | HP ProDesk Mini G4 | k3s server | 192.168.30.129 |
| worker-01 | HP ProDesk Mini G9 — i5 12th gen, 16GB RAM, 12TB USB | k3s server + NFS server + media workloads | 192.168.30.194 |
| worker-02 | HP ProDesk Mini G6 | **not yet provisioned** | — |

See `.claude/g6-migration.md` for the plan to bring `worker-02` online and convert the cluster to a 3-node HA control plane.

---

## Provisioning Nodes

See [`ansible/README.md`](ansible/README.md) for full setup: inventory, vault, and `just provision`.

## Bootstrapping the Cluster

After nodes are provisioned and k3s is up, bootstrap Cilium, ArgoCD, and the root ApplicationSets:

```bash
just bootstrap-diff    # dry-run
just bootstrap         # applies bootstrap/helmfile.yaml
```

This installs, in order: Cilium (CNI), Gateway API CRDs, ArgoCD, and the root chart that generates ArgoCD `ApplicationSet`s for `system/`, `platform/`, and `apps/`. From there, ArgoCD auto-syncs everything else from `main`.

See `just --list` for the full set of commands (sealing secrets, wiring up media apps, etc.).

---

## OS Install

Ubuntu Server 26.04 LTS — installed manually from USB.

1. Download the Ubuntu 26.04 LTS Server minimal ISO
2. Flash to USB: `sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=1m status=progress`
3. Boot the node from USB (HP ProDesk: **F10** → select USB)
4. Follow the installer: set hostname, enable OpenSSH, skip snaps
5. Reboot, remove USB, then install Tailscale for remote access: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`

---

## Repo Structure

```
apps/           # user-facing applications (arr stack, jellyfin, vaultwarden, etc.)
platform/       # cluster platform services (external-secrets, sealed-secrets, tailscale)
system/         # low-level cluster infrastructure (cilium, cert-manager, nfs-provisioner, vpa)
bootstrap/      # one-time helmfile bootstrap (Cilium, ArgoCD, root ApplicationSet)
ansible/        # node provisioning (Ubuntu install, k3s setup) — see ansible/README.md
config/         # sealed secrets that live outside app dirs (gitignored)
```

ArgoCD sync waves: `system` (wave 1) → `platform` (wave 2) → `apps` (wave 3). ArgoCD auto-syncs from `main` — merge to main = deploy.

See [`CLAUDE.md`](CLAUDE.md) for full conventions (adding an app, storage, secrets, networking).
