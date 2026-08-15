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

### Task 2 (revised): Correct the qBittorrent health-port claim

**Superseded.** The original Task 2 built a blackbox Probe against gluetun's health server.
Task 1 measured that endpoint returning 200 with an empty body through a confirmed tunnel
outage, so the probe would have asserted nothing. Gap 1 is abandoned — no Probe, no
`EndpointDown` narrowing, no `VPNTunnelDown`. See the spec's section 1 for the evidence.

What remains is the defect the measurement exposed: a comment that vouches for a signal that
cannot work, and would lead someone to configure Cleanuparr to trust it.

**Files:**
- Modify: `apps/qbittorrent/values.yaml` — the `HEALTH_SERVER_ADDRESS` comment (~line 69) and
  the `health` Service port comment (~line 93)

**Interfaces:**
- Consumes: Task 1's measurement.
- Produces: nothing. No later task depends on this.

- [ ] **Step 1: Correct both comments**

Replace the claim that the health server distinguishes a live tunnel from a live internet. The
replacement must state the measured fact and the consequence, without narrating the incident —
detail belongs in the commit message. Keep the existing explanation of *why* the port is bound
to all interfaces; only the claim about what it proves is wrong.

The `health` Service port comment must end up saying, in the file's own voice: this endpoint
reports that gluetun's health server is answering, not that the Mullvad tunnel is up — measured
2026-08-14 returning 200 with an empty body throughout a confirmed outage — so nothing should
gate tunnel-dependent behaviour on it.

- [ ] **Step 2: Verify nothing else in the repo relies on the old claim**

```bash
grep -rn '9999' --include='*.yaml' --include='*.md' . | grep -v '.superpowers'
```

Expected: hits in `apps/qbittorrent/values.yaml` and the spec/plan docs only. Any other file
gating on this endpoint is a finding — report it rather than fixing it.

- [ ] **Step 3: Validate and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('apps/qbittorrent/values.yaml')); print('ok')"
git add apps/qbittorrent/values.yaml
git commit -m "fix(qbittorrent): the health server does not prove the tunnel is up

The comment here claimed Cleanuparr's Queue Cleaner could gate on :9999 to
tell a dead tunnel from a dead internet, and so avoid striking torrents that
a VPN outage had stalled. Measured 2026-08-14: the endpoint returns 200 with
an empty body unconditionally, including under sub-second polling through a
confirmed outage with wireguard write errors in gluetun's log. The gate
cannot trip, and the comment was the reason someone would have built on it.

The real signal is gluetun's control server on :8000, which answers 401
without auth configured. Left alone deliberately -- see the spec."
```

This is a comment-only change to an app that is already deployed, so it is safe to batch into
the same PR as Task 3 rather than deploying on its own.

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
