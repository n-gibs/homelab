# Two clusters, one repo

How this repo deploys to k3s and Talos at the same time during the migration, without either
cluster touching what the other owns. Covers HOM-19; the migration order lives in
`docs/talos-migration-audit.md`.

Both clusters run an ArgoCD that syncs this repo's `main`. Three rules keep them apart:

1. **Each app lives on exactly one cluster,** chosen by one line in its `app.yaml`.
2. **A file or values overlay named for a cluster applies only to that cluster.** That is
   where the collisions get their per-cluster answer.
3. **Leaving a cluster orphans an app's resources instead of deleting them.** Moving an app
   never destroys its volumes.

The ApplicationSet templates on k3s change, but the resources k3s deploys stay the same, so this
can merge before the Talos cluster exists.

## Rule 1: one line picks the cluster

The three stack ApplicationSets glob `<stack>/*/app.yaml`, and every key in that file becomes
a generator parameter. Add `cluster: talos` to move an app; leave it out to stay on k3s. Each
ApplicationSet gets a post-selector on that key:

```yaml
# k3s root: everything not claimed by Talos or mid-move. NotIn also matches files with no
# `cluster` key, so today's apps need no edit.
selector:
  matchExpressions:
    - {key: cluster, operator: NotIn, values: [talos, moving]}

# Talos root: only what has moved.
selector:
  matchExpressions:
    - {key: cluster, operator: In, values: [talos]}
```

Put `cluster:` after the three chart lines. Renovate's regex manager matches `chartName`,
`chartRepo` and `chartVersion` as consecutive lines, and a key between them hides the app from
Renovate without an error.

Tailscale and Renovate never get `cluster: talos` until cutover (HOM-24), so the Talos cluster
never advertises the subnet or opens duplicate PRs.

## Rule 2: overlays named for a cluster

The root chart gains one value, `cluster: k3s` or `cluster: talos`, and passes it into each
ApplicationSet template in two places.

**Helm values.** Each app keeps its `values.yaml` and may add `values-<cluster>.yaml`:

```yaml
helm:
  valueFiles:
    - $values/{{path}}/values.yaml
    - $values/{{path}}/values-{{ .Values.cluster }}.yaml
  ignoreMissingValueFiles: true
```

**Raw manifests.** A manifest that differs per cluster splits into `<name>.k3s.yaml` and
`<name>.talos.yaml`, and each cluster excludes the other's files:

```yaml
directory:
  # k3s; the Talos root swaps *.talos.yaml for *.k3s.yaml
  exclude: '{app.yaml,values.yaml,values-*.yaml,*.talos.yaml}'
```

ArgoCD tracks objects by kind and name, not by file, so renaming `gateway.yaml` to
`gateway.k3s.yaml` is a no-op on k3s.

## Rule 3: orphan, don't delete

36 of the 39 Applications carry `resources-finalizer.argocd.argoproj.io`. Today, an app that
drops out of an ApplicationSet gets its Application deleted, and the finalizer then deletes
every resource it owned, including Longhorn PVCs and their data. Moving an app to Talos would
destroy its k3s state before the restore.

Set `syncPolicy.preserveResourcesOnDeletion: true` on the k3s ApplicationSets. The controller
then stops adding the finalizer. Check whether it also strips the finalizer from existing
Applications; if not, remove it by hand before moving the first app.

## The collisions

The audit listed four. Three more turned up while drafting this, all silent.

| Resource | Collision | Talos answer |
|---|---|---|
| external-dns | `txtOwnerId: homelab` with `policy: sync`; each deletes the other's records | `system/external-dns/values-talos.yaml`: `txtOwnerId: homelab-talos` |
| LB VIP | `cilium-lb-pool.yaml` hands out `192.168.30.200/29`; both clusters would ARP for `.200` | `cilium-lb-pool.talos.yaml` with `.201/32` |
| cert-manager | `gateway.yaml` and `wildcard-cert.yaml` both name `letsencrypt-prod`; Let's Encrypt allows 5 duplicate certificates a week | `.talos.yaml` copies of both naming `letsencrypt-staging` |
| Tailscale | both advertise `192.168.30.0/24` | stays on k3s (rule 1) |
| **Dead-man's switch** | both Alertmanagers ping the same healthchecks.io URL, so a dead k3s pipeline stays green | separate check; `deadmanssnitch-url` read from a Talos-only Infisical path |
| **Renovate** | two runs open duplicate PRs | stays on k3s (rule 1) |
| **Longhorn backups** | both write `nfs://192.168.30.144:/mnt/storage/data/longhorn-backups` and list each other's backups | `system/longhorn-system/values-talos.yaml` pointing at `longhorn-backups-talos` |

Shared NFS data is safe under rule 1. The provisioner's `pathPattern` is `namespace/pvc-name`,
so an app recreated on Talos finds its own directory, and only one cluster runs the app at a
time.

## Bootstrap

`bootstrap/helmfile.yaml` gains a `talos` environment next to `default` (k3s). Each environment
pins its kube context, so a Talos bootstrap can't land on k3s. That needs distinct context names
first: the k3s context is currently called `default`. Talos's Cilium needs its own
values (KubePrism endpoint, cgroup settings); those belong to HOM-18.

The root chart's standalone Applications split by cluster. `coredns-ha` stays k3s-only until
verify-item 5 in HOM-17 settles who owns `kube-dns` on Talos.

**Sealed secrets.** The two rows in `secrets/registry.tsv` (the Infisical bootstrap key and the
operator identity) are sealed to the k3s controller's key. Restore that key into the Talos
cluster before ArgoCD syncs `platform`, or reseal both rows for Talos.

## Moving an app

An app never runs on both clusters at once, because both would write the same NFS directories.
`cluster: moving` matches neither selector and holds it in between.

1. Set `cluster: moving` and merge. k3s drops the Application and leaves its resources running.
   With no Application left, selfHeal no longer reverts a scale-down.
2. Scale it to zero on k3s, then take its own backup to the NAS.
3. Set `cluster: talos` and merge. Talos creates it.
4. Restore from the backup on Talos and verify.
5. Delete the orphaned k3s resources by hand, including its HTTPRoute. While that route
   exists, k3s's external-dns keeps the hostname pointing at `.200`.

## Cutover

HOM-24 collapses the overlays. Delete every `*.k3s.yaml`, rename `*.talos.yaml` back to plain
names, move the Talos values into `values.yaml`, and drop the selectors and the `cluster` keys.
external-dns needs one deliberate step there: the records carry the `homelab` owner, so Talos
either takes that owner ID once k3s is gone or re-creates the records.
