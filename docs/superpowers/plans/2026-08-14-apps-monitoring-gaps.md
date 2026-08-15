# Apps Monitoring Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alert when the Mullvad tunnel behind qBittorrent dies, and start scraping the metrics Immich already knows how to emit.

**Architecture:** Two independent changes, no new components. A third blackbox `Probe` points at gluetun's existing health server on the `qbittorrent` Service, and the existing unselectored `EndpointDown` alert is narrowed so the new target doesn't inherit it. Separately, a one-line Helm values flip makes the Immich chart create its own ServiceMonitors.

**Tech Stack:** Prometheus Operator CRDs (`Probe`, `PrometheusRule`, `ServiceMonitor`), blackbox-exporter, bjw-s/immich Helm values, ArgoCD.

**Spec:** `docs/superpowers/specs/2026-08-14-apps-monitoring-gaps-design.md`

## Global Constraints

- **ArgoCD auto-syncs `main`. Merging IS deploying.** `system/` is covered by a stack ApplicationSet globbing `system/*/app.yaml`, so a branch cannot be synced for verification. Every "verify in cluster" step therefore happens *after* the merge, and a failed verification is fixed forward with a follow-up commit, never by leaving `main` broken.
- **`main` reflects applied state** — do not merge a task until its pre-merge checks pass, and do not start the next task until the previous one is confirmed live.
- **Never run `sleep`**, in a shell or a manifest. Poll with `kubectl wait` or re-run the command.
- **Never add `Co-Authored-By` trailers** or reference Claude/Anthropic in commit messages.
- **Comments: non-obvious "why" only.** Incident detail belongs in the commit message, not the YAML.
- All Prometheus queries run from a throwaway in-cluster pod, because the Prometheus pod has no shell:
  ```bash
  kubectl run promq-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
    curl -sG 'http://monitoring-system-kube-pro-prometheus.monitoring-system.svc:9090/api/v1/query' \
    --data-urlencode 'query=QUERY_HERE'
  ```
  This is referred to below as **PROMQ**. Substitute the query; keep the single quotes.
- Branch for all work: `monitoring/apps-gaps` (already exists, holds the spec).

---

### Task 1: Measure gluetun's health server before designing around it

The spec's Step 0. Everything in Task 2 assumes the health server answers non-2xx when the tunnel is down. That is an assumption, not a measurement. This task ends with the assumption confirmed or the module choice changed. **No manifest is written in this task.**

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-apps-monitoring-gaps-design.md` (record findings under Step 0)

**Interfaces:**
- Consumes: nothing.
- Produces: two decisions consumed by Task 2 — (a) module name, `http_2xx` or a new `http_2xx_body` defined in `system/blackbox-exporter/values.yaml`; (b) the `for:` duration on `VPNTunnelDown`.

- [ ] **Step 1: Record the healthy response**

```bash
kubectl run promq-healthy --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -o /tmp/body -w 'status=%{http_code}\n' \
  http://qbittorrent.qbittorrent.svc.cluster.local:9999/ ; \
kubectl run promq-healthy-body --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://qbittorrent.qbittorrent.svc.cluster.local:9999/
```

Expected: `status=200` and a short body. Write down both the code and the exact body string.

- [ ] **Step 2: Break the tunnel deliberately**

This stalls every torrent for as long as it takes gluetun to self-heal. Do it when nothing is mid-import. The `gluetun` container holds `NET_ADMIN`, which is what makes this possible:

```bash
POD=$(kubectl get pod -n qbittorrent -l app.kubernetes.io/name=qbittorrent -o name | head -1)
kubectl exec -n qbittorrent "$POD" -c gluetun -- ip link set tun0 down
```

- [ ] **Step 3: Record the unhealthy response immediately**

Re-run both commands from Step 1. Record the status code and body. This is the measurement the whole task exists for.

- [ ] **Step 4: Record how fast gluetun self-heals**

Re-run the Step 1 command repeatedly (no `sleep` — just re-run) until it returns 200 again, and note roughly how long the recovery took. Then confirm the tunnel is genuinely back:

```bash
kubectl logs -n qbittorrent "$POD" -c gluetun --tail=30
```

Expected: log lines showing the VPN restarting and a new connection established. If it does not recover on its own, restart the pod: `kubectl delete pod -n qbittorrent "$POD"`.

- [ ] **Step 5: Decide the module and the `for:` duration**

- Unhealthy status was non-2xx → module stays `http_2xx`.
- Unhealthy status was 200 → `http_2xx` is decorative. Task 2 must instead add a module to `system/blackbox-exporter/values.yaml` alongside the existing two, using the healthy body string recorded in Step 1:

```yaml
    http_2xx_body:
      prober: http
      timeout: 5s
      http:
        follow_redirects: true
        preferred_ip_protocol: ip4
        valid_http_versions: [HTTP/1.1, HTTP/2.0]
        fail_if_body_not_matches_regexp:
          - "EXACT_HEALTHY_BODY_STRING_FROM_STEP_1"
```

- `for:` is the larger of (self-heal time from Step 4, rounded up) and 5m. 5m is the floor because the qBittorrent Deployment is a single replica, so an ordinary pod restart or image pull must not page. If self-heal is faster than 5m, use 5m and accept that the alert only describes a tunnel that is genuinely stuck — which is the alert worth having.

- [ ] **Step 6: Record findings in the spec and commit**

Replace the spec's "That is unverified" paragraph with the measured codes, the body string, the observed self-heal time, and the two decisions.

```bash
git add docs/superpowers/specs/2026-08-14-apps-monitoring-gaps-design.md
git commit -m "docs(monitoring): record gluetun health server behaviour

Measured healthy and unhealthy status codes against the health server on
the qbittorrent Service, and how long gluetun takes to restart the VPN on
its own. Fixes the module choice and the alert's for: duration, both of
which the design had assumed."
```

---

### Task 2: Probe the tunnel and narrow EndpointDown

**Files:**
- Modify: `system/blackbox-exporter/probes.yaml` (append a third Probe)
- Modify: `system/blackbox-exporter/prometheusrule.yaml:19-31` (narrow `EndpointDown`, add `VPNTunnelDown`)
- Modify: `system/blackbox-exporter/values.yaml` — **only if** Task 1 Step 5 chose the body-matching module
- Modify: `apps/qbittorrent/values.yaml:93-99` (note the second consumer of the health port)

**Interfaces:**
- Consumes: module name and `for:` duration from Task 1.
- Produces: the label `probe_class="vpn"` on the new target — the selector every rule in this task keys off. No later task depends on it.

- [ ] **Step 1: Append the Probe**

Add to the end of `system/blackbox-exporter/probes.yaml`. Substitute `MODULE` and keep the comment — the file states a "public hostnames, not Services" rule and this deliberately breaks it:

```yaml
---
# The one Service-level probe here, and deliberately so. gluetun's health server has no
# route and no browser path to test; what it carries is whether the Mullvad tunnel is up,
# which nothing else in the cluster measures. A dead tunnel stalls every torrent at once
# while the pod stays Running and qbittorrent.nik-homelab.dev keeps answering 200.
#
# probe_class exists to keep this target out of EndpointDown, which is otherwise unselectored
# and would page critical for a stalled download queue.
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: vpn
  namespace: blackbox-exporter
  labels:
    release: monitoring-system
spec:
  interval: 60s
  module: MODULE
  prober:
    url: blackbox-exporter.blackbox-exporter.svc.cluster.local:9115
  targets:
    staticConfig:
      static:
        - http://qbittorrent.qbittorrent.svc.cluster.local:9999
      labels:
        probe_class: vpn
```

- [ ] **Step 2: Narrow `EndpointDown`**

In `system/blackbox-exporter/prometheusrule.yaml`, change line 20 only:

```yaml
          expr: probe_success{probe_class!="vpn"} == 0
```

Append to that alert's existing comment block:

```yaml
        # probe_class!="vpn" excludes the gluetun health probe, which is not a user-facing
        # endpoint and has its own warning-level alert. Pre-existing targets carry no
        # probe_class label at all, and != matches the empty label, so they are unaffected.
```

- [ ] **Step 3: Add `VPNTunnelDown`**

Insert after the `EndpointDown` block, substituting `FOR` from Task 1:

```yaml
        # Warning, not critical: Mullvad rotates servers and gluetun restarts its own VPN on
        # failure, so short outages are self-healing. Cleanuparr already gates its Queue
        # Cleaner on this same endpoint, so nothing is left unhandled — this only means being
        # told, rather than finding out from a queue that stopped moving.
        - alert: VPNTunnelDown
          expr: probe_success{probe_class="vpn"} == 0
          for: FOR
          labels:
            severity: warning
          annotations:
            summary: qBittorrent's VPN tunnel is down
            description: >-
              gluetun's health server has reported the Mullvad tunnel down for FOR. Every
              torrent stalls while this is true, and Cleanuparr's Queue Cleaner will hold off
              striking them. Check the gluetun container's logs in the qbittorrent pod; if it
              is looping on connection failures, the Mullvad credentials or the chosen server
              country are the usual causes.
```

- [ ] **Step 4: Note the second consumer in the qBittorrent values**

`apps/qbittorrent/values.yaml` explains the `health` port as existing for Cleanuparr. Extend that comment so neither consumer is removed on the assumption it is the only one:

```yaml
      # gluetun's health server. Two consumers: Cleanuparr's connectivity check at
      # http://qbittorrent.qbittorrent.svc.cluster.local:9999, and the vpn Probe in
      # system/blackbox-exporter/probes.yaml. Not routed publicly.
```

- [ ] **Step 5: Validate the YAML parses before merging**

```bash
python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]; print('ok')" \
  system/blackbox-exporter/probes.yaml \
  system/blackbox-exporter/prometheusrule.yaml \
  apps/qbittorrent/values.yaml
```

Expected: `ok`. A `PrometheusRule` with invalid PromQL parses as YAML but is rejected by the operator, which is caught in Step 8.

- [ ] **Step 6: Capture the pre-merge target count**

Run **PROMQ** with query `count(probe_success)`. Record the number. It should be 17 (16 in the `apps` Probe + 1 in `apps-auth`). This is the number Step 8 checks against.

- [ ] **Step 7: Commit and merge**

```bash
git add system/blackbox-exporter/ apps/qbittorrent/values.yaml
git commit -m "monitoring(vpn): alert when the Mullvad tunnel is down

gluetun's health server has been on the qbittorrent Service since Cleanuparr
needed it, and nothing read it. A dead tunnel stalls every torrent at once
while the pod stays Running and the public endpoint keeps answering 200.

EndpointDown was unselectored, so the new target would have inherited a
critical page for what is a stalled download queue. It now excludes
probe_class=vpn; pre-existing targets carry no such label and != matches the
empty label, so their coverage is unchanged."
git push -u origin monitoring/apps-gaps
gh pr create --fill
```

Merge once CI is green. ArgoCD syncs `main`.

- [ ] **Step 8: Verify in cluster after sync**

```bash
kubectl get probe -n blackbox-exporter
kubectl get prometheusrule -n blackbox-exporter blackbox-exporter -o yaml | grep -A2 'VPNTunnelDown'
```

Then, with **PROMQ**:

| Query | Expected |
|---|---|
| `probe_success{probe_class="vpn"}` | one series, value `1` |
| `count(probe_success{probe_class!="vpn"})` | the number from Step 6, expected 17 — **this is the check that matters** |
| `ALERTS{alertname="VPNTunnelDown"}` | empty |

If the second query returns fewer series than Step 6 recorded, the selector has silently dropped endpoint coverage. Fix forward immediately.

- [ ] **Step 9: Trip-test the alert**

Confirm the rule actually fires, using an invented severity so no Alertmanager route matches and nothing notifies (`amtool` lives in the Alertmanager pod; the Prometheus pod has no shell). Temporarily commit a copy of the alert with `expr: probe_success{probe_class="vpn"} == 1`, `for: 1m`, `severity: triptest`, and name `VPNTunnelDownTripTest`. After sync, **PROMQ** `ALERTS{alertname="VPNTunnelDownTripTest"}` should return a firing series. Then revert that commit and confirm it clears.

---

### Task 3: Enable Immich metrics

Independent of Tasks 1–2. Do not start it until Task 2 is confirmed live, so that if Prometheus behaves oddly there is only one recent change to look at.

**Files:**
- Modify: `apps/immich/values.yaml:30-32`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — chart-created ServiceMonitors, no downstream task.

- [ ] **Step 0: Branch fresh from main**

Task 2's PR merged `monitoring/apps-gaps`, so it is gone. Start clean:

```bash
git checkout main && git pull && git checkout -b monitoring/immich-metrics
```

- [ ] **Step 1: Record the baseline head series**

Run **PROMQ** with query `prometheus_tsdb_head_series`. Record the number and the wall-clock time. Without this, the after-measurement means nothing.

- [ ] **Step 2: Flip the flag**

In `apps/immich/values.yaml`:

```yaml
immich:
  # true makes the chart create the api and microservices ServiceMonitors itself -- there is
  # no hand-written one to keep in sync. Watch prometheus_tsdb_head_series after changing
  # this: the telemetry includes per-endpoint histograms.
  metrics:
    enabled: true
```

- [ ] **Step 3: Commit and merge**

```bash
git add apps/immich/values.yaml
git commit -m "monitoring(immich): scrape the metrics the chart already ships

metrics.enabled was false, so the largest stateful app after Nextcloud was
known only by pod health and a blackbox 200. Chart 0.13.1 creates the api and
microservices ServiceMonitors itself when this is true."
git push -u origin monitoring/immich-metrics
gh pr create --fill
```

- [ ] **Step 4: Verify the ServiceMonitors exist and scrape**

```bash
kubectl get servicemonitor -n immich
```

Expected: two ServiceMonitors created by the chart. Then **PROMQ** `up{namespace="immich"}` — expected: series with value `1`. If they are `0`, check that the metrics ports are on the Service: `kubectl get svc -n immich -o yaml | grep -A5 ports`.

- [ ] **Step 5: Measure the cardinality cost**

At least an hour after Step 4, run **PROMQ** `prometheus_tsdb_head_series` again and compare with Step 1. Also run `count({namespace="immich"})` for the immich-specific contribution.

Prometheus holds ~10.1GB of blocks in a 20Gi Longhorn volume at 10d retention. If the immich series are a small fraction of the existing head, record the number in the commit message of a follow-up doc tweak and stop. If they are a large fraction, scope Immich's telemetry down rather than absorbing it — the volume expands in place, but growing it is a decision, not a default.

- [ ] **Step 6: Record the result in the spec**

Append the measured before/after head series to the spec's Immich section and commit. This is the number that justifies (or reverses) the change later.

---

## Not in this plan, deliberately

- `exportarr` sidecars for the arrs, a qBittorrent exporter, and Jellyfin metrics — 6–7 containers on a cluster where worker-00 is the density hotspot. Revisit when an arr incident goes undetected.
- A dashboard for nextcloud / vaultwarden / immich — see the spec's "Out of scope" section for why it was cut rather than deferred.
- Immich job-queue and ML alerts or panels. They can only be written honestly against metric names observed after Task 3, and there is no evidence yet about which of them fail in ways worth paging for.
