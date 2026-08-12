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

Monitoring lives in `system/monitoring-system/podmonitor-cnpg.yaml` (one PodMonitor,
`namespaceSelector: any`, covers every current and future cluster) and
`prometheusrule-cnpg.yaml`.

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

`CNPGReplicationMetricsMissing` in `system/monitoring-system/prometheusrule-cnpg.yaml`
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
