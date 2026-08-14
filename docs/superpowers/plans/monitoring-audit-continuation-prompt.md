# Continuation prompt — monitoring audit follow-ups

Copy everything below the line into a fresh session.

---

Finish the three items left open by the monitoring audit in this repo. The audit is
`docs/audits/2026-08-14-monitoring-audit.md`; all ten of its tasks shipped on 2026-08-14
and are verified live. These three were deliberately deferred, not forgotten, and each is
recorded in that doc's Outcome section.

Do one at a time. Task 1 is date-gated and irreversible — check the gate before touching
anything.

## Current state

51 rule groups, 297 rules, 68 scrape targets with none down, ~503k head series. Watchdog is
the only firing alert. Prometheus runs on a `longhorn` PVC, 20Gi, two replicas on worker-02
and worker-01.

## Task 1 — prune the retained NFS PV from the TSDB migration

**Gated to 2026-08-28.** Do not run this before that date; if the current date is earlier,
say so and move to task 2.

`pvc-9dbb49b1-67bc-4e50-9cde-31a9db461985` is `Released` with `Retain`, still holding
10.3GB at
`worker-01:/mnt/storage/monitoring-system/prometheus-monitoring-system-kube-pro-prometheus-db-prometheus-monitoring-system-kube-pro-prometheus-0`.
It is the rollback for the NFS-to-longhorn move (PR #56), and deleting it is irreversible.

Before deleting, confirm the new volume has actually earned it:

- `prometheus_tsdb_wal_corruptions_total` is still 0
- the longhorn volume is `attached`, robustness `healthy`, both replicas `running`
- `time() - prometheus_tsdb_lowest_timestamp_seconds` is at or near the full 10d retention
  window, i.e. the TSDB has re-accumulated a complete window on longhorn rather than
  carrying only the copied blocks
- no `EndpointDown`, `CiliumUnreachableNodes` or storage alerts have fired in the interim

The subtlety: because the reclaim policy is `Retain`, `kubectl delete pv` releases the
Kubernetes object but leaves the directory on worker-01 untouched. Reclaiming the 10.3GB
means removing that directory on the node as well. Decide deliberately whether to do both
or only the PV, and say which you did.

Follow the repo's existing pattern for gated destructive cleanups — see the Vaultwarden
`data-pvc` and Longhorn task 16 precedents.

## Task 2 — extend blackbox probes to the remaining twelve hostnames

`system/blackbox-exporter/probes.yaml` covers five: vault, grafana, jellyfin, nextcloud,
immich. Not covered:

    argocd  bazarr  cleanuparr  home  infisical  lidarr
    longhorn  navidrome  prowlarr  qbittorrent  radarr  sonarr

Adding a target is one line each, but **measure each endpoint before adding it**. The five
already covered all return 200 through the probe, two of them only because the stock
`http_2xx` module follows redirects (jellyfin 302s to `/web/`, nextcloud to `/login`).
Several of the twelve are likely to behave differently — anything that answers 401 or 403
unauthenticated will make `probe_success` 0 and trip `EndpointDown` immediately, per
hostname, at `severity: critical`.

Measure first by querying the exporter directly rather than by adding targets and seeing
what breaks:

    kubectl -n blackbox-exporter port-forward svc/blackbox-exporter 19115:9115
    # then, from python: http://127.0.0.1:19115/probe?module=http_2xx&target=https://<host>

For anything that does not return 2xx, decide between a second module with
`valid_status_codes: [200, 401, 403]` (proves the gateway and TLS work without asserting
the app authenticates you) and leaving it unprobed. State the reasoning in the values
comment. Do not widen the existing `http_2xx` module — the five current targets should keep
asserting a real 200.

One thing already known: an unknown subdomain returns **404 from the gateway**, not a DNS
failure, because the wildcard record resolves everything to 192.168.30.200. So a hostname
dropped from an HTTPRoute surfaces as a 404 and trips `EndpointDown` rather than looking
like a DNS problem.

## Task 3 — reconcile the hand-added UFW rules into ansible

`ansible/roles/common/tasks/main.yml` is not a complete description of the node firewalls.
Live on all three nodes but absent from the role:

| Rule | Likely purpose — verify, do not assume |
|---|---|
| `2379:2381/tcp` | etcd client and peer. This is why cross-node etcd worked while `:4240` did not |
| `5001/tcp` | unidentified |
| `51820/udp`, `51821/udp` | WireGuard / Tailscale |
| `Anywhere from 10.42.0.0/16` | blanket allow, pod CIDR |
| `Anywhere from 10.43.0.0/16` | blanket allow, service CIDR |

Read the live state first — `ansible -i ansible/inventory.yml all -m command -a 'ufw status
verbose' --become --vault-password-file .vault_pass` — since it may have drifted again.

Two decisions to make explicitly:

1. **Which rules to codify.** `5001` needs identifying before it is written into the role
   as if it were intentional. If nothing uses it, propose removing it rather than blessing
   it.
2. **Whether the blanket cluster-CIDR allows should stay.** They make most of the specific
   rules redundant, and they are a meaningfully weaker posture than the port-by-port list
   the role otherwise implements. Keeping them is defensible; keeping them *by accident*
   is not. Whichever way it goes, the reasoning belongs in a comment.

The trap: **the `ufw` module only adds.** Deleting a rule from the role does not remove it
from the nodes — that needs `delete: true` on a matching rule. So a change here has two
halves, and the second one is easy to forget and impossible to notice afterwards.

Verify with `--check --diff` before applying, then `just provision-common`. Applying is a
node-level change across all three servers; adding allows is additive and safe, removing
them is not, so confirm before any deletion.

## Conventions to keep

**Rule placement.** Colocate a PrometheusRule/ServiceMonitor/PodMonitor with the app it
watches when that app owns a directory, so ArgoCD prunes the rule with the app. An orphaned
rule becomes an `absent()` guard firing about a metric nobody will produce again.
Cross-cutting rules stay in `system/monitoring-system/`: scrape-coverage, backups,
temperature, alert-escalation, etcd, argocd, infisical, and cilium (helmfile-managed,
no stack directory).

**Every rule ships with an `absent()` guard** for the metric family it depends on,
following the `*MetricsMissing` pattern. That is the whole point of the audit.

**Thresholds are measured, not picked round.** State the baseline in the comment.

**`/add-app` step 4** encodes the placement convention and asks "how would I know this app
is broken?" before an app ships. Keep it in step with any change here.

## Traps — do not rediscover these

1. **A storage class change is a silent no-op.** `volumeClaimTemplates` are immutable, so
   the operator recreates the StatefulSet and the recreated one adopts the PVC already
   existing under that name. CR, StatefulSet and ArgoCD all report the new class while the
   PVC keeps the old one.
2. **Prometheus cannot be stopped with `kubectl`.** Scaling the operator to 0 is reverted by
   `selfHeal`; removing `automated` from the Application is reverted by the `system`
   ApplicationSet that owns it. The only lever the controllers agree with is
   `prometheusSpec.replicas: 0` committed to main.
3. **UFW default-deny hides itself well.** Cross-node TCP to an unlisted port times out
   while ICMP to the same address and pod-to-pod traffic both pass, so it reads as a
   selective network fault. Prometheus scrapes a *node* IP, which Cilium masquerades to the
   scraping node's own address — the blanket pod-CIDR allow never matches it.
4. **ArgoCD excludes Endpoints and EndpointSlice by kind** and says nothing beyond an
   `ExcludedResourceWarning` condition while reporting Synced. Use a ScrapeConfig for static
   non-pod targets.
5. **kube-state-metrics never rereads its `customResourceState` ConfigMap.** It is read once
   at startup with no checksum annotation, so ArgoCD syncs it to a pod that ignores it.
   Needs `kubectl -n monitoring-system rollout restart deploy/monitoring-system-kube-state-metrics`.
6. **`extra_server_args` in `ansible/group_vars/k3s_cluster.yml` lands in the systemd unit,
   not `config.yaml`,** and the `k3s_server` role only restarts k3s when `config.yaml`
   changes. Restart one server at a time; two at once loses etcd quorum.
7. **Chart rules can be permanently dataless.** Check a metric exists before trusting a rule
   that reads it. Cilium 1.20 exports `loki_prometheus_rule_group_*`-style names that differ
   from upstream docs; take metric names off the live endpoint.
8. **Copy Jobs need real memory.** A 10GB `cp` was OOMKilled at a 256Mi limit because page
   cache counts against the cgroup. 2Gi completed in 2m20s.

## How to verify — the obvious approaches fail here

- **No shell in the Prometheus pod.** `promtool` is there, so pipe rules in: extract
  `spec.groups` to a plain rules file, then
  `kubectl -n monitoring-system exec -i prometheus-monitoring-system-kube-pro-prometheus-0 -c prometheus -- promtool check rules /dev/stdin < file`.
- **`curl` and `wget` are blocked by a hook.** Query Prometheus with `kubectl port-forward`
  plus `python3` and `urllib`. Never poll with shell `sleep` — it is disabled and loops spin
  hot; use `time.sleep` inside python.
- **Use `/usr/bin/git`, not `git`.** A hook rewrites git through a token filter that hides
  untracked files and swallows `git status` output.
- **Avoid backticks in `git commit -m`** — the shell eats part of the message. Use `-F` with
  a file.
- **A hook auto-commits new files the moment they are written.** Create the branch first.
- **Always `kubectl apply --dry-run=server`** against the CRD, and check the expression
  against live data before merging so you know whether it fires on arrival. A new namespace
  does not exist yet at dry-run time; validate with the namespace rewritten to an existing
  one.

## Workflow

Branch, commit, draft PR, mark ready, `--rebase --delete-branch` merge, then
`kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite` and
verify the resource landed and the rules evaluate. Main reflects applied state, so verify
after merging rather than declaring done. A new app directory needs an ApplicationSet
refresh, not an Application refresh, and takes ~3 minutes to appear.

Commit messages carry the reasoning; no `Co-Authored-By`, no mention of Claude. PR
descriptions follow `~/.claude/PROSE.md`.

Tell me before anything that reshapes the cluster or the nodes. Task 1 deletes data
irreversibly and task 3 edits the firewall on all three servers.
