# Monitoring Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every alerting subject in the cluster a dashboard that answers "is it getting worse, and why", starting by restoring the Longhorn metrics that six alerts currently depend on and are not receiving.

**Architecture:** Each dashboard is a ConfigMap holding a Grafana dashboard JSON, labelled `grafana_dashboard: "1"`, living in its subject's own directory. The Grafana sidecar runs `NAMESPACE=ALL`, so namespace does not affect discovery. `system/vpa/dashboard.yaml` is the structural template for every new dashboard — copy its ConfigMap wrapper, `templating` block, and panel shapes, and replace the panels.

**Tech Stack:** kube-prometheus-stack (Prometheus Operator, Grafana sidecar), Grafana schemaVersion 39, PromQL, ArgoCD, Longhorn 1.12.1, Envoy Gateway 1.8.3, CloudNativePG.

**Spec:** None. This plan comes from a gap analysis run on 2026-08-14: the 30 dashboards currently loaded in Grafana were compared against every `prometheusrule*.yaml` in the repo, and each proposed query was executed against the live Prometheus before being written down.

## Global Constraints

- **Dashboards live with their subject.** Monitoring artifacts go in the subject's directory when it has one (`system/envoy-gateway/`, `system/longhorn-system/`, `platform/cloudnative-pg/`). `system/monitoring-system/` is only for subjects with no directory (cilium, etcd, argocd) or ones spanning several (temperatures, cronjobs, media-stack).
- **File name is `dashboard.yaml`** in the subject's directory, matching the sibling convention of `prometheusrule.yaml` / `servicemonitor.yaml` / `podmonitor.yaml`.
- **ConfigMap name is `grafana-dashboard-<subject>`**, namespace is the subject's namespace, label `grafana_dashboard: "1"`.
- **Dashboard `uid` is `homelab-<subject>`**, title is `Homelab — <Subject>` (em dash, matching `homelab-vpa` and `homelab-temperatures`).
- **No `grafana_folder` annotation.** The sidecar runs without `FOLDER_ANNOTATION`, so it is silently ignored. Everything lands in the default folder.
- **Every panel query must be executed against live Prometheus before the task is committed.** Label names in this plan were verified on 2026-08-14; re-run them rather than trusting them.
- **Datasource reference is `{ "type": "prometheus", "uid": "${datasource}" }`** on both the panel and each target, with the `datasource` template variable copied verbatim from `system/vpa/dashboard.yaml`.
- **Never add an `Ingress`.** Never commit plaintext secrets. Server-side apply only (ArgoCD handles this).
- **Merging to `main` deploys.** Each task is its own branch and draft PR; do not merge until the verification step in that task passes.

## Helper: running a PromQL query without port-forwarding

Every verification step in this plan uses this shell function. Define it once per session:

```bash
promq() {
  kubectl get --raw \
    "/api/v1/namespaces/monitoring-system/services/http:monitoring-system-kube-pro-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | jq -r '.data.result[] | "\(.metric | tostring) = \(.value[1])"'
}
```

Usage: `promq 'sum by (update_mode) (vpa_updater_controlled_pods_total)'`

## Helper: validating a dashboard file

Both commands must pass before any dashboard commit:

```bash
# 1. The embedded JSON parses
awk '/\.json: \|/{f=1;next} f{sub(/^    /,"");print}' <path>/dashboard.yaml | python3 -m json.tool > /dev/null

# 2. The manifest is a valid ConfigMap
kubectl apply --dry-run=client -f <path>/dashboard.yaml
```

---

### Task 1: Restore Longhorn metrics scraping

**This task blocks Task 2 and is worth shipping on its own even if no dashboard follows.** All three `longhorn-backend` scrape targets are down, so `LonghornVolumeDegraded`, `LonghornVolumeFaulted`, `LonghornNodeStorageFull`, `LonghornBackupFailed`, `LonghornNodeNotReady`, and `LonghornReplicaLeak` all evaluate against nothing. They report `state=inactive health=ok`, which is indistinguishable from healthy.

**Root cause:** Longhorn chart 1.12.1, deployed earlier on 2026-08-14, renders six NetworkPolicies. The `longhorn-manager` policy admits ingress only from longhorn's own components — `longhorn-manager`, `longhorn-ui`, `longhorn-csi-plugin`, recurring-job pods, and `longhorn-driver-deployer`. Prometheus is in another namespace and matches none of them, so the scrape is dropped and reports `context deadline exceeded`.

The chart's documented off switch does not work. `helm template longhorn/longhorn --version 1.12.1` renders all six policies with `networkPolicies.enabled=false` **and** with `=true` — the templates never read the flag. Setting it in `values.yaml` would be a no-op that looks like a fix.

**Files:**
- Create: `system/longhorn-system/networkpolicy-monitoring.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: live `longhorn_*` series in Prometheus, which Task 2 queries.

- [ ] **Step 1: Confirm the failure is still present**

```bash
kubectl get --raw "/api/v1/namespaces/monitoring-system/services/http:monitoring-system-kube-pro-prometheus:9090/proxy/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | select(.labels.namespace=="longhorn-system") | "\(.scrapeUrl) health=\(.health) err=\(.lastError)"'
```

Expected: three targets, all `health=down`, all `err=Get "http://.../metrics": context deadline exceeded`.

If they are already `up`, stop — someone else fixed this. Skip to Task 2.

- [ ] **Step 2: Confirm the cause is the NetworkPolicy and not a slow endpoint**

```bash
POD=$(kubectl -n longhorn-system get pod -l app=longhorn-manager -o name | head -1 | cut -d/ -f2)
time kubectl get --raw "/api/v1/namespaces/longhorn-system/pods/http:$POD:9500/proxy/metrics" | wc -l
```

Expected: roughly 2200 lines returned in well under a second. The endpoint is fast; only the pod-network path from Prometheus is blocked. If this call is slow instead, the cause is different — stop and re-diagnose rather than applying the fix below.

- [ ] **Step 3: Create the branch**

```bash
git checkout main && git pull
git checkout -b fix/longhorn-metrics-netpol
```

- [ ] **Step 4: Write the allow policy**

NetworkPolicies are additive — a second policy selecting the same pods unions its `from` list with the chart's, so this restores the scrape without weakening anything else or fighting the chart on the next upgrade.

Create `system/longhorn-system/networkpolicy-monitoring.yaml`:

```yaml
# Longhorn chart 1.12.1 ships a longhorn-manager NetworkPolicy admitting only Longhorn's own
# components, which silently blackholed every Prometheus scrape and left all six alerts in
# prometheusrule.yaml evaluating against no data — inactive and healthy-looking.
#
# The chart's networkPolicies.enabled flag does not gate these templates: 1.12.1 renders all
# six policies whether it is true or false, so this cannot be fixed in values.yaml. Policies
# are additive, so this one grants Prometheus the port it needs and leaves the chart's
# isolation intact.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: longhorn-manager-allow-monitoring
  namespace: longhorn-system
spec:
  podSelector:
    matchLabels:
      app: longhorn-manager
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring-system
      ports:
        - protocol: TCP
          port: 9500
```

- [ ] **Step 5: Verify the namespace label the selector depends on exists**

`kubernetes.io/metadata.name` is applied automatically by the API server, but confirm rather than assume:

```bash
kubectl get ns monitoring-system -o jsonpath='{.metadata.labels}' | jq
```

Expected: includes `"kubernetes.io/metadata.name": "monitoring-system"`. If absent, replace the `namespaceSelector` with one matching a label the namespace actually carries.

- [ ] **Step 6: Validate the manifest**

```bash
kubectl apply --dry-run=client -f system/longhorn-system/networkpolicy-monitoring.yaml
```

Expected: `networkpolicy.networking.k8s.io/longhorn-manager-allow-monitoring created (dry run)`

- [ ] **Step 7: Commit and open a draft PR**

```bash
git add system/longhorn-system/networkpolicy-monitoring.yaml
git commit -m "storage(longhorn): let Prometheus reach the manager metrics port

Chart 1.12.1 ships a longhorn-manager NetworkPolicy admitting only Longhorn's own
components. Prometheus is in another namespace and matches none of them, so all three
scrape targets went to context deadline exceeded and every alert in prometheusrule.yaml
has been evaluating against no data since the upgrade — inactive, health ok, blind.

networkPolicies.enabled does not gate these templates in 1.12.1: the chart renders all
six policies whether the flag is true or false, so values.yaml cannot fix it. Policies
are additive, so this grants the one port Prometheus needs and leaves the rest alone."
git push -u origin fix/longhorn-metrics-netpol
gh pr create --draft --title "Let Prometheus reach Longhorn manager metrics" --body-file <path>
```

Follow `creating-pull-requests` for the body.

- [ ] **Step 8: Merge, then verify the targets recover**

After merging, refresh the app and poll until the targets come up:

```bash
kubectl -n argocd annotate app longhorn-system argocd.argoproj.io/refresh=normal --overwrite
kubectl get --raw "/api/v1/namespaces/monitoring-system/services/http:monitoring-system-kube-pro-prometheus:9090/proxy/api/v1/query?query=up%7Bjob%3D%22longhorn-backend%22%7D" \
  | jq -r '.data.result[] | "\(.metric.instance) up=\(.value[1])"'
```

Expected: three instances, all `up=1`. Re-run until they flip; the scrape interval is 30s.

- [ ] **Step 9: Verify the alerts now have data underneath them**

```bash
promq 'count(longhorn_volume_robustness)'
promq 'count(longhorn_engine_info)'
promq 'count(longhorn_backup_state)'
```

Expected: all three return a non-zero count. Before this task they returned nothing at all.

---

### Task 2: Longhorn dashboard

**Depends on Task 1.** Do not start until `up{job="longhorn-backend"} == 1`.

Longhorn is the highest-value dashboard in this plan: six alerts, a version upgrade and a volume migration both landed on 2026-08-14, and `longhorn_engine_info` exposes exactly the drift that let the control plane report green while volumes stayed on the old engine image.

**Files:**
- Create: `system/longhorn-system/dashboard.yaml`
- Reference: `system/vpa/dashboard.yaml` (copy the ConfigMap wrapper and `templating` block verbatim)

**Interfaces:**
- Consumes: `longhorn_*` series restored by Task 1.
- Produces: dashboard uid `homelab-longhorn`.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/longhorn-dashboard
```

- [ ] **Step 2: Confirm every metric this dashboard needs has current samples**

Run each and confirm a non-empty result. Any that returns nothing must be dropped from the dashboard rather than shipped as an empty panel:

```bash
promq 'longhorn_volume_robustness'
promq 'longhorn_engine_info'
promq 'longhorn_backup_state'
promq 'longhorn_disk_usage_bytes'
promq 'longhorn_disk_capacity_bytes'
promq 'longhorn_volume_actual_size_bytes'
```

Record the label sets returned. `longhorn_engine_info` in particular carries the engine image as a label — note its exact key, because Step 3's panel groups by it.

- [ ] **Step 3: Write the dashboard**

Copy `system/vpa/dashboard.yaml` to `system/longhorn-system/dashboard.yaml`, then change: ConfigMap `name` to `grafana-dashboard-longhorn`, `namespace` to `longhorn-system`, data key to `homelab-longhorn.json`, `title` to `Homelab — Longhorn`, `uid` to `homelab-longhorn`, `tags` to `["homelab", "storage"]`. Replace the `panels` array with these six.

| # | Type | Title | Query |
|---|---|---|---|
| 1 | stat | Volume health | `count by (robustness) (longhorn_volume_robustness)` |
| 2 | stat | Engine images in use | `count by (image) (longhorn_engine_info)` — substitute the real image label key found in Step 2 |
| 3 | timeseries | Disk usage vs capacity per node | `sum by (node) (longhorn_disk_usage_bytes)` and `sum by (node) (longhorn_disk_capacity_bytes)`, unit `bytes` |
| 4 | table | Backup state by volume | `longhorn_backup_state`, format table, instant |
| 5 | timeseries | Volume actual size | `topk(10, longhorn_volume_actual_size_bytes)`, unit `bytes` |
| 6 | stat | Scrape health | `sum(up{job="longhorn-backend"})` — thresholds red below 3, green at 3 |

Panel 2 is the one that earns its place: more than one engine image means a chart bump left volumes behind. Panel 6 exists because Task 1's failure mode was invisible — a dashboard fed by a dead scrape looks identical to a healthy idle cluster, and this panel is the difference.

Write a header comment following the style of `system/vpa/dashboard.yaml`: what the dashboard answers, and the non-obvious reason panel 2 and panel 6 exist.

- [ ] **Step 4: Validate**

```bash
awk '/homelab-longhorn.json: \|/{f=1;next} f{sub(/^    /,"");print}' system/longhorn-system/dashboard.yaml | python3 -m json.tool > /dev/null && echo "JSON valid"
kubectl apply --dry-run=client -f system/longhorn-system/dashboard.yaml
```

Expected: `JSON valid`, then `configmap/grafana-dashboard-longhorn created (dry run)`.

- [ ] **Step 5: Run every panel query through Prometheus**

Run each query from the table with `promq`. Every one must return at least one series. A query that returns nothing is a wrong label name, not an idle cluster — fix it now rather than discovering it in Grafana.

- [ ] **Step 6: Commit and open a draft PR**

```bash
git add system/longhorn-system/dashboard.yaml
git commit -m "monitoring(longhorn): add a storage dashboard"
git push -u origin feat/longhorn-dashboard
```

- [ ] **Step 7: After merge, verify Grafana loaded it**

```bash
kubectl -n argocd annotate app longhorn-system argocd.argoproj.io/refresh=normal --overwrite
kubectl -n monitoring-system exec deploy/monitoring-system-grafana -c grafana-sc-dashboard -- ls /tmp/dashboards | grep longhorn
kubectl -n monitoring-system logs deploy/monitoring-system-grafana -c grafana --since=10m | grep -iE 'provisioning.*error|failed to load dashboard'
```

Expected: `homelab-longhorn.json` present; no provisioning errors.

---

### Task 3: Envoy Gateway dashboard

Envoy has three alerts, an existing `podmonitor.yaml`, no dashboard, and the worst incident history in the repo: the `Programmed=False` condition traced on 2026-08-14 and the 504s caused by VPA shrinking Envoy's CPU limit.

**The obvious query is the wrong one.** `envoy_http_downstream_rq_xx` exists but only carries `envoy_http_conn_manager_prefix` values `admin` and `eg-ready-http` — Envoy's own admin and readiness listeners. No user traffic appears in it. Real per-route traffic lives in `envoy_cluster_upstream_rq`, labelled `envoy_cluster_name="httproute/<namespace>/<name>/rule/0"` and `envoy_response_code`. A dashboard built on `downstream_rq_xx` would look plausible and show nothing that matters.

**Files:**
- Create: `system/envoy-gateway/dashboard.yaml`

**Interfaces:**
- Consumes: `envoy_cluster_*` from the existing `system/envoy-gateway/podmonitor.yaml`.
- Produces: dashboard uid `homelab-envoy-gateway`.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/envoy-gateway-dashboard
```

- [ ] **Step 2: Confirm the per-route metrics and their labels**

```bash
promq 'topk(5, envoy_cluster_upstream_rq)'
promq 'count by (envoy_cluster_name) (envoy_cluster_upstream_rq_time_bucket)'
```

Expected: series named `httproute/<ns>/<name>/rule/0` with an `envoy_response_code` label. Confirm before writing panels.

- [ ] **Step 3: Write the dashboard**

Copy the wrapper from `system/vpa/dashboard.yaml`. ConfigMap `name` `grafana-dashboard-envoy-gateway`, `namespace` `envoy-gateway`, data key `homelab-envoy-gateway.json`, `uid` `homelab-envoy-gateway`, title `Homelab — Envoy Gateway`, tags `["homelab", "networking"]`. Panels:

| # | Type | Title | Query |
|---|---|---|---|
| 1 | timeseries | Requests per route | `sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq[$__rate_interval]))` |
| 2 | timeseries | Non-2xx per route | `sum by (envoy_cluster_name, envoy_response_code) (rate(envoy_cluster_upstream_rq{envoy_response_code!~"2.."}[$__rate_interval]))` |
| 3 | timeseries | p99 upstream latency per route | `histogram_quantile(0.99, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket[5m])))`, unit `ms` |
| 4 | timeseries | Upstream timeouts | `sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_timeout[$__rate_interval]))` |
| 5 | stat | Active connections | `sum(envoy_http_downstream_cx_active)` |
| 6 | stat | Proxy scrape health | `sum(up{job="envoy-gateway/envoy-proxy"})` |

Confirm the unit on panel 3 before shipping: `envoy_cluster_upstream_rq_time_bucket` is in **milliseconds**, not seconds, so the panel unit is `ms` and not `s`. Verify with `promq 'histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket[5m])))'` and sanity-check the magnitude against a known-fast route.

Header comment must record why `downstream_rq_xx` is not used — the next person will reach for it first.

- [ ] **Step 4: Validate, run every query, commit, PR, verify after merge**

Same four commands as Task 2 Steps 4–7, substituting `envoy-gateway` for `longhorn-system` and `homelab-envoy-gateway.json` for the data key.

---

### Task 4: Blackbox availability dashboard

17 `probe_success` series after the probe extension earlier on 2026-08-14. Every other dashboard in Grafana is the cluster's opinion of itself; this is the only outside-in view, and it also carries certificate expiry.

**Files:**
- Create: `system/blackbox-exporter/dashboard.yaml`

**Interfaces:**
- Consumes: `probe_*` series, labelled `instance="https://<host>"` and `job="probe/blackbox-exporter/apps"`.
- Produces: dashboard uid `homelab-blackbox`.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/blackbox-dashboard
```

- [ ] **Step 2: Confirm labels and the full probe list**

```bash
promq 'probe_success'
promq 'probe_ssl_earliest_cert_expiry'
```

Note the exact `job` value — panels filter on it, and there may be more than one probe module.

- [ ] **Step 3: Write the dashboard**

ConfigMap `name` `grafana-dashboard-blackbox`, `namespace` `blackbox-exporter`, data key `homelab-blackbox.json`, `uid` `homelab-blackbox`, title `Homelab — External Availability`, tags `["homelab", "availability"]`.

| # | Type | Title | Query |
|---|---|---|---|
| 1 | stat | Endpoints up | `sum(probe_success)` over `count(probe_success)` — two targets, `value_and_name` |
| 2 | table | Failing endpoints | `probe_success == 0`, format table, instant. Empty table is the healthy state |
| 3 | timeseries | Probe duration | `probe_duration_seconds`, legend `{{instance}}`, unit `s` |
| 4 | table | Certificate expiry | `(probe_ssl_earliest_cert_expiry - time()) / 86400`, format table, instant, unit `days`, thresholds amber under 21 and red under 7 |
| 5 | timeseries | HTTP status codes | `probe_http_status_code`, legend `{{instance}}` |
| 6 | stat | 24h availability | `avg_over_time(probe_success[24h])`, unit `percentunit`, thresholds red under 0.99 |

Panel 4's threshold must match whatever `system/cert-manager/prometheusrule.yaml` alerts on. Read that file and copy its window rather than inventing one — divergence between the alert and the colour is worse than no colour.

- [ ] **Step 4: Validate, run every query, commit, PR, verify after merge**

Same as Task 2 Steps 4–7, substituting `blackbox-exporter` and `homelab-blackbox.json`.

---

### Task 5: Backups overview dashboard

Five alerts across `system/monitoring-system/prometheusrule-backups.yaml` cover Longhorn backups, the Cleanuparr CronJob, and the arrs' built-in backups. There is currently no way to answer "did last night's backups run" other than noting that nothing paged.

This one is genuinely cross-cutting — it spans Longhorn, CronJobs in several namespaces, and CNPG — so it is the one dashboard in this plan that belongs in `system/monitoring-system/`, alongside `dashboard-cronjobs.yaml`.

**Files:**
- Create: `system/monitoring-system/dashboard-backups.yaml`
- Read first: `system/monitoring-system/prometheusrule-backups.yaml` and `system/monitoring-system/dashboard-cronjobs.yaml`

**Interfaces:**
- Consumes: `kube_job_*` and `kube_cronjob_*` from kube-state-metrics, `longhorn_backup_state` (needs Task 1), `cnpg_collector_last_available_backup_timestamp`.
- Produces: dashboard uid `homelab-backups`.

- [ ] **Step 1: Read the existing cronjob dashboard first**

```bash
grep -o '"expr": "[^"]*"' system/monitoring-system/dashboard-cronjobs.yaml | sort -u
```

If a panel here would duplicate one there, extend `dashboard-cronjobs.yaml` instead of creating a second dashboard. Two dashboards disagreeing about whether a backup ran is worse than one incomplete dashboard. Only continue to Step 2 if the overlap is small.

- [ ] **Step 2: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/backups-dashboard
```

- [ ] **Step 3: Confirm the metrics**

```bash
promq 'kube_job_status_failed'
promq 'kube_cronjob_status_last_schedule_time'
promq 'cnpg_collector_last_available_backup_timestamp'
promq 'longhorn_backup_state'
```

`longhorn_backup_state` requires Task 1. If Task 1 is not merged, drop panel 4 rather than shipping a permanently empty one.

- [ ] **Step 4: Write the dashboard**

ConfigMap `name` `grafana-dashboard-backups`, `namespace` `monitoring-system`, data key `homelab-backups.json`, `uid` `homelab-backups`, title `Homelab — Backups`, tags `["homelab", "backups"]`.

| # | Type | Title | Query |
|---|---|---|---|
| 1 | table | Hours since last CronJob run | `(time() - kube_cronjob_status_last_schedule_time) / 3600` by `namespace`, `cronjob`, instant, thresholds from `prometheusrule-backups.yaml` |
| 2 | stat | Failed jobs (24h) | `sum(increase(kube_job_status_failed[24h]))`, thresholds red at 1 |
| 3 | table | Failing jobs by name | `kube_job_status_failed > 0` by `namespace`, `job_name`, instant |
| 4 | table | Longhorn backup state | `longhorn_backup_state`, instant |
| 5 | stat | Hours since last CNPG backup | `(time() - max(cnpg_collector_last_available_backup_timestamp)) / 3600` |

Every threshold on panels 1 and 5 must be read out of `prometheusrule-backups.yaml`, not chosen. Put that requirement in the header comment so the next edit keeps them aligned, the same way `dashboard-temperatures.yaml` documents its link to `prometheusrule-temperature.yaml`.

- [ ] **Step 5: Validate, run every query, commit, PR, verify after merge**

Same as Task 2 Steps 4–7, substituting `monitoring-system` and `homelab-backups.json`.

---

### Task 6: CloudNativePG dashboard

Eight alerts, the most of any single rule file in the repo, and Vaultwarden's data sits behind it.

**Check for an official dashboard before writing one.** CloudNativePG publishes a Grafana dashboard in its own repository. Vendoring it into a ConfigMap is preferable to hand-writing panels, matching the existing preference for an app's official chart over a generic template. Only fall back to the table below if the upstream dashboard cannot be made to work.

**Files:**
- Create: `platform/cloudnative-pg/dashboard.yaml`

**Interfaces:**
- Consumes: `cnpg_*` from the existing `platform/cloudnative-pg/podmonitor.yaml`, labelled `cnpg_io_cluster`, `cnpg_io_instanceRole`, `namespace`.
- Produces: dashboard uid `homelab-cnpg`.

- [ ] **Step 1: Try the upstream dashboard first**

```bash
curl -sL https://raw.githubusercontent.com/cloudnative-pg/grafana-dashboards/main/charts/cluster/grafana-dashboard.json -o /tmp/cnpg-dashboard.json
python3 -m json.tool < /tmp/cnpg-dashboard.json > /dev/null && echo "valid JSON"
```

If the URL 404s, find the current path in the `cloudnative-pg/grafana-dashboards` repository rather than guessing another one. If nothing usable exists, skip to Step 3.

- [ ] **Step 2: Vendor it**

Wrap the JSON in the standard ConfigMap, indented four spaces under `data.homelab-cnpg.json: |`. Set `uid` to `homelab-cnpg` and title to `Homelab — CloudNativePG` so it matches the naming convention, and confirm its datasource references resolve — upstream dashboards often hardcode a datasource uid or use a variable named something other than `datasource`. Rewrite them to `${datasource}` and add the standard `templating` block from `system/vpa/dashboard.yaml` if it is missing.

Record the source URL and the retrieval date in the header comment. A vendored file with no provenance cannot be refreshed later.

Then skip to Step 4.

- [ ] **Step 3: Hand-write it (only if Step 1 found nothing)**

| # | Type | Title | Query |
|---|---|---|---|
| 1 | stat | Instances by role | `count by (cnpg_io_cluster, cnpg_io_instanceRole) (cnpg_backends_total)` |
| 2 | timeseries | Replication lag | `max by (cnpg_io_cluster) (cnpg_pg_replication_lag)`, unit `s` |
| 3 | timeseries | Active backends | `sum by (cnpg_io_cluster) (cnpg_backends_total)` |
| 4 | stat | Hours since last successful backup | `(time() - max by (cnpg_io_cluster) (cnpg_collector_last_available_backup_timestamp)) / 3600` |
| 5 | stat | Manual switchover required | `sum(cnpg_collector_manual_switchover_required)`, thresholds red at 1 |
| 6 | timeseries | Cache hit ratio | `sum by (cnpg_io_cluster) (rate(cnpg_cache_hits[5m])) / (sum by (cnpg_io_cluster) (rate(cnpg_cache_hits[5m])) + sum by (cnpg_io_cluster) (rate(cnpg_cache_miss[5m])))`, unit `percentunit` |

- [ ] **Step 4: Validate, run every query, commit, PR, verify after merge**

Same as Task 2 Steps 4–7, substituting `cloudnative-pg` and `homelab-cnpg.json`. For a vendored dashboard, "run every query" means opening it in Grafana after merge and confirming no panel reads "No data" — its query list is too long to check one at a time.

---

## Deliberately out of scope

- **Cilium and Loki dashboards.** Both have three alerts and live metrics, but Cilium has no directory (it is bootstrap-installed via helmfile) and would land in `monitoring-system`, and the Hubble dashboards upstream assume Hubble Relay metrics that may not be enabled. Revisit once the five above are in use.
- **Alert rules for anything added here.** Dashboards first. An alert needs a baseline, and there is none yet for in-place resize rates, per-route latency, or probe duration.
- **A homepage-style overview dashboard** stitching all of these together. Worth doing only once the individual dashboards have proven which panels get looked at.

## Sequencing

Task 1 is the only urgent one — six alerts are blind right now, and that is a live gap, not a missing nicety. It is worth merging on its own today.

Tasks 2 through 6 are independent of one another and each ships as its own PR. Order by what the cluster has actually hurt you with: Longhorn and Envoy first, then blackbox, backups, and CNPG.
