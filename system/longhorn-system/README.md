# Longhorn

Replicated block storage for the SQLite config volumes that used to be pinned to
whichever node `local-path` provisioned them on. Chart from
`https://charts.longhorn.io`, deployed as `system/longhorn-system` at sync wave 1
(same wave as `nfs-provisioner`). All three nodes are storage nodes.

Eight volumes are on it: sonarr, radarr, lidarr, prowlarr, bazarr, navidrome,
cleanuparr configs, and `nextcloud-html-longhorn` (the PHP app tree, not
Nextcloud's data directory). Jellyfin's config PVC is deliberately **not** here —
it stays `local-path` because the pin to worker-01 is what gives it QuickSync,
not an artifact of the old storage layout.

**`longhorn` is never the cluster default StorageClass.** `local-path` keeps that
role so a PVC that omits `storageClassName` — most notably a CNPG cluster — does
not silently land on Longhorn by omission.

## Why 1.11.3, not 1.12.x

1.11.3 shipped a month *after* 1.12.0 and carries fixes 1.12.0 predates:
"PVC resize fails after iscsid restart" (#13413) plus two volume-expansion bugs
(#13411/#13383) — load-bearing here, since `roles/common` now restarts iscsid on
every node and every claim in this repo is deliberately under-sized on the
assumption expansion works.

The trade going the other way: 1.12.0 fixes #13152, a Replica CR leak that needs
`defaultDataLocality: best-effort` plus a recurring job to trigger — exactly this
cluster's configuration, and a bug 1.11.3 does not have the fix for. 1.12.1 is the
first release with both fixes. `renovate.json` has `dependencyDashboardApproval: true`
on this chart specifically so no PR opens (and gets auto-merged) unattended —
upgrading past 1.11.3 is a deliberate decision, not a Renovate merge.

### The #13152 watch

Baseline measured at migration: Replica CRs == 2 × volume count, 16/8, no drift
across the full eight-volume migration plus a forced backup run. Re-check the
count whenever something feels off:

```bash
kubectl -n longhorn-system get replicas.longhorn.io --no-headers | wc -l
kubectl -n longhorn-system get volumes.longhorn.io --no-headers | wc -l
```

A replica count climbing with no new volumes added is #13152 — upgrade to 1.12.1
when that happens. Do **not** "fix" it by turning off `best-effort` locality; that
setting is the fsync-tax mitigation the whole migration was measured against, not
a symptom.

## Settings that fail silently

The chart accepts wrong keys and wrong formats without complaint — read the
Setting/StorageClass back after any values change, never trust "helm template
didn't error":

- **`guaranteedInstanceManagerCPU`** — capital `CPU`, and its value is
  data-engine-keyed JSON, not an integer: `'{"v1":"5","v2":"5"}'`. The lowercase
  `guaranteedInstanceManagerCpu: 5` some drafts of this used is silently ignored
  and the 12% default applies instead — on worker-00 (4 cores, no HT) that's the
  difference between 200m and ~480m reserved per node, before a single volume
  attaches.
- **`backupTarget`** lives under top-level `defaultBackupStore`, not
  `defaultSettings.backupTarget` — the latter key doesn't exist in the chart and
  the value is dropped with no error.
- **`persistence.defaultDataLocality`** is a *separate* key from
  `defaultSettings.defaultDataLocality`. The `defaultSettings` one is the global
  default; `persistence.defaultDataLocality` is what actually gets stamped into
  the `longhorn` StorageClass's own parameters. Without both, every PVC created
  from the class gets `dataLocality: disabled`, silently defeating the fsync
  mitigation.

Verify with the live objects, not the rendered chart:

```bash
kubectl get settings.longhorn.io guaranteed-instance-manager-cpu -n longhorn-system -o yaml
kubectl get sc longhorn -o yaml   # check .parameters.dataLocality
```

## Measured performance

fio, worker-01, 4k random write, `--fdatasync=1`:

| Class | write IOPS | fdatasync avg | fdatasync p99 |
|---|---|---|---|
| local-path | 2294 | 0.43 ms | 0.73 ms |
| longhorn | 530 | 1.86 ms | 2.93 ms |

~4.3× on IOPS, ~4.0× on p99 — inside the "roughly an order of magnitude" bar the
migration was gated on. Confirmed against a real workload, not just fio: zero
`database is locked` errors across 792 album + 76 artist refreshes and a full RSS
sync on Lidarr.

Pinning the fio pods with `nodeName` bypasses the scheduler — the `local-path`
PVC (`WaitForFirstConsumer`) never gets a `selected-node` annotation and sits
Pending forever. Use `nodeSelector: kubernetes.io/hostname` instead; Longhorn
binds `Immediate` and isn't affected either way, so the failure only kills the
baseline half of the comparison.

## Backups

`RecurringJob daily-backup`, 04:30, retain 7, group `default`, target
`nfs://192.168.30.194:/mnt/storage/longhorn-backups`. Longhorn renders this as
**one** Kubernetes CronJob named after the RecurringJob — not one per volume — so
`kubectl -n longhorn-system get cronjob daily-backup` covers all eight.

**A completed Job is not a successful backup.** `kubectl wait --for=condition=complete`
returns clean on a run whose underlying Backup CR is `Error` and whose
backupstore never received the data. Check the actual Backup objects:

```bash
kubectl -n longhorn-system get backups.longhorn.io
```

Anything not `Completed` is a failed backup that the Job's own status will not
tell you about.

The NFS export needed a dedicated `/mnt/storage/longhorn-backups` line, for two
reasons discovered the hard way:

- **Reachability**: a pod on worker-01 connecting to `192.168.30.194` (its own
  node) is not masqueraded by Cilium, so the source address stays a pod IP. The
  export and the host firewall both need to permit the pod CIDR
  (`10.42.0.0/16`), not just the LAN subnet — the arrs' NFS `data` mount never hit
  this because those pods aren't scheduled on worker-01 exclusively.
- **Squash mode must agree with the parent export.** `/mnt/storage` (the main
  share) is `no_root_squash`. The backup directory line was first written as
  `all_squash` to scope pod access away from the 12TB share — but NFSv4 clients
  can resolve through the parent export regardless, so squashing was not
  actually uniform: some clients landed as `root`, others as `nobody`, and a
  root-owned `drwx------` directory then blocked a squashed client's own `mkdir`.
  Both lines are now `no_root_squash`, matching the parent. Pod access is still
  scoped to `/mnt/storage/longhorn-backups` only — the fix was the squash mode,
  not the scope.

## UI

`https://longhorn.nik-homelab.dev`, behind an Envoy Gateway `SecurityPolicy`
basicAuth — the dashboard ships with no login of its own and can delete volumes.

The Secret key **must be literally `.htpasswd`** (Envoy Gateway's requirement),
and Infisical secret names can't start with a dot — hence the `template` block in
`infisical-secret.yaml`, the first use of that field in this repo. Only the SHA
algorithm works for the hash, not bcrypt:

```bash
htpasswd -cbs .htpasswd admin '<password>'
```

Credential lives at Infisical `/longhorn-system/longhorn-ui-auth`, key
`HTPASSWD`.

## ArgoCD interactions

- Settings are chart-managed with `selfHeal: true` — a setting changed in the UI
  reverts within minutes. Change settings in git.
- `deletingConfirmationFlag: false` is what stops deleting this directory (a
  `prune: true` sync) from taking every volume with it.
- `ServerSideApply=true` keeps the large Longhorn CRDs under the annotation size
  limit.
- New files added to this directory need an **Application** hard refresh, not an
  ApplicationSet refresh (which only reloads the generator, not this app's
  manifest list):
  ```bash
  kubectl -n argocd annotate application longhorn-system argocd.argoproj.io/refresh=hard --overwrite
  ```

## Migration runbook (for any future volume)

1. Add the new right-sized PVC alongside the old one (`storageClassName: longhorn`).
2. Scale the app to `replicas: 0`.
3. Trigger the app's own backup (System → Backup, or equivalent) — a second,
   application-consistent copy before touching anything.
4. Run a copy Job mounting both PVCs.
5. Swap the app to `existingClaim: <new-pvc>`.
6. Scale back up.

Verify the copy with file count + byte sum + a checksum of the database file —
**not `du`**. `du` does not match across filesystems (ext4 block allocation vs
`local-path`'s), even on a byte-identical copy; it was off by 200 bytes on a
396MB Lidarr copy for exactly this reason. This did work every time:

```bash
find /old -type f | wc -l; find /old -type f -exec stat -c %s {} + | awk '{s+=$1} END {print s}'
find /new -type f | wc -l; find /new -type f -exec stat -c %s {} + | awk '{s+=$1} END {print s}'
md5sum /old/<app>.db /new/<app>.db
```

If the copy Job image is `alpine`, note busybox's `find` has no `-printf` and its
`diff` has no `--exclude` — the `stat`/`awk` form above works around the first,
and `grep -v` around the second. `xargs` also hits its argument-count limit
around 28k files (Nextcloud's file count) — pipe through `find | wc -l` rather
than `find | xargs stat`.

## Monitoring

`ServiceMonitor` and `PrometheusRule` live in `system/monitoring-system/`, not
here — Prometheus's job label for these targets is `longhorn-backend` (the
Service name), port `manager` (9500).

`longhorn_volume_robustness` is a **one-hot gauge with a `state` label** —
`{state="healthy"} 1`, `{state="degraded"} 0`, etc. — not a numeric enum. An
alert expression like `longhorn_volume_robustness == 2` will never match; the
correct form is:

```
longhorn_volume_robustness{state="degraded"} == 1
```

A **detached** volume reports `{state="unknown"} 1`, not degraded — scaling an
app to zero during a migration does not trip a degraded-volume alert.

## No VPA

Deliberately excluded, unlike every other app in this repo. `instance-manager`
pods have no VPA-targetable owning controller (Longhorn manages them directly),
and restarting one breaks every volume currently attached on that node — the
opposite of what a VPA `Recreate` update mode is supposed to do safely.

## Cleanup gotcha

The `longhorn` StorageClass is `reclaimPolicy: Retain`. Deleting a PVC does
**not** delete the underlying Longhorn volume — it keeps existing, keeps
attaching, and keeps being backed up nightly, invisible from `kubectl get pvc`.
Free it explicitly:

```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system delete volumes.longhorn.io <name>
```

This has already caught two orphaned scratch/bench volumes during this
migration — expect it for the eight old `local-path` PVCs once they're retired.
Unlike Longhorn's `Retain`, the `local-path` class those PVCs use is `Delete` —
so for those eight, removing the PVC from git and letting ArgoCD prune it
destroys the data immediately, with no `Released` PV to reclaim. Confirm each
volume's Longhorn backup exists in the backupstore before that PVC is removed.

## Dashboards

`dashboard.yaml` is fed by the longhorn-backend scrape that
`networkpolicy-monitoring.yaml` unblocks. Before that NetworkPolicy the scrape was dead and
every `longhorn_*` series was empty. The question it answers is whether the volumes underneath
the control plane are healthy, current, and backed up, not whether the Longhorn UI is reachable.

Panel 2 (engine images in use) exists because a Longhorn chart bump upgrades the manager and
reports green while existing volumes keep running their old engine image until each one is
individually upgraded. The control plane and the data plane can silently disagree.

Panel 6 (scrape health) exists because a dead scrape is invisible: a dashboard fed by one
renders identically to a healthy idle cluster. Below 3 targets up means the rest of the
dashboard is stale, not quiet.
