# Two clusters, one repo

How this repo deploys to k3s and Talos at the same time during the migration, without either
cluster touching what the other owns. Covers HOM-19; the migration order lives in
`docs/talos-migration-audit.md`.

Both clusters run an ArgoCD that syncs this repo's `main`. Three rules keep them apart:

1. **One line in `app.yaml` picks the cluster:** k3s, Talos, or both. An app holding state
   runs on exactly one.
2. **A file or values overlay named for a cluster applies only to that cluster.** That is
   where the collisions get their per-cluster answer.
3. **Leaving a cluster orphans an app's resources instead of deleting them.** Moving an app
   never destroys its volumes.

The ApplicationSet templates on k3s change, but the resources k3s deploys stay the same, so this
can merge before the Talos cluster exists. Prove that before relying on it:

1. `helmfile diff` on the root release shows only the selector, the second `valueFiles` entry,
   `ignoreMissingValueFiles`, the `exclude` pattern and `preserveResourcesOnDeletion`.
2. Apply with `just bootstrap-root`, refresh, and confirm every Application stays Synced with no
   resource changed. An app that goes OutOfSync means an overlay matched on k3s.
3. Run the finalizer check under rule 3; it must print nothing.

## Rule 1: one line picks the cluster

The three stack ApplicationSets glob `<stack>/*/app.yaml`, and every key in that file becomes
a generator parameter. `cluster: talos` moves an app; `cluster: both` runs it on each cluster;
no key keeps it on k3s. Each ApplicationSet gets a post-selector on that key, under
`spec.generators[].selector` next to `git:`:

```yaml
# k3s root: everything not claimed by Talos or mid-move. NotIn also matches files with no
# `cluster` key, so today's apps need no edit.
selector:
  matchExpressions:
    - {key: cluster, operator: NotIn, values: [talos, moving]}

# Talos root: what has moved, plus what runs on both.
selector:
  matchExpressions:
    - {key: cluster, operator: In, values: [talos, both]}
```

`both` is for the platform each cluster needs its own copy of: everything under `system/`
except `loki`, plus `cloudnative-pg` and `sealed-secrets`. Nothing with an `nfs` PVC gets it,
because `pathPattern` hands both clusters the same directory. Loki keeps its chunks at
`loki/storage-loki-0`, so it moves like an app, and Talos ships no logs until it does. A
component given `both` before Talos exists changes nothing on k3s.

Put `cluster:` after the three chart lines. Renovate's regex manager matches `chartName`,
`chartRepo` and `chartVersion` as consecutive lines, and a key between them hides the app from
Renovate without an error.

Tailscale and Renovate never get `cluster: talos` or `both` until cutover (HOM-24), so the Talos
cluster never advertises the subnet or opens duplicate PRs.

## Rule 2: overlays named for a cluster

The root chart gains one value, `cluster: k3s` or `cluster: talos`, and passes it into each
ApplicationSet template in two places.

**Helm values.** Each app keeps its `values.yaml` and may add `values-<cluster>.yaml`:

```yaml
helm:
  valueFiles:
    - $values/{{`{{path}}`}}/values.yaml
    - $values/{{`{{path}}`}}/values-{{ $.Values.cluster }}.yaml
  ignoreMissingValueFiles: true
```

As written in `stack.yaml`: the backticks keep Helm off ArgoCD's `{{path}}`, and `$.` is needed
inside `range $stack`. `ignoreMissingValueFiles` covers `values.yaml` too, so a misnamed one
renders chart defaults without an error.

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
every resource it owned. `longhorn` and `nfs` PVs are `Retain` and survive that, but CNPG's
`local-path` volumes are `Delete`, so moving an app to Talos would destroy its k3s database
before the restore.

Set `syncPolicy.preserveResourcesOnDeletion: true` on the ApplicationSets of both clusters;
on Talos it keeps a rollback (`talos` back to `moving`) from cascading. The controller then
stops adding the finalizer and strips it from every Application it still generates on the
next reconcile. An app that drops out in that same reconcile keeps it and cascades, so the
setting must be live first. Before the first move, this must print nothing:
`kubectl -n argocd get app -o json | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="ApplicationSet" and (.metadata.finalizers // [] | index("resources-finalizer.argocd.argoproj.io"))) | .metadata.name'`

The cost: deleting an app's directory no longer prunes it. Its resources stay until removed by
hand, on either cluster, until cutover reverts the setting.

## The collisions

The audit listed four. Four more turned up while drafting and reviewing this, all silent. The
platform rows depend on `cluster: both`; without it, a Talos overlay never applies.

| Resource | Collision | Talos answer |
|---|---|---|
| external-dns | `txtOwnerId: homelab` with `policy: sync`; each deletes the other's records | `system/external-dns/values-talos.yaml`: `txtOwnerId: homelab-talos` |
| LB VIP | `cilium-lb-pool.yaml` hands out `192.168.30.200/29`; both clusters would ARP for `.200` | `cilium-lb-pool.talos.yaml` with `.208/32`, outside the k3s pool, so k3s needs no change |
| cert-manager | both issue the `*.nik-homelab.dev` wildcard from `letsencrypt-prod` | `wildcard-cert.talos.yaml` stays on `letsencrypt-prod` and adds `*.talos.nik-homelab.dev`. Staging would serve every moved app an untrusted certificate. Let's Encrypt allows 5 duplicates a week; the two clusters need about 2 |
| Tailscale | both advertise `192.168.30.0/24` | stays on k3s (rule 1) |
| **Dead-man's switch** | both Alertmanagers ping the same healthchecks.io URL, so a dead k3s pipeline stays green | separate check; `system/monitoring-system/infisical-secret.talos.yaml` reads `/monitoring-system/deadmanssnitch-url-talos` |
| **Renovate** | two runs open duplicate PRs | stays on k3s (rule 1) |
| **Longhorn backups** | both write `nfs://192.168.30.144:/mnt/storage/data/longhorn-backups` and list each other's backups | `system/longhorn-system/values-talos.yaml` pointing at `longhorn-backups-talos`, created on the NAS first (Longhorn can't mount a missing path) |
| **Platform UIs** | `argocd`, `grafana`, `longhorn`, `hubble` and `headlamp` exist on both; Talos's external-dns can't take records k3s owns, so Talos's copies have no name | `.talos.yaml` routes on `<name>.talos.nik-homelab.dev` |

external-dns's RecordsOutOfSync alert counts the other cluster's TXT records as foreign, so
expect it on both clusters for the whole migration; silence it rather than chase it.

Shared NFS data is safe under rule 1. The provisioner's `pathPattern` is `namespace/pvc-name`,
so an app recreated on Talos finds its own directory, and only one cluster runs the app at a
time. That holds only while both clusters' `nfs` StorageClass keeps `reclaimPolicy: Retain` and
`archiveOnDelete: false`; otherwise deleting the orphaned k3s PVC wipes the directory Talos uses.

## Bootstrap

`bootstrap/helmfile.yaml` gains a `talos` environment next to `default` (k3s). Each environment
pins its kube context, so a Talos bootstrap can't land on k3s. That needs distinct context names
first: the k3s context is currently called `default`. Talos's Cilium needs its own
values (KubePrism endpoint, cgroup settings); those belong to HOM-18.

The root chart's standalone Applications split by cluster. `coredns-ha` stays k3s-only until
verify-item 5 in HOM-17 settles who owns `kube-dns` on Talos.

**Infisical.** The server stays on k3s until it moves like any other app. Talos's operator
reads from it through `https://infisical.nik-homelab.dev`: k3s's
`system/infisical/connection-auth.yaml` uses a cluster-local address Talos can't resolve.
`system/infisical` gets `cluster: both`; on Talos, `values-talos.yaml` turns the server off,
`connection-auth.talos.yaml` points the same-named `infisical-auth` at that URL, and the CNPG
cluster and `pg-backup.yaml` become `.k3s.yaml`. Every InfisicalSecret references
`infisical-auth` in namespace `infisical`, so none of them changes. Until Infisical moves,
Talos's secret refresh depends on k3s's gateway; existing Secrets survive an outage.

**Sealed secrets.** The two rows in `secrets/registry.tsv` (the Infisical bootstrap key and the
operator identity) are sealed to the k3s controller's key. Talos needs only the operator identity
until the server moves. Restore the k3s controller's key into Talos before ArgoCD syncs
`platform`, or reseal that row for Talos.

## Moving an app

An app never runs on both clusters at once, because both would write the same NFS directories.
`cluster: moving` matches neither selector and holds it in between.

1. Set `cluster: moving` and merge. k3s drops the Application and leaves its resources running.
   With no Application left, selfHeal no longer reverts a scale-down.
2. Scale it to zero on k3s, then take its own backup to the NAS.
3. Set `cluster: talos` and merge. Talos creates it. For a CNPG app, the same merge adds a
   `values-talos.yaml` holding the app at zero replicas, and you suspend Talos's `pg-backup`
   CronJob as soon as it exists (`pg-backup.yaml` doesn't render `suspend`, so selfHeal leaves
   it). Otherwise its first run drops an empty-database dump beside the real ones.
4. Restore from the backup on Talos and verify. Then remove the zero-replica override and
   unsuspend the CronJob.
5. Delete the orphaned k3s resources by hand, including its HTTPRoute. While that route
   exists, k3s's external-dns keeps the hostname pointing at `.200`.

qBittorrent's `fix-perms` init container runs `chmod -R 777` over `/data/downloads` and
`/data/media` on every start, so its first start on Talos rewrites modes across the shared
library. That is expected; a checksum or diff afterwards shows `p` flags, not a fault.

## Cutover

HOM-24 collapses the overlays. Delete every `*.k3s.yaml`, rename `*.talos.yaml` back to plain
names, move the Talos values into `values.yaml`, and drop the selectors and the `cluster` keys.
Remove `preserveResourcesOnDeletion` so deleting an app's directory prunes it again, and move
the platform UIs back to their plain hostnames. external-dns needs one deliberate step there:
the records carry the `homelab` owner, so Talos either takes that owner ID once k3s is gone or
re-creates the records.
