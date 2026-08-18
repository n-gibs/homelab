# CloudNativePG

The operator. Four clusters run on it, each 3 instances on `local-path`, one per node:

| namespace | cluster | backed up by |
|---|---|---|
| `immich` | `immich-database` | `apps/immich/pg-backup.yaml` |
| `nextcloud` | `nextcloud-database` | `apps/nextcloud/pg-backup.yaml` |
| `infisical` | `infisical-database` | `system/infisical/` |
| `vaultwarden` | `vaultwarden-database` | `apps/vaultwarden/pg-backup.yaml` |

`local-path` is deliberate and is the CNPG exception in CLAUDE.md: NFS is not a supported
CNPG configuration, and node-failure durability comes from streaming replication across the
three instances rather than from the volume. Disk-failure durability comes from the nightly
`pg_dump` onto worker-01's USB disk. Both halves matter — a cluster that quietly drops to
one streaming replica still serves reads and writes normally while no longer having a
surviving copy of the data.

Monitoring lives in `platform/cloudnative-pg/podmonitor.yaml` (one PodMonitor,
`namespaceSelector: any`, covers every current and future cluster) and
`prometheusrule.yaml`.

## The metrics exporter needs a CONNECT grant, and it is not in git

Each instance runs an in-pod exporter as the `cnpg_metrics_exporter` role. That role needs
`CONNECT` on the application database. Without it every per-database collector query fails:

```
FATAL: permission denied for database "app"
User does not have CONNECT privilege.  (SQLSTATE 42501)
```

**This does not look like a failure.** `cnpg_collector_up` still reports `1`, the Cluster
still reports `Cluster in healthy state`, and the pods stay Ready. What actually happens is
that `cnpg_pg_replication_*`, `pg_stat_database`, `pg_stat_archiver` and `backends` simply
stop being emitted — and an alert that compares a series against a threshold does not fire
when the series is absent, it goes quiet. `nextcloud` sat in exactly this state from at
least 2026-08-03 until 2026-08-12, healthy and completely unmonitored.

`CNPGReplicationMetricsMissing` in `platform/cloudnative-pg/prometheusrule.yaml`
exists to catch this. It uses `unless` rather than a comparison, precisely because the
failure mode is an absent series.

To restore the grant, against the **primary** (replicas are read-only, and
`pg_stat_replication` is empty on them anyway):

```bash
kubectl -n <namespace> get cluster            # read the PRIMARY column
kubectl -n <namespace> exec <primary-pod> -c postgres -- \
  psql -U postgres -c 'grant connect on database app to cnpg_metrics_exporter'
```

Confirm it took — the namespace should appear in:

```bash
# expect one entry per CNPG namespace, each reporting 2
max by (namespace) (cnpg_pg_replication_streaming_replicas)
```

**CNPG has no declarative field for this grant, so it is not in git and it does not survive
a cluster rebuild or a restore into a fresh cluster.** Re-run it after rebuilding any
cluster, and after any restore drill that creates a throwaway cluster you intend to keep.

## Dashboards

`dashboard.yaml` is hand-written, not vendored. Upstream publishes one
([cloudnative-pg/grafana-dashboards](https://github.com/cloudnative-pg/grafana-dashboards/blob/main/charts/cluster/grafana-dashboard.json)),
but it is 66 panels and 253KB, and its template variables assume a metric set this cluster does
not have. Its `operatorNamespace` variable derives from
`controller_runtime_webhook_requests_total{webhook="/mutate-postgresql-cnpg-io-v1-cluster"}`,
which requires scraping the CNPG operator's own controller-runtime metrics; `podmonitor.yaml`
here scrapes only instance pods (`cnpg.io/podRole: instance`), so that series does not exist and
every panel gated behind it comes up empty.

Its per-panel label scheme is also inconsistent across CNPG's own metric set. Collector-level
metrics (`cnpg_collector_up`) carry a native `cluster` label, but pg_stat-derived ones
(`cnpg_backends_total`, `cnpg_pg_replication_lag`) do not, relying instead on a pod-name regex
variable. Fixing that is a redesign per panel, not a datasource-uid rewrite, so six hand-written
panels using this cluster's actual labels (`cnpg_io_cluster`, `cnpg_io_instanceRole`,
`namespace`) is the smaller and more honest fix.

### Why the backup timestamp reads zero

No CNPG Cluster here has a `.spec.backup` stanza and there are zero `Backup`/`ScheduledBackup`
CRs, so `cnpg_collector_last_available_backup_timestamp` reads 0 (unix epoch) on all four
clusters permanently. That is CNPG-native backup never having been configured, by design, not
four backups that failed. The actual backup path is the app-level `pg_dump` CronJobs (see
`apps/*/pg-backup.yaml` and `system/monitoring-system/dashboard-backups.yaml` panel 5), which is
why panel 4 points at that dashboard instead of rendering this metric.
