# monitoring-system

## Dashboards

Four dashboards live here: `dashboard-media-stack.yaml`, `dashboard-backups.yaml`,
`dashboard-cronjobs.yaml`, and `dashboard-temperatures.yaml`. The Grafana sidecar picks all of
them up by label (`LABEL=grafana_dashboard`, `LABEL_VALUE=1`, `NAMESPACE=ALL`), which is also
why dashboards for subjects that own a directory (vpa, longhorn-system, envoy-gateway,
blackbox-exporter, cloudnative-pg) live beside the scrape config that feeds them instead of
here. This directory holds the dashboards whose subject has no directory of its own (cilium,
etcd, argocd) or spans several.

The sidecar has no `FOLDER_ANNOTATION`, so a `grafana_folder` annotation is silently ignored
and every dashboard lands in the default folder.

### dashboard-media-stack.yaml

Scope is health and capacity, not application internals. None of the *arr apps, Jellyfin, or
qBittorrent export Prometheus metrics, so queue depth, download rate, and indexer health are
not available: that needs exportarr plus an API key per app. Every panel here reads signals
that already exist (cAdvisor, kube-state-metrics, node-exporter, Loki).

The `$media` variable is the single place the namespace list lives. Every panel derives from it.

Two traps worth knowing before editing:

- **`kubelet_volume_stats_*` is useless for these apps.** Every media PVC is NFS-backed, so
  each one reports the whole 12TB filesystem's usage, and all eight report an identical 2.9TB.
  The library panels read `node_filesystem` on worker-01 instead, selected by `fstype="xfs"` so
  they hit the local disk rather than the two nfs4 client mounts of the same path.
- **node-exporter is a DaemonSet**, so its pod label changes on every restart and
  `node_filesystem_*` quietly becomes several overlapping series for one device. Without the
  `max()` wrapper, `predict_linear` returns one divergent projection per historical pod.

### dashboard-backups.yaml

Companion to `prometheusrule-backups.yaml`, answering a different question. The rule file is
what should wake you up; this dashboard answers "did last night's backups actually run" in one
place, spanning the CronJob-based database dumps and Longhorn volume snapshots.

It stays separate from `dashboard-cronjobs.yaml` deliberately. Panel 4 (Longhorn) has no
equivalent there at all: that dashboard has nothing keyed on `longhorn_backup_state`. Panel 5
does read the same `kube_cronjob_status_last_successful_time`, but reduced to a single
worst-case number across the CNPG-backed apps' CronJobs rather than a per-job view, an "is
anything stale" check a per-job table cannot give at a glance.

Panel 1's own description covers why it borrows `CronJobNotSucceeding`'s 24h/26h window instead
of `CronJobOverdue`'s. Keep that window in sync if the rule's `> 26 * 3600` changes.

Panel 5 tracks the `pg_dump` CronJobs, not CNPG's own backup machinery. No CNPG Cluster here
has a `.spec.backup` stanza, so `cnpg_collector_last_available_backup_timestamp` stays 0
forever by design rather than by failure (see `platform/cloudnative-pg/README.md`). The real
backup path for CNPG-backed apps is the same `*-db-backup` CronJobs panel 1 already lists, so
panel 5 borrows `CronJobNotSucceeding`'s 26h threshold directly, since that is the alert
actually keying on this metric.

### dashboard-cronjobs.yaml

Also a companion to `prometheusrule-backups.yaml`. It answers the questions an alert cannot: is
the dump growing or has it quietly collapsed, are runs getting slower, did a job fail and then
pass on retry.

The dump-size panel is the reason this dashboard is worth having. Every alert proves a job ran
and exited zero; none of them prove it wrote a usable file. `pg_dump` exiting zero after
producing a truncated dump is the failure that stays invisible until a restore, and a size
series is the cheapest thing that shows it. The values are parsed straight out of the job's own
`wrote <path> (N bytes)` log line, because a PVC-usage metric cannot help: the backup PVCs are
NFS-backed and each reports the whole 12TB filesystem.

Job-level metrics are keyed by `job_name`, which carries a per-run timestamp suffix, so every
panel joins through `kube_job_owner` to group runs under the owning CronJob. Without that join,
each nightly run is its own unrelated series.

### dashboard-temperatures.yaml

Answers "is it getting worse?", which the alerts and the Homepage widget cannot. A common-mode
step across all three nodes at once (a room move cost 2-5C everywhere) is only legible on a
shared time axis.

Thresholds mirror `prometheusrule-temperature.yaml` (crit-12 warning, crit-5 critical) so the
colours change where the alerts fire. Keep them in sync.
