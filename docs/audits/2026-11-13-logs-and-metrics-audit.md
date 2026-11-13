# Logs and metrics audit: 2026-11-13

Read-only sweep of Prometheus, Loki, Hubble, Grafana, VPA, Longhorn and node disks, looking
for anything worth fixing. Measured 2026-11-13 between 10:20 and 11:00 PST. Nothing was
changed.

## Baseline

The cluster is healthy on the usual signals. Over 7 days there were no container restarts,
no CPU throttling above 10%, no scrape targets down and no unhealthy ArgoCD app except
Renovate. Running pods request 38-62% of node memory.

VPA and live requests agree: 38 containers under 30 VPAs request 0.96 CPU against a 0.96
target, and 8.9Gi memory against 9.1Gi. No container is off by more than 2x.

Two numbers mislead if you query them naively:

- `kube_pod_container_resource_requests` includes Failed pods. Unfiltered, worker-02 shows
  127% of memory requested; joined to `kube_pod_status_phase{phase="Running"}` it is 58%.
- `kubelet_volume_stats_*` for a `local-path` PVC reports the host root filesystem, so every
  CNPG volume reads 71-75% full. That is the node disk, not the database.

## Findings

| # | Priority | Finding | Fix |
|---|---|---|---|
| 1 | ~~Fix now~~ Done (#363) | Alloy drops logs on every rollout | Persist `/tmp/alloy` |
| 2 | ~~Fix now~~ Done (#364) | worker-02 disk blocks Longhorn scheduling | Kubelet image GC below Longhorn's floor |
| 3 | Fix now | Renovate still OOMs on heap | Watch the next run; reopen #358 if it fails |
| 4 | Worth doing | Prometheus stores 183k series twice | Drop apiserver/etcd series from the kubelet scrape |
| 5 | Worth doing | No app-level NetworkPolicies | Default-deny in database namespaces |
| 6 | Worth doing | Prometheus volume is in the daily backup | Remove it from the `default` group |
| 7 | Cleanup | Hubble dashboards are mostly empty | Enable `flow,tcp,icmp` or drop the dashboards |
| 8 | Cleanup | Irrelevant and duplicate dashboards | Disable MacOS/AIX, drop upstream duplicates |
| 9 | Cleanup | Loki's own info logs dominate log volume | Lower Loki's log level |
| 10 | Cleanup | Failed Job pods linger | Delete; check `failedJobsHistoryLimit` |

### 1. Alloy drops logs on every rollout

Loki discarded 870k entries in the hour after #360 (alloy 1.16.0) merged at 10:07: 698k
`too_far_behind` and 172k `rate_limited`. Alloy reported 469k entries dropped with
`final error sending batch, no retries left`. Every discard in the 7-day window falls in
that hour.

Alloy keeps tail positions in `/tmp/alloy/loki.source.kubernetes.pods/positions.yml`
(`--storage.path=/tmp/alloy`) on the container filesystem. A new pod re-tails every
container from the start. The replayed lines share batches with live lines, so Loki's
400s and 429s discard live logs as well, and `AlloyDroppingLogs` fires. The Deployment has
11 ReplicaSets in 124 days, one per chart bump or config change.

Fix: put the storage path on a small `longhorn` volume. The chart supports a StatefulSet
controller with volume claim templates; confirm the exact keys against the chart before
writing them.

**Status: fixed 2026-11-13 (#363).** Alloy runs as a single-replica StatefulSet with a 1Gi
`longhorn` volume at `/var/lib/alloy`, and positions now survive a pod replacement. The
`stage.drop` older-than guard stays, because a fresh or lost volume still tails from the start.

### 2. worker-02's disk blocks Longhorn scheduling

Longhorn marks worker-02's disk `Schedulable=False, DiskPressure`. The root filesystem is
80% used (187 of 233 GiB) and `storage-minimal-available-percentage` is 25, so Longhorn
places no new replicas there. worker-00 sits at 76% with 29% available.

Containerd holds 92 GiB on worker-02 (70 GiB unpacked snapshots, 22 GiB content) against
70 GiB of Longhorn replicas. The node keeps 236 images, including 19 Renovate versions
(7.9 GiB compressed) because Renovate updates itself. Kubelet image GC starts at its
default 85% high threshold, above the point where Longhorn stops scheduling.

Fix: set `image-gc-high-threshold` and `image-gc-low-threshold` below 75 through
`kubelet-arg` in `ansible/`, then prune once by hand. worker-01 is fine at 36% of 466G.

**Status: fixed 2026-11-13 (#364).** A `kubelet.conf.d` drop-in replaced the deprecated
`kubelet-arg` flags: thresholds 70/65 plus `imageMaximumGCAge: 168h`, so no manual prune was
needed. The first GC pass took worker-02's root filesystem from 176G to 106G and worker-00's
from 82G to 59G. All three Longhorn disks report `Schedulable=True`.

### 3. Renovate still OOMs on heap

The 03:24 run died with `Ineffective mark-compacts near heap limit` at about 1020 MB, which
is V8's heap ceiling rather than the 2Gi container limit. #358 (Node heap cap) was closed
unmerged. That failure predates the #359 merge at 09:49, and the 09:59 manual run
succeeded, so #359 may be enough. The next scheduled run, around 15:25 PST, settles it.

`ArgoCDAppDegraded` fired on the renovate app for most of the week (1,158 samples), which
trains you to ignore it.

### 4. Prometheus stores 183k series twice

Prometheus holds 460k head series. On k3s the kubelet `/metrics` endpoint serves the whole
process registry, so the `kubelet` job collects 147k `apiserver_*` and 36k `etcd_*` series
that the `apiserver` job already has. That is 40% of head series. The PVC is 70% of 20Gi,
growing 0.17-0.27 GiB a day, with no `retentionSize` set behind the 10d retention.

Fix: a `metricRelabelings` drop of `(apiserver|etcd)_.+` on the kubelet ServiceMonitor in
`system/monitoring-system/values.yaml`, plus a `retentionSize`. Before merging, grep the
rendered rules and dashboards for those metrics filtered on `job="kubelet"`.

### 5. No app-level NetworkPolicies

The only NetworkPolicies are the ones the argocd, longhorn and infisical charts ship. Any
pod can reach the Vaultwarden, Infisical, Nextcloud and Immich Postgres clusters. Hubble's
drop metrics (`hubble_drop_total` with namespace context) are already on, so a
default-deny would show what it breaks.

### 6. Prometheus volume is in the daily backup

The 20Gi Prometheus volume uses 24.9G per replica, about 50G across two. It carries the
`recurring-job-group.longhorn.io/default` label, so `daily-backup` snapshots it, and that
snapshot pins every TSDB block compaction has since rewritten. A crash-consistent copy of
10 days of metrics is worth little. Removing the label frees the space once Longhorn cleans
up the snapshot.

### 7. Hubble dashboards are mostly empty

Cilium runs `hubble-metrics: drop dns`. The `dns` metric emits nothing without L7 DNS
visibility, so four dashboards (Hubble Metrics and Monitoring, DNS Overview, Network
Overview, L7 HTTP) query `hubble_flows_processed_total`, `hubble_tcp_flags_total`,
`hubble_icmp_total` and `hubble_dns_*`, none of which exist.

### 8. Irrelevant and duplicate dashboards

43 dashboards are provisioned. Node Exporter MacOS and AIX do not apply. Longhorn and
CloudNativePG each ship an upstream dashboard beside the "Homelab" one. The Cilium
Operator EC2 panels and Cilium kvstore/proxy panels are empty by design and can stay.

### 9. Loki's own info logs dominate log volume

Loki ingests about 2M lines a day. The top sources:

| Namespace | Lines/day | Main source |
|---|---|---|
| loki | 594k | `loki` container info logs (499k), canary (91k) |
| argocd | 481k | repo-server, notifications, application-controller, about 160k each |
| infisical | 345k | per-request info logs |
| vpa | 181k | recommender checkpoint logs |

### 10. Failed Job pods linger

Three rclone-seedbox Jobs from 19 days ago and two Renovate Jobs keep their Failed pods.
They are harmless except for skewing the unfiltered request queries above.

## Watch only

- `sealed-secrets/controller` has a 75Mi memory limit against a 512Mi VPA upper bound. The
  bound is wide because #359 renamed the container and reset its history; target is 50Mi.
- CoreDNS answers 65% of queries with NXDOMAIN (785k of 1.2M a day), and AAAA queries match
  A queries one for one. That pattern points to `ndots:5` search expansion. The source
  apps are not identified.
- `hubble_lost_events_total{source="hubble_ring_buffer"}` rose about 121k per node over 7
  days, with near-identical counts on all three nodes. Cause unknown; it affects
  `hubble observe`, not traffic.
- Physical NICs drop 43-51k packets a day per node, evenly across three NIC models.
  Probably multicast or unknown-protocol frames; unconfirmed.
- Cilium drops are benign: 34.9k ICMPv6 on an IPv4-only cluster, 433 stale-IP retries and
  47 policy-denied pings to argocd over 7 days.
- Alertmanager's webhook failed twice in 7 days.
- flaresolverr was OOMKilled once; its 7-day peak is 884Mi against a 1199Mi limit.
- Grafana logs 1,732 `search-manifest-watcher` "zero manifests" warnings a day. Noise.

## Not checked

Loki-backed dashboard panels, which apps generate the NXDOMAIN traffic, and the cause of
Hubble's lost events.
