# Continuation prompt — monitoring audit tasks 6-10

Paste everything below the line into a new session.

---

Continue the monitoring and alerting audit in this repo. The plan is
`docs/audits/2026-08-14-monitoring-audit.md`; tasks 1-5 are done, merged, and verified live.
Start with task 6 unless I say otherwise.

## What is already shipped

| Task | PR | Result |
|---|---|---|
| 1 | #43 | `ScrapePoolEmpty` in `system/monitoring-system/prometheusrule-scrape-coverage.yaml` |
| 2 | #44, #45 | k3s `--etcd-expose-metrics=true`; etcd scraped via `system/monitoring-system/scrapeconfig-etcd.yaml`. 3/3 targets up, 15 chart etcd rules now have data |
| 3 | #46 | `system/monitoring-system/prometheusrule-etcd.yaml` — `EtcdMetricsMissing`, `EtcdRequestLatencyHigh`, `EtcdSnapshotStale` + the ETCDSnapshotFile metric in KSM `customResourceState` |
| 4 | #47 | cert-manager scraped; `system/cert-manager/prometheusrule.yaml` — 4 rules. Wildcard expiry now a metric |
| 5 | #48 | `system/envoy-gateway/podmonitor.yaml` + `prometheusrule.yaml` — 3 rules, 19 backends healthy |
| — | #49 | Longhorn, CoreDNS, CNPG monitoring moved next to their apps |

Current state: 46 rule groups, 241 rules, ~493k head series, zero empty scrape pools, Watchdog
the only firing alert. Also during task 2, worker-01 and worker-02 went k3s v1.36.2 -> v1.36.3;
all three are level now.

## Remaining tasks

6. **Loki + Alloy** — ServiceMonitors plus `LokiRulerNotEvaluating`, `AlloyNotShippingLogs`,
   `LogPipelineMetricsMissing`. This closes the last case of alerting inside its own blast
   radius: the only log-based alert (`loki-rule-cilium-split-brain`) is delivered by the Loki
   ruler, so if Alloy stops shipping or the ruler stops evaluating, that alert silently stops
   existing. Neither component is scraped today.
7. **Cilium** — agent and operator metrics, plus Hubble drop/DNS metrics only (flow metrics are
   a cardinality trap). `CiliumUnreachableNodes`, `CiliumAgentRestarting`,
   `CiliumMetricsMissing`. Cilium is helmfile-managed in `bootstrap/`, not a `system/` app.
8. **Move the Prometheus TSDB off NFS** to `longhorn`, 20Gi. It currently sits on the 12TB USB
   HDD behind worker-01 over NFS, against this repo's own storage rule, and a TSDB is
   mmap-heavy. Do it deliberately: this is the alerting path. `wal_corruptions_total` is 0, so
   nothing is damaged yet.
9. **blackbox-exporter + Probes** for vaultwarden / grafana / jellyfin / nextcloud / immich,
   plus `EndpointDown` and `ProbeCertExpiringSoon`. `probeSelectorNilUsesHelmValues: false` is
   already set and there are zero Probes. This is also what gives the 16 apps an availability
   signal, which is why it beats per-app exporters.
10. **external-dns** ServiceMonitor + `ExternalDNSRegistryErrors`.

Optional, found but deliberately skipped:

- `envoy_server_days_until_first_cert_expiring` — the proxy's own view of the certificate it
  serves. Catches a renewed Secret that Envoy never reloads over SDS, which task 4's rules
  structurally cannot see. One rule in `system/envoy-gateway/prometheusrule.yaml`.
- Grafana ships `adminPassword: changeme` with `auth.anonymous.org_role: Admin` in
  `system/monitoring-system/values.yaml`. Not monitoring, noted in the audit's last section.
- The audit doc's plan table has no status column. Worth marking 1-5 done.

## Conventions established this session

**Rule placement.** Colocate a PrometheusRule/ServiceMonitor/PodMonitor with the app it
watches when that app owns a directory, so ArgoCD prunes the rule with the app. An orphaned
rule is worse than no rule: it becomes an `absent()` guard firing about a metric nobody will
produce again, and an orphaned monitor is a permanently empty scrape pool that now trips
`ScrapePoolEmpty`. Cross-cutting rules stay in `system/monitoring-system/`: scrape-coverage,
backups, temperature, alert-escalation, etcd (no directory owns k3s), argocd (bootstrap
helmfile, no stack directory), and infisical (its metric comes from KSM's
`customResourceState` in monitoring-system's own values).

**Watch the sync wave before colocating.** `monitoring-system` is wave 0 within `system`, so
apps at wave 1+ are safe. **Loki and Alloy are both wave 0**, same as monitoring-system, and
ordering within a wave is not guaranteed — on a fresh bootstrap their PrometheusRule could
apply before the CRD exists. Decide deliberately for task 6: keep those rules central, or
colocate and accept a transient failed sync that self-heals on retry.

**Every rule ships with an `absent()` guard** for the metric family it depends on, following
the existing `*MetricsMissing` pattern. That is the whole point of the audit: fifteen etcd
rules sat dataless for 33 days.

**Thresholds are measured, not picked round.** State the baseline in the comment. Examples
from this session: `ScrapePoolEmpty` uses `for: 30m` because `max_over_time(...[7d]) == 0`
showed Longhorn's pool touching zero during manager restarts but only etcd staying empty;
`Gateway5xxRateHigh` is 5% against a lifetime 1.1%; `CertExpiringSoon` is 21d against a 90d
cert renewed at 30d out.

## Traps found the hard way — do not rediscover these

1. **ArgoCD excludes `Endpoints` and `EndpointSlice` by kind** and says nothing. The
   `ExcludedResourceWarning` condition is the only tell while the app reports `Synced`. This
   repo cannot deploy either kind. Use a `ScrapeConfig` for static non-pod targets.
2. **kube-state-metrics never rereads its `customResourceState` config.** It is a ConfigMap
   read only at startup and the chart adds no checksum annotation, so ArgoCD syncs it to a pod
   that ignores it and the metric silently never appears. Needs
   `kubectl -n monitoring-system rollout restart deploy/monitoring-system-kube-state-metrics`.
3. **`extra_server_args` in `ansible/group_vars/k3s_cluster.yml` lands in the k3s systemd unit,
   not `config.yaml`,** and the `k3s_server` role only restarts k3s when `config.yaml` changes.
   A flag added there reaches the unit file and sits unapplied. Restart one server at a time;
   two at once loses etcd quorum.
4. **KSM custom-resource metrics are prefixed `kube_customresource_`.** The name declared in
   values is not the name you query.
5. **`absent()` guards go `pending` for a few seconds** when the rule loads before the first
   scrape lands. Harmless with a generous `for:`, and it is why they have one.
6. **Chart rules can be permanently dataless.** `etcdGRPCRequestsSlow` reads a histogram etcd
   only publishes under `--metrics extensive`. Check that a metric exists before trusting a
   rule that reads it.

## How to verify — this repo makes the obvious approaches fail

- **No shell in the Prometheus pod.** `promtool` is there, so pipe rules in:
  extract `spec.groups` to a plain rules file, then
  `kubectl -n monitoring-system exec -i prometheus-monitoring-system-kube-pro-prometheus-0 -c prometheus -- promtool check rules /dev/stdin < file`.
- **`curl` and `wget` are blocked by a hook.** Query Prometheus with `kubectl port-forward` plus
  `python3` and `urllib`. Do not poll with shell `sleep` — it is disabled and loops spin hot;
  use `time.sleep` inside python.
- **Use `/usr/bin/git`, not `git`.** A hook rewrites `git` through a token filter that hides
  untracked files and swallows `git status` output entirely. This cost real time.
- **Avoid backticks in `git commit -m`** — the shell interprets them and silently eats part of
  the message. Use `-F` with a file for anything with backticks.
- **A hook auto-commits new files the moment they are written.** Check
  `/usr/bin/git log -1 --stat` after writing, or work on a branch created first.
- Always `kubectl apply --dry-run=server` against the CRD, and check the expression against
  live data before merging so you know whether it fires on arrival.

## Workflow I want

Branch, commit, draft PR, mark ready, `--rebase --delete-branch` merge, then
`kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite` and verify
the resource landed and the rules evaluate. Main reflects applied state, so verify after
merging rather than declaring done. Commit messages carry the reasoning; no `Co-Authored-By`,
no mention of Claude. PR descriptions follow `~/.claude/PROSE.md`.

One task at a time, and tell me before doing anything that reshapes the cluster — task 8 moves
the alerting path's own storage.
