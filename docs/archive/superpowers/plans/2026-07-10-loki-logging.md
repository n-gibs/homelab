# Loki Logging + Grafana Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cluster-wide log aggregation (Loki + Alloy) and wire it into the existing Grafana instance, per `docs/archive/superpowers/specs/2026-07-10-loki-logging-design.md`.

**Architecture:** Two new `system/` apps — `loki` (grafana-community/loki chart, Monolithic mode, filesystem storage on NFS, 7-day retention) and `alloy` (grafana/alloy chart, single Deployment replica, `loki.source.kubernetes` tailing all pod logs via the K8s API, no DaemonSet/hostPath/privileged container needed). Grafana gets one new `additionalDataSources` entry pointing at Loki.

**Tech Stack:** Helm charts `grafana-community/loki` 18.4.4, `grafana/alloy` 1.10.1, existing `prometheus-community/kube-prometheus-stack` 86.2.0 (Grafana subchart). ArgoCD ApplicationSet (ArgoCD auto-discovers `system/*/app.yaml`).

## Global Constraints

- All chart versions and generated config verified against the live charts this session (`helm show values`, `helm template`) — copy exact values below verbatim, do not re-derive from memory.
- `CLAUDE.md`: `terraform fmt`/HCL rules don't apply here (no HCL in this plan); YAML rule "K8s manifests always include resources.requests/limits" applies — only `cpu` requests/limits are set, matching this repo's existing convention (VPA `Auto` mode fills in memory later).
- Never use `Ingress` — N/A here, neither new app is user-facing (no `httproute.yaml` for either).
- Never use `local-path` StorageClass — Loki's PVC uses `nfs`.
- No `sleep` — use `kubectl wait`/`--timeout` for all readiness checks below.
- **ArgoCD's git generator only scans `system/*/app.yaml` at `revision: main`** (`bootstrap/root/values.yaml:3`) — brand-new app directories are invisible to ArgoCD until they exist on `main`. This means Tasks 1 and 2 (new apps) commit directly to `main`, matching this repo's own `add-app.md` precedent ("Commit and watch... syncs automatically when merged to main"). Task 3 (editing the existing `monitoring-system` app) uses a feature branch + temporary `targetRevision` bump for pre-merge verification, since that Application already exists.
- Never add `Co-Authored-By` to commits.

---

### Task 1: `system/loki` — deploy Loki (Monolithic, filesystem storage, 7-day retention)

**Files:**
- Create: `system/loki/app.yaml`
- Create: `system/loki/values.yaml`
- Create: `system/loki/vpa.yaml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a reachable Loki HTTP API at `http://loki.loki.svc.cluster.local:3100` (push path `/loki/api/v1/push`, query API on the same port) — Task 2 (Alloy) and Task 3 (Grafana datasource) both depend on this URL.

- [ ] **Step 1: Write `system/loki/app.yaml`**

```yaml
chartName: loki
chartRepo: https://grafana-community.github.io/helm-charts
chartVersion: 18.4.4
```

- [ ] **Step 2: Write `system/loki/values.yaml`**

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

- [ ] **Step 3: Write `system/loki/vpa.yaml`**

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: loki
  namespace: loki
spec:
  targetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: loki
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: 10m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

- [ ] **Step 4: Validate the chart renders cleanly with these values**

Run:
```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm template loki grafana-community/loki --version 18.4.4 -n loki -f system/loki/values.yaml > /dev/null
```
Expected: exit code 0, no error output. (Already verified once this session with these exact values — this step re-confirms against the committed file.)

- [ ] **Step 5: Commit and push to `main`**

```bash
git add system/loki/
git commit -m "feat(loki): add Loki log storage (monolithic, filesystem, 7-day retention)"
git push origin main
```

- [ ] **Step 6: Verify live**

```bash
kubectl get application loki -n argocd -w
```
Wait for `HEALTH STATUS: Healthy` and `SYNC STATUS: Synced` (Ctrl-C once seen; nudge with `kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=normal --overwrite` if it hasn't picked up within ~3 min).

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki,app.kubernetes.io/component=single-binary -n loki --timeout=120s
kubectl get pvc -n loki
kubectl logs -n loki -l app.kubernetes.io/component=loki-canary --tail=20
```
Expected: pod `Ready`, PVC `Bound` on the `nfs` StorageClass, canary logs show no `missing entry` errors.

```bash
kubectl exec -n loki loki-0 -- cat /etc/loki/config/config.yaml | grep -A2 "^compactor:\|retention_period"
```
Expected: `retention_enabled: true`, `delete_request_store: filesystem`, `retention_period: 168h`.

---

### Task 2: `system/alloy` — deploy Alloy to ship pod logs to Loki

**Files:**
- Create: `system/alloy/app.yaml`
- Create: `system/alloy/values.yaml`
- Create: `system/alloy/vpa.yaml`

**Interfaces:**
- Consumes: Loki push endpoint `http://loki.loki.svc.cluster.local:3100/loki/api/v1/push` (Task 1).
- Produces: all cluster pod logs present in Loki, labeled `cluster="homelab"` plus Kubernetes metadata (`namespace`, `pod`, `container`, etc., attached automatically by `loki.source.kubernetes`) — Task 3's verification query depends on this.

- [ ] **Step 1: Write `system/alloy/app.yaml`**

```yaml
chartName: alloy
chartRepo: https://grafana.github.io/helm-charts
chartVersion: 1.10.1
```

- [ ] **Step 2: Write `system/alloy/values.yaml`**

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

- [ ] **Step 3: Write `system/alloy/vpa.yaml`**

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: alloy
  namespace: alloy
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: alloy
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: 10m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

- [ ] **Step 4: Validate the chart renders cleanly with these values**

Run:
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
helm template alloy grafana/alloy --version 1.10.1 -n alloy -f system/alloy/values.yaml > /dev/null
```
Expected: exit code 0, no error output. (Already verified once this session with these exact values.)

- [ ] **Step 5: Commit and push to `main`**

```bash
git add system/alloy/
git commit -m "feat(alloy): ship cluster pod logs to Loki"
git push origin main
```

- [ ] **Step 6: Verify live**

```bash
kubectl get application alloy -n argocd -w
```
Wait for `Healthy` / `Synced` (Ctrl-C once seen).

```bash
kubectl wait --for=condition=available deployment/alloy -n alloy --timeout=120s
kubectl logs -n alloy -l app.kubernetes.io/name=alloy --tail=50 | grep -i "error\|loki.write"
```
Expected: deployment `Available`, no repeated error lines in logs (occasional startup connection retries before Loki is fully ready are fine — Task 1 already confirmed Loki healthy first).

```bash
kubectl run -n loki loki-query-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -G "http://loki.loki.svc.cluster.local:3100/loki/api/v1/query" \
  --data-urlencode 'query={namespace="alloy"}' --data-urlencode 'limit=5'
```
Expected: JSON response with `"status":"success"` and at least one log line under `result` (Alloy's own pod logs, proving the full pipeline — discovery → tail → push → store → query — works end to end).

---

### Task 3: Wire Loki into Grafana as a datasource

**Files:**
- Modify: `system/monitoring-system/values.yaml` (add `grafana.additionalDataSources`)

**Interfaces:**
- Consumes: Loki query endpoint `http://loki.loki.svc.cluster.local:3100` (Task 1, already live).
- Produces: a `Loki` datasource selectable in Grafana Explore — end of this plan.

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b nik/loki-grafana-datasource
```

- [ ] **Step 2: Edit `system/monitoring-system/values.yaml`**

Add to the existing `grafana:` block (after the `grafana.ini` section, i.e. append as a new top-level key under `grafana:`):

```yaml
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.loki.svc.cluster.local:3100
```

- [ ] **Step 3: Validate the chart still renders cleanly**

Run:
```bash
helm template monitoring-system prometheus-community/kube-prometheus-stack --version 86.2.0 \
  -n monitoring-system -f system/monitoring-system/values.yaml \
  --show-only charts/grafana/templates/secret-env.yaml > /dev/null 2>&1 || \
helm template monitoring-system prometheus-community/kube-prometheus-stack --version 86.2.0 \
  -n monitoring-system -f system/monitoring-system/values.yaml | grep -A5 "Loki"
```
Expected: no render error, and the second command's output shows the `Loki`/`loki`/`proxy` datasource fields somewhere in the rendered manifests (the exact template path varies by chart internals — grepping the full render for `Loki` is the robust check here).

- [ ] **Step 4: Commit and push the branch**

```bash
git add system/monitoring-system/values.yaml
git commit -m "feat(monitoring): wire Loki as a Grafana datasource"
git push -u origin nik/loki-grafana-datasource
```

- [ ] **Step 5: Temporarily point the `monitoring-system` Application at the branch**

```bash
kubectl patch application monitoring-system -n argocd --type json -p '[
  {"op":"replace","path":"/spec/sources/1/targetRevision","value":"nik/loki-grafana-datasource"},
  {"op":"replace","path":"/spec/sources/2/targetRevision","value":"nik/loki-grafana-datasource"}
]'
kubectl annotate application monitoring-system -n argocd argocd.argoproj.io/refresh=normal --overwrite
```
(`sources[0]` is the Helm chart itself, pinned to `chartVersion` — untouched. `sources[1]`/`sources[2]` are the two git-repo sources, the ones that need to point at the branch.)

- [ ] **Step 6: Verify live**

```bash
kubectl get application monitoring-system -n argocd -w
```
Wait for `Healthy` / `Synced` against the branch (Ctrl-C once seen).

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring-system --timeout=120s
kubectl exec -n monitoring-system deploy/monitoring-system-grafana -- \
  grep -A4 "name: Loki" /etc/grafana/provisioning/datasources/*.yaml
```
Expected: pod `Ready`, and the datasource file shows `name: Loki`, `type: loki`, `url: http://loki.loki.svc.cluster.local:3100`.

Then confirm via the UI: open `https://grafana.nik-homelab.dev/explore`, select the `Loki` datasource, run `{namespace="alloy"}`, confirm log lines return.

- [ ] **Step 7: Revert the temporary targetRevision patch**

```bash
kubectl patch application monitoring-system -n argocd --type json -p '[
  {"op":"replace","path":"/spec/sources/1/targetRevision","value":"main"},
  {"op":"replace","path":"/spec/sources/2/targetRevision","value":"main"}
]'
```

- [ ] **Step 8: Merge to `main`**

```bash
git checkout main
git pull origin main
git merge --no-ff nik/loki-grafana-datasource -m "feat(monitoring): wire Loki as a Grafana datasource"
git push origin main
git branch -d nik/loki-grafana-datasource
git push origin --delete nik/loki-grafana-datasource
```

- [ ] **Step 9: Confirm `main` is in sync**

```bash
kubectl get application monitoring-system -n argocd
```
Expected: `Synced` / `Healthy`, now tracking `main` again (already verified functionally correct in Step 6 — this just confirms the post-merge state matches).
