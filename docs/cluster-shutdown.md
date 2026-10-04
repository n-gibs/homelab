# Shutting down and restarting the whole homelab

Use this when every node and the NAS lose power on purpose: a house move, building work, an
electrical job. The order is workloads, then nodes, then the NAS, and the reverse on the way back.

Powering the nodes off without the quiesce would probably survive. It risks Longhorn replica
rebuilds and a dirty stop for SQLite and Postgres, and the quiesce costs about fifteen minutes.

**Status.** The ArgoCD, scale-down and CronJob steps ran during the NAS cutover
(`nas-migration-checklist.md`). CNPG hibernation and a full three-node power-off have not run on
this cluster yet. Correct this file after the first real run.

## Before you start

- **Window.** Start after 04:30 UTC so the nightly database and Longhorn backups are fresh, and
  stay clear of ~06:00 UTC, when unattended-upgrades restarts things.
- **Backups travel with the hardware.** The database dumps and the Longhorn backupstore live on the
  NAS. Export the Vaultwarden vault to a device that stays out of the box.
- **Access.** `kubectl` from the Mac reaches the cluster through the Tailscale subnet router, which
  runs as a pod. Find its node, and shut that node down last:

  ```bash
  kubectl -n tailscale get pods -o wide
  ```

- **Cabling.** Note which switch ports the nodes and the NAS use. The nodes take DHCP leases, and
  their addresses in `192.168.30.0/24` are hardcoded across this repo.

## Shutting down

### 1. Pause the dead-man's switch

Pause the check in the healthchecks.io UI. Prometheus stops sending `Watchdog` in step 4, and the
check pages once its grace period runs out.

### 2. Stop ArgoCD from healing

`selfHeal` reverts a `kubectl scale` within minutes. Removing `automated` from the three stack
ApplicationSets propagates to every Application they generate.

```bash
for a in system platform apps; do
  kubectl -n argocd patch applicationset "$a" --type json \
    -p '[{"op":"remove","path":"/spec/template/spec/syncPolicy/automated"}]'
done
```

### 3. Suspend the CronJobs

A CronJob that fires mid-shutdown reattaches a volume or mounts NFS.

```bash
kubectl get cronjobs -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name |
  while read -r ns name; do
    kubectl -n "$ns" patch cronjob "$name" -p '{"spec":{"suspend":true}}'
  done
```

### 4. Scale the stateful workloads to zero

Build the list from the live cluster: every Deployment and StatefulSet that mounts a PVC or an NFS
volume. Read the list before piping it into the loop.

```bash
kubectl get deploy,sts -A -o json | jq -r '
  .items[]
  | select(([.spec.template.spec.volumes[]? | select(.persistentVolumeClaim or .nfs)] | length > 0)
           or ((.spec.volumeClaimTemplates // []) | length > 0))
  | select(.metadata.namespace != "nfs-provisioner")
  | select(.metadata.ownerReferences == null)
  | "\(.metadata.namespace) \(.kind | ascii_downcase)/\(.metadata.name)"' |
  while read -r ns res; do kubectl -n "$ns" scale "$res" --replicas=0; done
```

The `ownerReferences` filter drops the Prometheus StatefulSet, which its operator would scale
straight back. Stop Prometheus through its custom resource:

```bash
kubectl -n monitoring-system patch prometheus monitoring-system-kube-pro-prometheus \
  --type merge -p '{"spec":{"replicas":0}}'
```

### 5. Hibernate the Postgres clusters

Hibernation deletes the primary and then the replicas, with no switchover, and keeps every PVC.
The app pods are already gone, so nothing is writing.

```bash
kubectl get clusters.postgresql.cnpg.io -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name |
  while read -r ns name; do
    kubectl -n "$ns" annotate clusters.postgresql.cnpg.io "$name" --overwrite cnpg.io/hibernation=on
  done
kubectl get pods -A -l cnpg.io/cluster    # empty when hibernation finishes
```

Infisical goes down with `infisical-database`. The Secrets it already synced stay in the cluster.

### 6. Wait for Longhorn to detach

Every volume must read `detached` before a node powers off.

```bash
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=PVC:.status.kubernetesStatus.pvcName,STATE:.status.state,ROBUSTNESS:.status.robustness
```

A volume that stays `attached` still has a pod. `kubectl get pods -A -o wide | grep <pvc-namespace>`
finds it.

### 7. Snapshot etcd

k3s already snapshots twice a day. Take one more and copy it off the node. The join
token already lives in the Ansible vault as `vault_k3s_token`.

```bash
ssh homelab@192.168.30.129 'sudo k3s etcd-snapshot save --name pre-shutdown'
ssh homelab@192.168.30.129 \
  'sudo sh -c "cat /var/lib/rancher/k3s/server/db/snapshots/pre-shutdown-*"' > pre-shutdown.etcd
```

### 8. Power off the nodes, then the NAS

No drain and no cordon: the stateful workloads are down, and a cordon would need undoing later.
The API dies when the second node stops, which is expected. Put the subnet-router node last.

```bash
for h in 192.168.30.129 192.168.30.194 192.168.30.136; do
  ssh "homelab@$h" 'sudo shutdown -h now'
done
```

Once all three are dark, shut the NAS down from the TrueNAS UI. **The NAS goes off after the last
node:** these are hard NFS mounts, and a client that outlives the server hangs on its way down.
OPNsense goes last, if it is moving too.

### 9. Pack

- Let the NAS disks spin down before moving the chassis, and pad it.
- worker-02's M.2 has needed a reseat before. If that node fails to boot afterwards, reseat the
  drive before suspecting it.

## Starting up

### 1. Power on in order

1. **OPNsense.** The nodes need their DHCP leases.
2. **The NAS.** Wait until the TrueNAS UI shows the `storage` pool healthy and NFS running.
3. **All three nodes together.** etcd needs two of three members, so one node alone sits `NotReady`.

### 2. Check the platform before restoring sync

```bash
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n longhorn-system get nodes.longhorn.io
kubectl get gateway -A
```

All nodes `Ready`, one Cilium agent per node, every Longhorn node ready and schedulable, the Gateway
`Programmed`. Verify the NFS export from a node: an empty mountpoint looks the same as a working
one until something writes into it.

```bash
ssh homelab@192.168.30.129 \
  'sudo mkdir -p /mnt/test && sudo mount -t nfs4 192.168.30.144:/mnt/storage/data /mnt/test \
     && ls /mnt/test && sudo umount /mnt/test'
```

### 3. Wake the Postgres clusters

```bash
kubectl get clusters.postgresql.cnpg.io -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name |
  while read -r ns name; do
    kubectl -n "$ns" annotate clusters.postgresql.cnpg.io "$name" cnpg.io/hibernation-
  done
kubectl get clusters.postgresql.cnpg.io -A    # wait for 3/3 and "Cluster in healthy state"
```

A replica that stays unready after its node returned sometimes needs its pod deleted a second
time before it re-seeds.

### 4. Restore auto-sync, one stack at a time

`selfHeal` puts the replica counts back, so the order of this loop is the bring-up order. Wait for
each stack to go green in ArgoCD before starting the next.

```bash
kubectl -n argocd patch applicationset system --type json \
  -p '[{"op":"add","path":"/spec/template/spec/syncPolicy/automated","value":{"prune":true,"selfHeal":true}}]'
```

Repeat for `platform`, then `apps`. Then confirm nothing is still at zero:

```bash
kubectl get deploy,sts -A --no-headers | awk '$3 ~ /^0\//'
```

### 5. Unsuspend the CronJobs

`selfHeal` flips back only the CronJobs whose chart renders `suspend:`. Unsuspend all of them,
then check the column is `false` everywhere.

```bash
kubectl get cronjobs -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name |
  while read -r ns name; do
    kubectl -n "$ns" patch cronjob "$name" -p '{"spec":{"suspend":false}}'
  done
kubectl get cronjobs -A
```

### 6. Resume the dead-man's switch

Unpause the healthchecks.io check once Prometheus is up and `Watchdog` is firing. Then open
`https://vault.nik-homelab.dev` and Jellyfin from a client on the LAN: a login page from each
proves DNS, the Gateway, Longhorn, Postgres and NFS in one pass.
