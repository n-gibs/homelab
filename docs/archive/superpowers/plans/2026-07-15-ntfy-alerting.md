# ntfy Alerting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Alertmanager (in `system/monitoring-system/`) to push node-down, pod-crashlooping, and disk-pressure alerts to a phone/desktop via ntfy.sh.

**Architecture:** No new app, no new `PrometheusRule` resources — the three target failure modes are already covered by kube-prometheus-stack's bundled default alert rules. Add one sealed secret holding the full ntfy.sh webhook URL (topic embedded, since free-tier topics are public and the topic string is the only access control), mount it into the Alertmanager pod, and add an `ntfy` receiver + severity-based route to `alertmanager.config` in `values.yaml`.

**Tech Stack:** Helm (`kube-prometheus-stack` 86.2.0), Prometheus Alertmanager config, `kubeseal`/sealed-secrets, ArgoCD (auto-sync from `main`).

**Spec:** `docs/archive/superpowers/specs/2026-07-15-ntfy-alerting-design.md`

## Global Constraints

- Never commit plaintext secrets — sealing is table-driven via `secrets/registry.tsv` + `just seal` (see `secrets/README.md`).
- ArgoCD auto-syncs `system/monitoring-system` from `main`. Merge to `main` = deploy. Never manually `kubectl apply`/`kubectl edit` resources ArgoCD manages.
- No new `PrometheusRule` resources — `KubeNodeNotReady`/`KubeNodeUnreachable`, `KubePodCrashLooping`, `NodeFilesystemAlmostOutOfSpace`/`NodeFilesystemSpaceFillingUp` already exist via `defaultRules`.
- No self-hosted ntfy instance, no bridge/adapter service — use ntfy.sh's built-in `?template=alertmanager` formatting directly.
- Chart version (`86.2.0`) is Renovate-managed — don't bump it as part of this work.
- Never add `Co-Authored-By` lines to commit messages.
- No `sleep` commands — use `kubectl wait`/`--timeout` for anything that waits on cluster state.

---

### Task 1: Seal the ntfy webhook URL secret

**Files:**
- Modify: `secrets/registry.tsv` (add one row)
- Modify: `secrets/.secrets` (gitignored — local only, never committed)
- Create: `system/monitoring-system/ntfy-webhook-url.yaml` (sealed secret, committed)

**Interfaces:**
- Produces: a `SealedSecret` named `ntfy-webhook-url` in namespace `monitoring-system`, which decrypts to a `Secret` with one key `url` — consumed by Task 2 via `alertmanager.alertmanagerSpec.secrets` (mounts at `/etc/alertmanager/secrets/ntfy-webhook-url/url`).

- [ ] **Step 1: Generate a random topic slug and build the full webhook URL**

```bash
cd ~/homelab
SLUG="$(openssl rand -hex 8)"
echo "https://ntfy.sh/homelab-alerts-${SLUG}?template=alertmanager"
```

Expected: prints a URL like `https://ntfy.sh/homelab-alerts-3f9a1c2d8b7e4f01?template=alertmanager`. Keep this value — you'll need it both for `secrets/.secrets` below and to subscribe your phone/desktop ntfy app to the same topic later (Task 4).

- [ ] **Step 2: Add the value to `secrets/.secrets`**

Append a line (replace `<the-url-from-step-1>` with the actual value):

```bash
echo 'NTFY_WEBHOOK_URL=<the-url-from-step-1>' >> secrets/.secrets
```

- [ ] **Step 3: Add the registry row**

Edit `secrets/registry.tsv`, add this row (tab-separated, matching the existing rows' column alignment):

```
ntfy-webhook-url         monitoring-system  system/monitoring-system/ntfy-webhook-url.yaml    url=NTFY_WEBHOOK_URL
```

- [ ] **Step 4: Seal it**

```bash
just seal ntfy-webhook-url
```

Expected output: `Sealed: system/monitoring-system/ntfy-webhook-url.yaml`

- [ ] **Step 5: Verify the sealed output is well-formed**

```bash
cd ~/homelab
head -5 system/monitoring-system/ntfy-webhook-url.yaml
```

Expected: valid YAML starting with `apiVersion: bitnami.com/v1alpha1` and `kind: SealedSecret`, `metadata.name: ntfy-webhook-url`, `metadata.namespace: monitoring-system`. No plaintext URL visible anywhere in the file (only base64-encoded ciphertext under `spec.encryptedData.url`).

- [ ] **Step 6: Commit**

```bash
git add secrets/registry.tsv system/monitoring-system/ntfy-webhook-url.yaml
git commit -m "feat(monitoring): add sealed ntfy webhook URL secret"
```

Do **not** `git add secrets/.secrets` — it's gitignored; confirm with `git status --short` that it doesn't show up as staged.

---

### Task 2: Wire the Alertmanager receiver and route

**Files:**
- Modify: `system/monitoring-system/values.yaml`

**Interfaces:**
- Consumes: the `ntfy-webhook-url` secret from Task 1, mounted at `/etc/alertmanager/secrets/ntfy-webhook-url/url`.
- Produces: an `ntfy` Alertmanager receiver and a route matching `severity =~ "warning|critical"`, which Task 3/4 verify live.

- [ ] **Step 1: Add the secret mount and Alertmanager config**

Read the current file first:

```bash
cat system/monitoring-system/values.yaml
```

Add the following two top-level keys to `system/monitoring-system/values.yaml` (append at the end of the file, after the existing `grafana:` block):

```yaml
alertmanager:
  alertmanagerSpec:
    secrets:
      - ntfy-webhook-url
  config:
    global:
      resolve_timeout: 5m
    inhibit_rules:
      - source_matchers: ['severity = critical']
        target_matchers: ['severity =~ warning|info']
        equal: ['namespace', 'alertname']
      - source_matchers: ['severity = warning']
        target_matchers: ['severity = info']
        equal: ['namespace', 'alertname']
      - source_matchers: ['alertname = InfoInhibitor']
        target_matchers: ['severity = info']
        equal: ['namespace']
      - target_matchers: ['alertname = InfoInhibitor']
    route:
      group_by: ['namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'null'
      routes:
        - receiver: 'null'
          matchers: ['alertname = "Watchdog"']
        - receiver: 'ntfy'
          matchers: ['severity =~ "warning|critical"']
          continue: false
    receivers:
      - name: 'null'
      - name: 'ntfy'
        webhook_configs:
          - url_file: /etc/alertmanager/secrets/ntfy-webhook-url/url
            send_resolved: true
    templates:
      - '/etc/alertmanager/config/*.tmpl'
```

- [ ] **Step 2: Validate the rendered chart locally**

```bash
cd ~/homelab
helm repo update prometheus-community >/dev/null
helm template monitoring-system prometheus-community/kube-prometheus-stack \
  --version 86.2.0 \
  -f system/monitoring-system/values.yaml \
  --show-only templates/alertmanager/secret.yaml \
  | awk -F': ' '/alertmanager\.yaml:/{print $2}' | tr -d '"' | base64 -d
```

Expected: valid YAML printed to stdout, containing:
- `receivers:` with both `name: "null"` and a `name: ntfy` entry with `webhook_configs` pointing at `url_file: /etc/alertmanager/secrets/ntfy-webhook-url/url`
- `route.routes` with the `Watchdog` matcher routing to `"null"` listed **before** the `ntfy` route
- The four `inhibit_rules` unchanged from the chart defaults

If the command errors or the output doesn't match, fix `values.yaml` and re-run — do not proceed to Task 3 with a broken render.

- [ ] **Step 3: Commit**

```bash
git add system/monitoring-system/values.yaml
git commit -m "feat(monitoring): route warning/critical alerts to ntfy"
```

---

### Task 3: Deploy and verify Alertmanager comes up healthy

**Files:** none (verification only)

**Interfaces:**
- Consumes: commits from Task 1 and Task 2, once merged to `main`.

- [ ] **Step 1: Merge to main**

```bash
cd ~/homelab
git checkout main
git merge --ff-only <feature-branch>   # or open/merge a PR per your usual flow
git push origin main
```

- [ ] **Step 2: Wait for ArgoCD to sync monitoring-system**

```bash
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/monitoring-system -n argocd --timeout=180s
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/monitoring-system -n argocd --timeout=180s
```

Expected: both commands print `application.argoproj.io/monitoring-system condition met`.

- [ ] **Step 3: Confirm the Alertmanager pod picked up the new secret mount without crashlooping**

```bash
kubectl get pods -n monitoring-system -l app.kubernetes.io/name=alertmanager
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=alertmanager -n monitoring-system --timeout=120s
```

Expected: pod status `Running`, `1/1` or `2/2` ready (depending on sidecar count), no restarts spike. If it's `CrashLoopBackOff`, check logs before doing anything else:

```bash
kubectl logs -n monitoring-system -l app.kubernetes.io/name=alertmanager -c alertmanager --tail=50
```

A config-load error here almost always means a typo in the `url_file` path or the secret name in `alertmanagerSpec.secrets` not matching `ntfy-webhook-url` exactly. **Rollback if broken:**

```bash
git revert HEAD~1 HEAD --no-edit   # reverts both Task 1 and Task 2 commits
git push origin main
```

- [ ] **Step 4: Confirm the secret actually mounted**

```bash
kubectl exec -n monitoring-system alertmanager-monitoring-system-kube-pro-alertmanager-0 -- \
  cat /etc/alertmanager/secrets/ntfy-webhook-url/url
```

Expected: prints the full `https://ntfy.sh/homelab-alerts-...` URL from Task 1 (confirms the mount path in `values.yaml` matches reality, not just the rendered template).

---

### Task 4: End-to-end live verification

**Files:** none (verification only)

- [ ] **Step 1: Subscribe your phone/desktop to the topic**

Install the ntfy app (iOS/Android) or use the web app at `https://ntfy.sh/homelab-alerts-<your-slug>` (same URL from Task 1, minus the `?template=alertmanager` query string), and subscribe to the topic.

- [ ] **Step 2: Trigger a real `KubePodCrashLooping` alert**

```bash
kubectl run crashloop-test --image=busybox -n default -- /bin/false
```

This creates a pod that exits immediately and crashloops, which fires `KubePodCrashLooping` (severity `warning`) once it's been in `CrashLoopBackOff` continuously for the rule's `for: 15m` duration (confirmed live via `kubectl get prometheusrules ... -o json` — longer than this step originally assumed; budget ~15-20 minutes, not "a few").

- [ ] **Step 3: Confirm the alert reached Alertmanager**

```bash
kubectl port-forward -n monitoring-system svc/monitoring-system-kube-pro-alertmanager 9093:9093 &
PF_PID=$!
curl -s --retry 5 --retry-delay 1 --retry-connrefused http://localhost:9093/api/v2/alerts | grep -o '"alertname":"KubePodCrashLooping"'
kill "$PF_PID"
```

`curl --retry-connrefused` handles the port-forward's brief startup window without a fixed wait. Expected: at least one match once the alert has fired (may take 2-5 minutes — if empty, the port-forward is up but the alert hasn't fired yet; re-run the `curl` line alone, don't restart the port-forward).

- [ ] **Step 4: Confirm the push notification arrived**

Check the ntfy app/web subscription from Step 1 — expect a notification titled around `[FIRING:1] KubePodCrashLooping` (ntfy's `alertmanager` template formats the title/body from the webhook payload).

- [ ] **Step 5: Clean up the test pod**

```bash
kubectl delete pod crashloop-test -n default
```

- [ ] **Step 6: Confirm the resolved notification arrives (optional but recommended)**

Since `send_resolved: true` is set, once `KubePodCrashLooping` clears (a few minutes after Step 5), expect a second ntfy notification indicating the alert resolved.

---

## Self-Review Notes

- **Spec coverage:** all three "Changes" sections of the design spec map 1:1 to Task 1 (secret) and Task 2 (values.yaml). The spec's "Verification" section maps to Task 3 (deploy health) and Task 4 (live alert round-trip). The spec's "Out of scope" items (no new PrometheusRules, no bridge service, no dead-man's-switch, default timing, unverified rate limits) are deliberately **not** tasks — they're documented exclusions, not deferred work.
- **Rollback path:** Task 3 Step 3 gives an explicit `git revert` command rather than "fix it somehow," since a broken Alertmanager config is a self-inflicted outage of the whole alerting pipeline.
- **No placeholders:** the only user-supplied value is the topic slug, which Task 1 Step 1 generates concretely (`openssl rand -hex 8`) rather than leaving as a `<TBD>`.
