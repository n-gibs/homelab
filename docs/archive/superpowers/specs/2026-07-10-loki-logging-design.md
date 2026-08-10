# Add Loki log aggregation, wired into Grafana

## Context

`system/monitoring-system` runs `kube-prometheus-stack` (Prometheus + Grafana), giving metrics but no centralized log aggregation — logs are only reachable via `kubectl logs` per pod. This adds Loki to collect and store logs cluster-wide, with Grafana able to query them via Explore.

## Research

Verified against the live charts (`helm show values`, `helm template`) rather than assumed, since Grafana's logging stack moved around a lot in the last year:

- **`loki-stack`** (the old bundled Loki+Promtail chart) is deprecated and does not support Alloy as an agent — ruled out.
- **The Loki Helm chart itself moved**, effective 2026-03-16, from `grafana/loki` to `grafana-community/loki` (`https://grafana-community.github.io/helm-charts`); the old repo now only maintains the chart for GEL (Grafana Enterprise Logs) customers. Chart numbering reset — current version is `18.4.4`.
- **Promtail is deprecated/EOL** (removed from Loki as of 3.7.3, functionality merged into Alloy) — Alloy is the only actively maintained log-shipping agent going forward.
- **`loki.source.kubernetes`** (an Alloy component) tails Pod logs via the Kubernetes API rather than reading node-local log files. This means Alloy can run as a single `Deployment` replica instead of a per-node `DaemonSet`, with no privileged container, no root user, and no hostPath mount — a smaller footprint and smaller blast radius than the traditional Promtail-style agent, at the cost of a bit more Kubelet/API-server load (a non-issue at 3-node homelab scale).
- Rendered the `grafana-community/loki` chart locally in `Monolithic` mode with `storage.type: filesystem` to confirm the generated `schema_config`/`storage_config`/`compactor` actually come out correct (TSDB schema v13, `object_store: filesystem`, `delete_request_store: filesystem`, `retention_enabled: true`, `retention_period: 168h`) — filesystem storage for monolithic mode is officially supported, object storage is only a "recommended for production" suggestion.
- The default chart also enables `gateway` (an nginx proxy in front of Loki, only useful for the scalable/distributed deployment modes), `minio` (deprecated, removed 2026-10-31), and memcached-backed `chunksCache`/`resultsCache`. All four are irrelevant at single-instance scale and add pods for no benefit — disabled. `lokiCanary` (a lightweight per-node synthetic-log DaemonSet that verifies the pipeline end-to-end) was left enabled — the chart's Helm test hook requires it, and it's a legitimate cheap health check.
- Rendered the `grafana/alloy` chart (`1.10.1`, still on the original `grafana` repo — not affected by the March migration) with `controller.type: deployment` to confirm the chart's default `ClusterRole` already grants `pods`/`pods/log` `get`/`list`/`watch` — no RBAC changes needed for `loki.source.kubernetes` to work.
- `kube-prometheus-stack`'s Grafana subchart supports `grafana.additionalDataSources` (a plain array in `values.yaml`) — the standard way to add a datasource without a separate provisioning ConfigMap or cross-namespace sidecar `searchNamespace: ALL` change.
- Confirmed via `bootstrap/root/templates/stack.yaml` that ArgoCD's `ApplicationSet` derives the deploy namespace from the app directory's basename (`path.basename`) — so `system/loki` → namespace `loki`, `system/alloy` → namespace `alloy`, giving Loki's in-cluster service DNS as `loki.loki.svc.cluster.local:3100`.

## Changes

### 1. `system/loki/` (new app)

`app.yaml`:
```yaml
chartName: loki
chartRepo: https://grafana-community.github.io/helm-charts
chartVersion: 18.4.4
```

`values.yaml` — Monolithic mode, filesystem storage on the NFS `StorageClass`, 7-day retention, everything not needed at single-instance scale turned off:
```yaml
deploymentMode: Monolithic

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    retention_period: 168h
    allow_structured_metadata: true
    volume_enabled: true
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
  pattern_ingester:
    enabled: true

singleBinary:
  replicas: 1
  persistence:
    storageClass: nfs
    accessModes:
      - ReadWriteOnce
    size: 20Gi
  resources:
    requests:
      cpu: 100m
    limits:
      cpu: "1"

gateway:
  enabled: false
minio:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Zero out replica counts for the other deployment modes (Distributed/SimpleScalable) —
# the chart renders their workload templates whenever `replicas` is unset, even though
# deploymentMode: Monolithic doesn't use them.
backend: { replicas: 0 }
read: { replicas: 0 }
write: { replicas: 0 }
ingester: { replicas: 0 }
querier: { replicas: 0 }
queryFrontend: { replicas: 0 }
queryScheduler: { replicas: 0 }
distributor: { replicas: 0 }
compactor: { replicas: 0 }
indexGateway: { replicas: 0 }
bloomPlanner: { replicas: 0 }
bloomBuilder: { replicas: 0 }
bloomGateway: { replicas: 0 }
```

`vpa.yaml` — standard repo pattern, `targetRef.kind: StatefulSet`, `name: loki`.

No `httproute.yaml` — Loki is only consumed in-cluster by Grafana and Alloy, not user-facing.

### 2. `system/alloy/` (new app)

`app.yaml`:
```yaml
chartName: alloy
chartRepo: https://grafana.github.io/helm-charts
chartVersion: 1.10.1
```

`values.yaml` — single Deployment replica, `loki.source.kubernetes` config shipping all pod logs cluster-wide:
```yaml
controller:
  type: deployment
  replicas: 1

alloy:
  resources:
    requests:
      cpu: 100m
    limits:
      cpu: "1"
  configMap:
    content: |-
      discovery.kubernetes "pods" {
        role = "pod"
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.kubernetes.pods.targets
        forward_to = [loki.write.local.receiver]
      }

      loki.write "local" {
        endpoint {
          url = "http://loki.loki.svc.cluster.local:3100/loki/api/v1/push"
        }
        external_labels = {
          cluster = "homelab",
        }
      }
```

`vpa.yaml` — `targetRef.kind: Deployment`, `name: alloy`.

No `httproute.yaml` — Alloy exposes only its internal debug UI, not a user-facing service.

### 3. `system/monitoring-system/values.yaml` — wire Loki into Grafana

Add one datasource entry so Loki shows up in Grafana Explore immediately:
```yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.loki.svc.cluster.local:3100
```

## Out of scope

- Loki's bundled Grafana dashboards/alerting rules (`monitoring.dashboards.enabled`, `monitoring.rules.enabled` — both off by default in the chart). Not requested; Explore covers ad-hoc log queries. Straightforward to turn on later if pre-built panels are wanted (would also need the Grafana sidecar's `searchNamespace: ALL`, since the dashboard ConfigMap would live in the `loki` namespace, not `monitoring-system`).
- Object storage (S3/GCS/MinIO) — filesystem on NFS is sufficient at this log volume; revisit only if the 20Gi PVC or single-instance throughput becomes a real constraint.
- Kubernetes Events collection (Alloy can also ship cluster Events to Loki as a separate log stream) — only pod logs were asked for.
- Log-based alerting (Loki `ruler` / ships alerts to Alertmanager) — not requested.

## Testing

- After ArgoCD syncs both new apps: confirm the `loki` StatefulSet and `alloy` Deployment reach `Ready` (`kubectl get sts,deploy -n loki -n alloy`).
- Confirm the `loki-canary` DaemonSet reports no missing entries (`kubectl logs -n loki -l app.kubernetes.io/component=loki-canary`).
- In Grafana, open Explore, select the new `Loki` datasource, and query `{namespace="alloy"}` (or any known-active namespace) to confirm logs are flowing end-to-end.
- Confirm retention is configured as intended: `kubectl exec` into the `loki` pod and check `/etc/loki/config/config.yaml` for `retention_period: 168h` and `retention_enabled: true` under `compactor`.
