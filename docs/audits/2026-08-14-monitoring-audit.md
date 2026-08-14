# Monitoring & Alerting Audit — 2026-08-14

Scope: what is scraped, what alerts exist, and which failure modes currently produce no
signal. Every finding below was checked against the live Prometheus, not just the repo.

## What's already good

- kube-prometheus-stack `defaultRules` are all enabled (38 rule groups live), so
  pod/node/kubelet/apiserver/PVC-level failures do alert.
- Dead-man's switch works: `Watchdog` → healthchecks.io, `group_interval: 1m` /
  `repeat_interval: 5m`.
- Escalation loop exists (`WarningAlertFiringTooLong` → critical → hourly ntfy).
- Purpose-built rules for the subsystems that have bitten this cluster before: CNPG,
  CoreDNS, Longhorn, backups/CronJobs, temperature, Infisical, ArgoCD.
- The repo already has the right habit of pairing each subsystem with an
  `absent()`-style `*MetricsMissing` rule. That pattern just hasn't been applied
  everywhere.
- 18 scrape pools, 17 of them healthy, 0 failing targets, `prometheus_tsdb_wal_corruptions_total = 0`,
  414k series.

## Findings

Ranked by "what breaks, and would I find out".

### P0 — etcd is completely unmonitored

`monitoring-system-kube-pro-kube-etcd` Service has **empty endpoints**; the scrape pool
has **0 targets** (the only empty pool in the cluster). `etcd_server_has_leader` returns
no series.

Consequences:
- The chart's `etcd` rule group (leader loss, no-leader flapping, high fsync/commit
  latency, member down, proposal failures) can **never fire** — it has no data.
- `TargetDown` cannot cover for it either: no endpoints means no target, so there is no
  `up` series to be 0.
- This is a 3-node HA embedded-etcd control plane. Quorum loss is the one failure that
  takes the whole cluster with it, and it is the one thing with zero instrumentation.

Cause: k3s binds embedded-etcd metrics to `127.0.0.1:2381` unless
`etcd-expose-metrics: true` is set, and the chart's Service selects `component=etcd`
pods that don't exist on k3s (etcd runs inside the k3s process).

### P0 — nothing detects "a scrape pool went empty"

The etcd gap has been live for 33 days and silent. `prometheus_target_scrape_pool_targets == 0`
matches it exactly and matches nothing else right now — a single generic rule closes this
whole class of failure, including the next chart that quietly stops matching anything.

### P1 — TLS certificate expiry is blind

cert-manager metrics are not scraped (`certmanager_certificate_expiration_timestamp_seconds`:
no series). `*.nik-homelab.dev` is the front door for every app. If a renewal fails
— Cloudflare token rotated, DNS-01 broken, rate limit — the first notification is a
browser warning, ~90 days after the last successful issue.

### P1 — the ingress data path is blind

No Envoy Gateway metrics (`envoy_cluster_upstream_rq_total`: no series). There is no
signal for 5xx rate, upstream/backend health, listener state, or per-hostname
availability. Every user-facing request in the cluster goes through this and none of it
is measured.

### P1 — the log pipeline is unmonitored, and log alerts sit inside their own blast radius

Neither Loki nor Alloy is scraped (`loki_build_info`, `alloy_build_info`: no series).
The cluster's only log-based alert (`loki-rule-cilium-split-brain`) is delivered by the
Loki ruler. If Alloy stops shipping or the ruler stops evaluating, that alert silently
stops existing — the same failure shape the dead-man's switch was added to fix for the
metrics path.

### P1 — Cilium/CNI has metrics disabled

`cilium_unreachable_nodes` and all Hubble metrics: no series. Given this cluster's
history — dangling BPF backends from two agents on one node, split-brain, stale CNI
conflist after reboot — this is the highest-value metric source not yet scraped after
etcd. The one Cilium alert that exists is log-derived, and per the finding above, that
delivery path is itself unwatched.

### P2 — Prometheus's own TSDB lives on NFS

`prometheus.prometheusSpec.storageSpec` uses `storageClass: nfs`, 20Gi — i.e. the
alerting path's own state is a 12TB USB HDD hanging off worker-01, over NFS.

Two problems: it contradicts the repo's own storage rule (state → `longhorn`), and a
TSDB is `mmap`-heavy, which is exactly what NFS handles worst. A worker-01 or NFS blip
corrupts the WAL and takes down the thing that notices outages. No damage so far
(`wal_corruptions_total = 0`), so this is a scheduled migration, not an incident.

### P2 — no black-box / outside-in checks

`probeSelectorNilUsesHelmValues: false` is set but there are **zero** `Probe` resources
and no blackbox exporter. Nothing verifies from the outside that an app actually answers,
that the public DNS record still resolves, or that the served certificate chain is valid.
Every current check is inside-out.

### P3 — apps have no availability signal beyond pod state

16 apps, one app-level alert (`NextcloudDown`). Crashloops and NotReady are covered by
the default rules, but "pod is Running and the app is broken" is not — including
Vaultwarden, the highest-consequence app in the cluster. The blackbox work in P2 covers
most of this in one move, which is why it should come before any per-app exporters.

### P3 — gluetun tunnel state is not measured

qBittorrent binds to `tun0`. There is no metric for tunnel state or egress IP, so a
tunnel that drops and reconnects (or doesn't) is invisible until downloads stall.

### P3 — low-value unscraped components

external-dns (`external_dns_registry_errors_total` would explain the "record didn't
update" class of problem), VPA, sealed-secrets, Tailscale, metrics-server. Cheap
ServiceMonitors, low urgency.

### Incidental, not monitoring

`system/monitoring-system/values.yaml` ships Grafana with `adminPassword: changeme` and
`auth.anonymous.org_role: Admin`. It's only reachable behind the gateway, but anonymous
Admin means anyone who reaches the hostname can edit datasources.

## Plan

Ordered so each task is independently shippable and verifiable. Same pattern throughout:
enable the scrape, add the alerts, and add the `absent()` guard so the *next* silent gap
announces itself.

| # | Done | Task | Files | Verify |
|---|------|------|-------|--------|
| 1 | #43 | Generic empty-scrape-pool alert (`ScrapePoolEmpty`, `for: 30m`) | `prometheusrule.yaml` | fires for etcd today, nothing else |
| 2 | #44 #45 | Expose k3s etcd metrics: `etcd-expose-metrics: true` in the k3s config, `kubeEtcd.endpoints` = the three node IPs so the chart renders static Endpoints | `ansible/`, `monitoring-system/values.yaml` | `etcd_server_has_leader == 1` ×3; task 1's alert clears |
| 3 | #46 | `prometheusrule-etcd.yaml` gap-fill + `EtcdMetricsMissing` | new file | trip-test with an invented severity |
| 4 | #47 | cert-manager ServiceMonitor + `CertExpiringSoon` (<21d), `CertNotReady`, `CertManagerMetricsMissing` | `system/cert-manager/`, new rule file | expiry series present for every live cert |
| 5 | #48 | Envoy Gateway telemetry (PodMonitor via the existing `EnvoyProxy` parametersRef) + `Gateway5xxRateHigh`, `GatewayNoHealthyUpstream`, `EnvoyMetricsMissing` | `system/envoy-gateway/`, new rule file | 5xx rate visible during a deliberate 503 |
| 6 | #53 | Loki + Alloy ServiceMonitors + `LokiRulerNotEvaluating`, `AlloyNotShippingLogs`, `LogPipelineMetricsMissing` | `system/loki/`, `system/alloy/`, new rule file | scale Alloy to 0 → alert fires |
| 7 | #54 #55 | Cilium agent/operator metrics (+ Hubble drop/DNS metrics only — flow metrics are a cardinality trap at 414k series) + `CiliumUnreachableNodes`, `CiliumAgentRestarting`, `CiliumMetricsMissing` | `bootstrap/` (Cilium is helmfile-managed, not in `system/`), new rule file | `cilium_unreachable_nodes == 0` ×3; watch series count after |
| 8 | #56 #57 #58 | Move the Prometheus TSDB PVC to `longhorn` (20Gi, 2 replicas). Accept the history loss or copy the blocks; do it deliberately — this is the alerting path | `monitoring-system/values.yaml` | Prometheus Ready, `wal_corruptions_total == 0`, Watchdog ping never gaps |
| 9 | #59 | blackbox-exporter + `Probe`s for vaultwarden / grafana / jellyfin / nextcloud / immich + `EndpointDown`, `ProbeCertExpiringSoon` | new `system/blackbox-exporter/`, new rule file | `probe_success == 1` for each; block one app to confirm it trips |
| 10 | #60 | external-dns ServiceMonitor + `ExternalDNSRegistryErrors` | `system/external-dns/` | errors counter present |

Deliberately **not** in the plan:

- Per-app exporters (exportarr for the arrs, qBittorrent exporter, Jellyfin exporter).
  Task 9 gives an availability signal for all of them with one deployment. Add a
  dedicated exporter only when a specific failure recurs and blackbox can't see it.
- A gluetun tunnel metric. Gluetun exposes no Prometheus endpoint; the options are a
  control-server probe or a sidecar, and neither has earned its keep yet. Revisit if
  tunnel drops actually happen.
- VPA / sealed-secrets / Tailscale / metrics-server scrapes. Nothing has ever failed
  here in a way a metric would have caught first.
- Recording rules and new dashboards. Nothing in this audit is blocked on query cost.

Tasks 1–3 are the ones that matter; 1 is ~10 lines and closes the class of bug that hid
the other one for a month.

## Outcome

All ten tasks shipped on 2026-08-14. 46 rule groups and 241 rules became 51 and 297; 62
scrape targets became 68; head series went 493k to 503k, almost all of it Cilium.

Three things the audit did not predict:

**The health mesh had been broken the whole time.** Task 7 turned on Cilium metrics and
`cilium_unreachable_nodes` read 2 on all three nodes — `cilium-health` had been reporting
1/3 reachable indefinitely. UFW's default deny had no rule for `:4240` or the metrics
ports, so every cross-node probe timed out while ICMP and pod-to-pod both passed. 6443 and
2380 worked throughout because they have explicit rules, which is what made it look like a
selective network fault rather than a firewall. Four allows in
`ansible/roles/common/tasks/main.yml` took it to 3/3. The alert found its own root cause
within ten minutes of the metrics existing, and never fired.

**Prometheus cannot be stopped with `kubectl`.** Task 8 needed the pod down to swap its
PVC. Scaling the operator to 0 is reverted by `selfHeal`; removing `automated` from the
Application is reverted by the `system` ApplicationSet that owns it. The only lever the
controllers agree with is `prometheusSpec.replicas: 0` committed to main, which is why
that window is two commits in the history rather than none.

**A storage class change is a silent no-op.** After merging task 8's values change, the
Prometheus CR and its StatefulSet both said `longhorn`, ArgoCD said Synced and Healthy, and
the PVC was still `nfs`. `volumeClaimTemplates` are immutable, so the operator recreates
the StatefulSet, and the recreated one adopts the PVC that already exists under that name.
Nothing anywhere indicates the migration has not happened.

Left open, deliberately:

- The old NFS PV `pvc-9dbb49b1` is `Released` with `Retain`, holding 10.3GB at
  `worker-01:/mnt/storage/monitoring-system/prometheus-…-0`. It is the rollback for task 8;
  deleting it is irreversible.
- Blackbox probes cover 5 of 16 hostnames. Extending is one line each in
  `system/blackbox-exporter/probes.yaml`, worth doing once `EndpointDown` has been quiet
  for a while.
- The live UFW rules include `2379:2381`, `5001`, `51820/51821` and blanket allows for both
  cluster CIDRs, none of which are in the `common` role. The `ufw` module only adds, so
  provisioning will not remove them, but that file is not a complete description of the
  nodes.
Closed without action:

- Grafana ships `adminPassword: changeme` with `auth.anonymous.org_role: Admin`. Accepted
  on 2026-08-14: Grafana is reachable only from the home network or over Tailscale, so
  anonymous Admin is the intended behaviour rather than an oversight. Recorded here so it
  is not re-raised as a finding. Revisit only if the gateway ever fronts it publicly.
