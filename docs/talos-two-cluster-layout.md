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
   `ignoreMissingValueFiles`, the `exclude` patterns (stacks and `kube-system-limits`) and
   `preserveResourcesOnDeletion`.
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

Put `cluster:` after the three chart lines. Renovate's regex manager matches `chartName`,
`chartRepo` and `chartVersion` as consecutive lines, and a key between them hides the app from
Renovate without an error.

`both` grows with the migration rather than covering the platform at once. Step 1 is one node
with 8GB, and several components are k3s-specific or pointless on Talos:

| Component | On Talos | Why |
|---|---|---|
| `cert-manager`, `envoy-gateway`, `external-dns`, `infisical-operator`, `infisical`, `longhorn-system`, `metrics-server`, `vpa`, `monitoring-system`, `sealed-secrets`, `kube-system-limits` | `both` from step 1 | Ingress, secrets and storage. `vpa` and `monitoring-system` own CRDs that every other app's `vpa.yaml`, ServiceMonitor and PrometheusRule need, so they can't wait |
| `cloudnative-pg`, `nfs-provisioner`, `descheduler` | `both` from step 2 | Nothing on one node uses them |
| `local-path-provisioner` (new) | `talos` before the first CNPG app moves | k3s bundles `local-path`; Talos has no such StorageClass, and CNPG volumes use it |
| `loki` and `alloy` | `talos`, moved together like an app | Loki's `nfs` PVC path is the same on both clusters; Alloy on Talos has no Loki to push to until then, so Talos ships no logs before the move |
| `node-feature-discovery`, `intel-gpu-plugin` | `talos` with Jellyfin | They exist for the iGPU |
| `blackbox-exporter` | at cutover | It probes the same public URLs from either cluster, so a second copy only duplicates alerts |
| `kured` | never | Talos upgrades through `talosctl`, with no reboot sentinel and no `systemctl` |
| `tailscale`, `renovate` | at cutover (HOM-24) | A second Connector advertises the subnet twice; a second Renovate opens duplicate PRs |

A component given `both` before Talos exists changes nothing on k3s. No component gets `both`
while Talos would mount its `nfs` PVC, because `pathPattern` hands both clusters the same
directory. Infisical's `pg-backup` PVC is the one case inside the `both` set, and it becomes
`.k3s.yaml` (see Bootstrap).

**Pod Security.** Talos enforces Pod Security `baseline` by default and exempts only
`kube-system`; k3s enforces nothing. `stack.yaml` creates namespaces with `CreateNamespace=true`
and no labels, so on Talos the privileged pods in `longhorn-system` and `monitoring-system`
(node-exporter) are rejected at admission. Each such app adds a `namespace.talos.yaml` with
`pod-security.kubernetes.io/enforce: privileged`; `alloy`, `node-feature-discovery` and
`intel-gpu-plugin` need the same when they move. After the first Talos sync,
`kubectl get events -A --field-selector reason=FailedCreate` must show no PodSecurity
rejections.

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
renders chart defaults without an error. Helm merges maps but replaces lists, so an overlay that
changes one entry of a list restates the whole list.

**Raw manifests.** A manifest that differs per cluster splits into `<name>.k3s.yaml` and
`<name>.talos.yaml`, and each cluster excludes the other's files:

```yaml
directory:
  # k3s; the Talos root swaps *.talos.yaml for *.k3s.yaml
  exclude: '{app.yaml,values.yaml,values-*.yaml,*.talos.yaml}'
```

A split always names both halves. A file with no suffix applies to both clusters, so adding
`<name>.talos.yaml` beside a plain `<name>.yaml` deploys both files on Talos. ArgoCD tracks
objects by kind and name, not by file, so renaming `gateway.yaml` to `gateway.k3s.yaml` is a
no-op on k3s.

**Renovate.** `renovate.json` matches only `values.yaml`, for both its regex manager and
helm-values. The PR that adds the first overlay carrying an image tag widens both patterns to
`values(-[a-z0-9]+)?\.yaml`, or Renovate stops updating that tag.

## Rule 3: orphan, don't delete

Every ApplicationSet-generated Application carries `resources-finalizer.argocd.argoproj.io`; the
three standalone Applications in `bootstrap/root/templates/` don't. Today, an app that drops out
of an ApplicationSet gets its Application deleted, and the finalizer then deletes every resource
it owned. `longhorn` and `nfs` PVs are `Retain` and survive that, but CNPG's `local-path`
volumes are `Delete`, so moving an app to Talos would destroy its k3s database before the
restore.

Set `syncPolicy.preserveResourcesOnDeletion: true` on the ApplicationSets of both clusters;
on Talos it keeps a rollback (`talos` back to `moving`) from cascading. The controller then
stops adding the finalizer and strips it from every Application it still generates on the
next reconcile. An app that drops out in that same reconcile keeps it and cascades, so the
setting must be live first. That behaviour was read from the v3.5.3 source and `main` now ships
v3.6.2, so trust the check rather than the version: before the first move, this must print
nothing:
`kubectl -n argocd get app -o json | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="ApplicationSet" and (.metadata.finalizers // [] | index("resources-finalizer.argocd.argoproj.io"))) | .metadata.name'`

The cost: deleting an app's directory no longer prunes it. Its resources stay until removed by
hand, on either cluster, until cutover reverts the setting.

## The collisions

The audit listed four; the rest turned up while drafting and reviewing this. All are silent.
The platform rows depend on `cluster: both`; without it, a Talos overlay never applies.

| Resource | Collision | Talos answer |
|---|---|---|
| external-dns | `txtOwnerId: homelab` with `policy: sync`; each deletes the other's records | `system/external-dns/values-talos.yaml`: `txtOwnerId: homelab-talos` |
| LB VIP | `cilium-lb-pool.yaml` hands out `192.168.30.200/29`; both clusters would ARP for `.200` | `cilium-lb-pool.k3s.yaml` keeps `.200/29`; `cilium-lb-pool.talos.yaml` holds `.208/32`. Confirm `.208` sits outside OPNsense's DHCP range first. Announcing also needs the node prerequisites under Machine config |
| LAN DNS | OPNsense's Unbound override answers every `*.nik-homelab.dev` name with `.200`, existing or not, so LAN clients and both clusters' pods reach k3s for Talos hostnames | For step 1, exempt `talos.nik-homelab.dev` from the override (`local-zone: "talos.nik-homelab.dev." transparent` in Unbound's custom options). Before the first app moves, delete the override as `docs/unifi-migration.md` plans, after checking OPNsense passes Cloudflare's private-IP answers through. `dig @192.168.30.1 argocd.talos.nik-homelab.dev` must return `.208` |
| cert-manager | both issue the `*.nik-homelab.dev` wildcard from `letsencrypt-prod` | `wildcard-cert.k3s.yaml` keeps today's names; `wildcard-cert.talos.yaml` adds `*.talos.nik-homelab.dev`, so it is a different certificate rather than a duplicate. Staging would serve every moved app an untrusted certificate |
| ACME account | `cluster-issuer.yaml` holds `email: ${LETSENCRYPT_EMAIL}`, which only Ansible or `just build-config` fills in. Talos would register a fresh account with the literal placeholder | `cluster-issuer.k3s.yaml` unchanged; `cluster-issuer.talos.yaml` omits `email`, which ACME doesn't require. Confirm the ClusterIssuer reaches Ready |
| Tailscale | both advertise `192.168.30.0/24` | stays on k3s (rule 1) |
| **Dead-man's switch** | both Alertmanagers ping the same healthchecks.io URL, so a dead k3s pipeline stays green | separate check: `system/monitoring-system/infisical-secret.k3s.yaml` unchanged, `infisical-secret.talos.yaml` the same two secrets with the dead-man's path at `/monitoring-system/deadmanssnitch-url-talos` |
| **Monitoring** | both clusters label every series `cluster: homelab` and page the same ntfy topic, so a page doesn't say which cluster sent it. `scrapeconfig-etcd.yaml` scrapes k3s's etcd by node IP, and `EtcdSnapshotStale` reads k3s's `ETCDSnapshotFile`, so Talos would alert on k3s and fire `absent()` forever | `values-talos.yaml` relabels to `cluster: talos`, drops the `k3s.cattle.io` state metric and its RBAC rule, and sizes Prometheus for an 8GB node. `scrapeconfig-etcd` and `prometheusrule-etcd` split into `.k3s`/`.talos`, the Talos half scraping its own etcd |
| **Renovate** | two runs open duplicate PRs | stays on k3s (rule 1) |
| **Longhorn backups** | both write `nfs://192.168.30.144:/mnt/storage/data/longhorn-backups` and list each other's backups | `system/longhorn-system/values-talos.yaml` pointing at `longhorn-backups-talos`, created on the NAS first (Longhorn can't mount a missing path) |
| **Platform UIs** | `argocd`, `grafana`, `longhorn` and `hubble` exist on both; Talos's external-dns can't take records k3s owns, so Talos's copies have no name | each route splits into `.k3s.yaml` and a `.talos.yaml` on `<name>.talos.nik-homelab.dev`: `system/envoy-gateway/argocd-httproute`, `system/monitoring-system/httproute`, `system/longhorn-system/httproute` and `system/kube-system/hubble-ui-httproute`. Keep the object names, so `longhorn-system/securitypolicy.yaml` still targets `longhorn-ui` |

external-dns's RecordsOutOfSync alert counts the other cluster's TXT records as foreign, so
expect it on both clusters for the whole migration; silence it rather than chase it. Longhorn
at 2 replicas also sits Degraded on step 1's single node; silence its volume alerts on Talos
until step 2.

Shared NFS data is safe under rule 1. The provisioner's `pathPattern` is `namespace/pvc-name`,
so an app recreated on Talos finds its own directory, and only one cluster runs the app at a
time. That holds only while both clusters' `nfs` StorageClass keeps `reclaimPolicy: Retain` and
`archiveOnDelete: false`; otherwise deleting the orphaned k3s PVC wipes the directory Talos uses.

## Bootstrap

`bootstrap/helmfile.yaml` gains a `talos` environment next to `default` (k3s). Each environment
pins its kube context, so a Talos bootstrap can't land on k3s. That needs distinct context names
first: the k3s context is currently called `default`. Talos's Cilium needs its own values
(KubePrism endpoint, cgroup settings, `l2announcements` on `eno1`); those belong to HOM-18.

**Standalone Applications.** The root chart's three standalone Applications have no `app.yaml`,
so rule 1 can't place them; the root chart gates them on its `cluster` value instead.
`coredns-ha` renders on k3s only until verify-item 5 in HOM-17 settles who owns `kube-dns` on
Talos. `intel-gpu-plugin` renders on k3s only until Jellyfin moves; it is kustomize, so an
`exclude` can't split it. `kube-system-limits` renders on both and gets the stacks' `exclude`
pattern, so `system/kube-system/hubble-ui-httproute.yaml` can split.

**No ordering between stacks.** The root chart is a helmfile release, not a parent Application,
and no progressive sync is configured, so the `sync-wave` annotations on the ApplicationSets
order nothing. On a fresh Talos cluster all three stacks sync at once. Anything that must exist
first goes in before `just bootstrap-root`.

**Sealed secrets.** The two rows in `secrets/registry.tsv` (the Infisical bootstrap key and the
operator identity) are sealed to the k3s controller's key. Copy that key into the `sealed-secrets`
namespace on Talos before `just bootstrap-root`: the controller loads existing keys by label at
start, and generates its own if it finds none. `machine-identity.yaml` then unseals on Talos
unchanged.

**Infisical.** The server stays on k3s until it moves like any other app. Talos's operator
reads from it through `https://infisical.nik-homelab.dev`: k3s's
`system/infisical/connection-auth.yaml` uses a cluster-local address Talos can't resolve. That
puts k3s's gateway, cert-manager and external-dns in Talos's secret path, the dependency
`connection-auth.yaml` was written to avoid; Talos accepts it until Infisical moves, and existing
Secrets survive an outage. On Talos:

- `values-talos.yaml` sets `infisical.enabled: false` and `redis.enabled: false`.
- `connection-auth` splits: the `.k3s.yaml` half keeps the cluster-local address, and the
  `.talos.yaml` half points the same-named `infisical-auth` at the URL.
- The server's own pieces become `.k3s.yaml`: `postgres`, `pg-backup`, `infisical-secrets` (the
  sealed `ENCRYPTION_KEY`), `httproute`, `networkpolicy-postgres` and `vpa`.

Every InfisicalSecret references `infisical-auth` in namespace `infisical`, so none of them
changes.

## Machine config

`talos/` holds the Image Factory schematic and the machine-config patches (#177), as audit
Phase 3 describes. The stack generators glob only `<stack>/*/app.yaml`, so ArgoCD never reads
it. Secrets stay out of git, as #177 handles them.

- `talos/schematic.yaml`: the audit's extension table, `siderolabs/nut-client` included.
- `talos/patches/`:
  - Node labels: `homelab.io/ingress=true` on each ingress node, agreeing with
    `envoyDeployment.replicas` and both nodeSelectors (the audit's ingress triple).
  - Storage: Longhorn's `/var/lib/longhorn` user volume now, and the `local-path` kubelet mount
    before the first CNPG move.
  - etcd: `cluster.etcd.extraArgs.listen-metrics-urls`, so `scrapeconfig-etcd.talos.yaml` has a
    target.
  - `ups.yaml` (#187): the `ExtensionServiceConfig` holding `upsmon.conf` with the NAS as primary,
    and `machine.kubelet.extraConfig.shutdownGracePeriodByPodPriority`.

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
names, move the Talos values into `values.yaml`, and drop the selectors, the `cluster` keys and
the root chart's `cluster` gates. Remove `preserveResourcesOnDeletion` so deleting an app's
directory prunes it again, and move the platform UIs back to their plain hostnames.
external-dns needs one deliberate step there: the records carry the `homelab` owner, so Talos
either takes that owner ID once k3s is gone or re-creates the records.
