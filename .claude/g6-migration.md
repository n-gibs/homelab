# G6 Migration — HA Cluster Redesign

When G6 arrives, convert all 3 nodes to k3s server+worker (HA control plane) and rework scheduling with taints.

## Target State

| Node | Role | Taint |
|------|------|-------|
| worker-00 (G4) | k3s server + worker | none |
| worker-01 (G9) | k3s server + worker | `homelab.io/media=true:PreferNoSchedule` |
| worker-02 (G6) | k3s server + worker | none |

**Scheduling intent:**
- Media apps → always land on G9 (nodeSelector + toleration)
- System/infra apps → prefer G4/G6, spill to G9 only if needed
- `PreferNoSchedule` (not `NoSchedule`) keeps G9 as overflow — prevents deadlock if G4/G6 fill up

## Steps

### 1. Provision G6

```bash
# Add G6 IP to ansible/inventory.yml under k3s_cluster and k3s_server groups
just provision --limit worker-02
```

### 2. Join G6 as k3s server+worker

`ansible/host_vars/worker-02.yml` is already staged with `extra_server_args: "{{ common_server_flags }}"` (no control-plane taint). Just fill in its real IP in `ansible/inventory.yml` and provision:

```bash
just provision --limit worker-02
kubectl get nodes  # verify worker-02 Ready
```

### 3. Remove control-plane taint from G4

Already staged: `ansible/host_vars/worker00.yml` overrides `extra_server_args` to `{{ common_server_flags }}` (no `--node-taint` line).

```bash
just provision --limit worker-00
kubectl get nodes  # G4 should now show as schedulable
```

### 4. Promote G9 to server + add its taint

Already staged: `ansible/inventory.yml` moves worker-01 into the `server` group, and its `extra_server_args` includes `--node-label homelab.io/media=true --node-taint homelab.io/media=true:PreferNoSchedule`.

worker-01 is currently running as a k3s **agent** — moving it to the `server` group does not stop that. `k3s-agent.service` and `k3s.service` (server) would conflict if both run. Cleanly uninstall the agent first:

```bash
ansible worker-01 -i ansible/inventory.yml -b -m command -a "k3s-agent-uninstall.sh"
just provision --limit worker-01
# k3s only applies --node-label on every agent/server restart, but --node-taint
# only takes effect at *initial* node registration — since worker-01 already
# exists, the taint needs to be applied manually after provisioning:
kubectl taint node worker-01 homelab.io/media=true:PreferNoSchedule
kubectl get nodes --show-labels | grep worker-01  # verify label applied
kubectl describe node worker-01 | grep -A2 Taints  # verify taint applied
```

### 5. Add tolerations to all media apps

Every app in `apps/` that has `nodeSelector: homelab.io/media=true` needs a matching toleration in `values.yaml`:

```yaml
controllers:
  main:
    pod:
      nodeSelector:
        homelab.io/media: "true"
      tolerations:
        - key: homelab.io/media
          operator: Equal
          value: "true"
          effect: PreferNoSchedule
```

Apps to update: jellyfin, sonarr, radarr, qbittorrent, prowlarr, bazarr, recyclarr

### 6. Rebalance

```bash
# Drain G4 to evict pods, then uncordon — scheduler redistributes to G4/G6
kubectl drain worker-00 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon worker-00

kubectl get pods -A -o wide  # verify media on G9, system spread across G4/G6
```

## Rollback

If anything goes wrong before step 6:
```bash
# Re-add control-plane taint to G4
kubectl taint node worker-00 node-role.kubernetes.io/control-plane:NoSchedule

# Remove G9 taint
kubectl taint node worker-01 homelab.io/media=true:PreferNoSchedule-
```
