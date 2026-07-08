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

In `ansible/host_vars/worker-02.yml`, ensure no control-plane taint:
```yaml
k3s_server_args: ""   # no --node-taint k3s.io/role=control-plane:NoSchedule
```

```bash
just provision --limit worker-02
kubectl get nodes  # verify worker-02 Ready
```

### 3. Remove control-plane taint from G4

In `ansible/host_vars/worker-00.yml`:
```yaml
k3s_server_args: ""   # remove --node-taint line
```

```bash
kubectl taint node worker-00 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl get nodes  # G4 should now show as schedulable
```

### 4. Add PreferNoSchedule taint to G9

```bash
kubectl taint node worker-01 homelab.io/media=true:PreferNoSchedule
```

Add to Ansible so it survives reprovisioning (`host_vars/worker-01.yml`):
```yaml
k3s_agent_args: "--node-taint homelab.io/media=true:PreferNoSchedule"
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
