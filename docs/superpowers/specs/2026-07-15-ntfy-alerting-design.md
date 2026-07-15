# Wire Alertmanager -> ntfy for push notifications

## Context

`system/monitoring-system/` runs `kube-prometheus-stack` (Prometheus Operator + bundled Alertmanager + Grafana). Alertmanager is deployed but has no configured receivers — alerts fire into Prometheus/Alertmanager's UI only, nothing reaches a phone or desktop. `ruleSelectorNilUsesHelmValues: false` is already set, so the Operator watches all `PrometheusRule` CRDs cluster-wide.

This wires Alertmanager to send push notifications via [ntfy](https://ntfy.sh) for the failure modes most likely to matter in a 3-node homelab: a node going down, a pod crashlooping, and disk pressure.

## Research

- The three target failure modes are **already covered by kube-prometheus-stack's bundled default alert rules** (`defaultRules`, on by default, not overridden in this repo's `values.yaml`) — confirmed live via `kubectl get prometheusrules -n monitoring-system`:
  - `KubeNodeNotReady` / `KubeNodeUnreachable` (severity `warning`) — node down
  - `KubePodCrashLooping` (severity `warning`) — pod crashlooping
  - `NodeFilesystemAlmostOutOfSpace` / `NodeFilesystemSpaceFillingUp` (severity `warning`/`critical`) — disk pressure

  No new `PrometheusRule` resources are needed — this is a routing/receiver problem, not a rule-authoring problem.

- ntfy has a **built-in Alertmanager template** (`?template=alertmanager` query param, or `X-Template: alertmanager` header) that formats Alertmanager's native webhook JSON into a readable title/message — confirmed via `docs.ntfy.sh/publish/`. No bridge/adapter service required; Alertmanager's stock `webhook_configs` receiver posts directly to `https://ntfy.sh/<topic>?template=alertmanager`.

- **Reserved (access-controlled) topics on ntfy.sh require a Pro subscription** — confirmed via ntfy's docs/FAQ. On the free tier, a topic is public: anyone who knows the exact topic string can publish or subscribe to it. A free-tier access token authenticates *you* to your own ntfy.sh account; it does **not** restrict who else can use a topic name they've discovered. So there's no real security difference between "free-tier token" and "no auth" — **the topic name itself is the only thing standing between "just my alerts" and anyone who finds this string.** That makes it a credential, not a config value, even though ntfy has no separate auth mechanism for it on the free tier.

- Alertmanager's `webhook_config` supports `url_file` as an alternative to `url` (mutually exclusive, confirmed via `prometheus.io/docs/alerting/latest/configuration/#webhook_config`) — the URL is read from a mounted file at runtime instead of living in the rendered config. This lets the full webhook URL (topic embedded) go through this repo's existing sealed-secret pattern instead of sitting in plaintext `values.yaml`/git history.

- `alertmanager.config` in `values.yaml` is a Helm values map merged with the chart's default config. Helm deep-merges maps but **replaces lists wholesale** — so overriding `route.routes`, `receivers`, or `inhibit_rules` means restating the chart's existing defaults (the `Watchdog -> null` route, the severity inhibition rules) in full alongside the new `ntfy` addition, not just appending to them.

## Changes

### 1. Secret: ntfy webhook URL

Add to `secrets/registry.tsv`:
```
ntfy-webhook-url  monitoring-system  system/monitoring-system/ntfy-webhook-url.yaml  url=NTFY_WEBHOOK_URL
```
Not a `generate:` value — the topic needs to be a real ntfy.sh URL with a random, high-entropy slug we pick ourselves (e.g. `https://ntfy.sh/homelab-alerts-x7k2p9qz?template=alertmanager`), so it goes in `secrets/.secrets` as a manually-set plaintext value, then `just seal ntfy-webhook-url`.

### 2. `system/monitoring-system/values.yaml`

Mount the secret into Alertmanager:
```yaml
alertmanager:
  alertmanagerSpec:
    secrets:
      - ntfy-webhook-url
```

Rewrite `alertmanager.config` to add the `ntfy` receiver (using `url_file`, not `url`) and a severity-based route, preserving the chart's existing `Watchdog` null-route and inhibit_rules:
```yaml
alertmanager:
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

### 3. Verification

- `helm template` the chart locally with the updated values to confirm the rendered Alertmanager config secret is valid YAML and the receiver/route show up as expected.
- After deploy, trigger a real alert (e.g. temporarily cordon/drain a node, or `kubectl delete` a pod repeatedly to trip `KubePodCrashLooping`) and confirm a push notification arrives on phone/desktop via the ntfy app/web subscribed to the topic.
- Confirm `Watchdog` (Alertmanager's own dead-man's-switch, fires every interval) still routes to `null` and does **not** spam ntfy — this is why the null route must come first with no `continue: true`.

## Out of scope

- No new `PrometheusRule` resources (existing default rules cover all three target failure modes).
- No self-hosted ntfy instance, no bridge/adapter service.
- No additional alert categories (memory/CPU pressure, ArgoCD sync failures, cert expiry) — can be added later by adding more routes to the same `ntfy` receiver.
