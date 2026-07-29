# Post-Outage Follow-Ups — 2026-07-28 DNS Outage

Two pieces of resilience work left over from the 2026-07-28 incident. Both are optional
in the sense that the cluster is healthy without them, and both address the fact that
the outage went unnoticed for roughly an hour rather than the outage itself.

## What Happened (context for both items)

While migrating the last node off the containerd `native` snapshotter, a pre-flight check
found worker-00's Cilium agent had **stopped programming new backends into its BPF load
balancer map**. 23 service frontends pointed at backend IDs that no longer existed
(`backend 235 not found`); worker-01 and worker-02 had zero such entries.

Every affected service's backend pod had been created *after* worker-00's cilium-agent
container restarted — the agent came up at `01:58:56Z`, CoreDNS was recreated at
`01:59:58Z`, 62s later. So this was not one stale leftover; that node had stopped
programming backends entirely.

It hid well. `cilium-dbg service list` renders the agent's *userspace* view and still
showed `10.43.0.10:53 => 10.42.0.46 (active)`. Node Ready, agent ready,
`cilium-dbg status --brief` = OK, all endpoints `ready`, zero not-ready pods. Only the
BPF map disagreed.

Detect it (0 is healthy; always compare across nodes):

```bash
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- \
  cilium-dbg bpf lb list | grep -c 'not found'
```

From inside an affected pod the signature is that *one* ClusterIP fails while others
work — `10.43.0.10:53` gives `no route to host` while `10.43.0.1:443` and CoreDNS's
*pod* IP both succeed. `bash /dev/tcp/<ip>/<port>` works in most pods here.

**Fix:** delete that node's cilium agent pod; it rebuilds the LB maps from k8s state.
Went 23 → 0, DNS restored, no side effects.

**Blast radius:** all ~43 pods on worker-00 lost cluster DNS. All 27 ArgoCD apps sat at
`sync_status=Unknown` with a `ComparisonError` (reads like a git or Cloudflare problem —
it wasn't) and cert-manager went `Degraded`. Also dangling: the Envoy Gateway VIP
`192.168.30.200:80/443`, two Postgres services, Loki, Alertmanager, and four `:443`
admission webhooks.

## Already Done — don't redo

- **Containerd snapshotter.** All three nodes run overlayfs. `ansible/roles/common/tasks/main.yml`
  removes the override with `state: absent`, so it self-heals on any future provision.
  worker-01's containerd store went 128G → 8.9G, disk 138G → 20G.
- **ArgoCD sync alerts** (commit `2aa9323`). ArgoCD was not being scraped at all, so a
  rule on `argocd_app_info` would have silently never fired. Added
  `controller.metrics.enabled` to `bootstrap/values/argocd.yaml`, a ServiceMonitor, and
  three rules (`ArgoCDAppSyncUnknown`, `ArgoCDAppDegraded`, `ArgoCDAppOutOfSync`).
  Note the metrics port is named `http-metrics`, not `metrics`.

---

## Open Item 1 — Dead-Man's Switch (highest leverage, small)

`Watchdog` fires continuously while Prometheus and Alertmanager are healthy, and
`system/monitoring-system/values.yaml` routes it to the `'null'` receiver — throwing that
signal away. So when the alerting path itself breaks, the result is silence rather than a
page.

This is exactly what happened: Prometheus, Alertmanager and Grafana all run on worker-00,
the node whose DNS died. Alertmanager's own service was one of the 23 dangling frontends,
and delivering to an external webhook needs the DNS that was dead. Rules fired with
nowhere to go.

Detection was never the gap — 31 PrometheusRules / 148 alert rules are active, including
`KubePodNotReady` and `TargetDown`. **Delivery** was the gap.

**ntfy cannot do this.** It has no absence detection. This needs an external watcher that
alerts when a ping *stops* arriving — healthchecks.io (free), Dead Man's Snitch, or an
off-cluster Uptime Kuma push monitor. Hosting the watcher on this cluster defeats the
purpose; it must sit outside the blast radius.

The recipe is also parked as a `TODO` in `system/monitoring-system/values.yaml`, so it
shows up in `just todos`. Blocked only on creating the check and getting a URL.

1. Create a check (healthchecks.io: period ~15m, grace ~10m). Copy its ping URL.
2. `echo 'DEADMANSSNITCH_URL=https://hc-ping.com/<uuid>' >> secrets/.secrets`
3. Add a row to `secrets/registry.tsv`:
   ```
   deadmanssnitch-url  monitoring-system  system/monitoring-system/deadmanssnitch-url.yaml  url=DEADMANSSNITCH_URL
   ```
4. `just seal deadmanssnitch-url`
5. Add `- deadmanssnitch-url` to `alertmanager.alertmanagerSpec.secrets` in
   `system/monitoring-system/values.yaml`
6. Replace the `Watchdog` → `'null'` route with:
   ```yaml
   - receiver: 'deadmanssnitch'
     matchers: ['alertname = "Watchdog"']
     group_wait: 0s
     group_interval: 5m
     repeat_interval: 5m
   ```
   and add the receiver:
   ```yaml
   - name: 'deadmanssnitch'
     webhook_configs:
       - url_file: /etc/alertmanager/secrets/deadmanssnitch-url/url
         send_resolved: false
   ```

**Ordering trap:** seal the secret *before* step 5. Adding it to `alertmanagerSpec.secrets`
while the sealed secret doesn't exist leaves Alertmanager unable to mount the volume, and
it will not start.

Alertmanager then posts Watchdog every 5m; ~25m of silence and the external watcher
notifies you. Verify by silencing Watchdog (or scaling Alertmanager to 0) and confirming
the watcher actually complains.

---

## Open Item 2 — CoreDNS HA

CoreDNS runs as a **single replica**, and it is deployed and reconciled by k3s itself
(`/var/lib/rancher/k3s/server/manifests/coredns.yaml`), not by this repo —
`grep -rl coredns` across the repo returns nothing.

Be clear-eyed about the limit here: worker-00's agent had stopped programming *any* new
backend, so a second CoreDNS replica created after the fault would have dangled too. This
reduces blast radius; it does not prevent that failure mode. Don't oversell it.

Prompt to hand to a fresh session:

```
Make CoreDNS highly available in the homelab k3s cluster (repo: /Users/nikgibson/homelab).

Today CoreDNS runs as a SINGLE replica, currently on worker-00. It is deployed and
reconciled by k3s itself (from /var/lib/rancher/k3s/server/manifests/coredns.yaml),
NOT by this repo — `grep -rl coredns` across the repo returns nothing. So the first
real question is mechanism, and it needs verifying before any manifest is written:

  a) HelmChartConfig / a values override k3s will respect
  b) k3s server flag --disable=coredns + manage CoreDNS as a normal app in system/
  c) something else

Option (b) means CoreDNS becomes a repo-managed app and the ansible role in
ansible/roles/ needs the flag. Option (a) is smaller but confirm k3s won't revert
replica count on restart — k3s re-applies its packaged manifests, so test that the
override actually survives a k3s restart rather than assuming.

Target state:
- 2+ replicas
- topologySpreadConstraints or podAntiAffinity so replicas never share a node
- a PodDisruptionBudget so a drain can't take all of them at once
- resources.requests/limits (per repo convention)

Why this matters: on 2026-07-28 a node-local Cilium datapath fault left worker-00's
BPF LB map pointing at backend IDs that no longer existed, so every pod on worker-00
lost cluster DNS for ~1h. Be honest in the writeup about the limit of this fix: the
agent had stopped programming ANY new backend on that node, so a second CoreDNS
replica created after the fault would have dangled too. This reduces blast radius,
it does not prevent that failure mode. Do not oversell it.

Constraints:
- Never use Ingress; Gateway API HTTPRoute only (not relevant here, but repo rule)
- No `sleep` in scripts/manifests — use kubectl wait
- Deploy by merging to main and letting ArgoCD sync; don't kubectl apply managed
  manifests. Bootstrap/helmfile and ansible changes are the exception since they
  sit outside ArgoCD.
- No Co-Authored-By trailers

DNS is the dependency everything else has, so treat rollback as a first-class
concern: state up front how to revert if replicas land wrong or k3s fights the
override, and verify DNS resolution from a pod on EACH node before declaring done
(bash /dev/tcp/10.43.0.10/53 works in most pods here). Also re-check
`cilium-dbg bpf lb list | grep -c 'not found'` is 0 on all three nodes afterward —
changing CoreDNS backends is exactly what exposed the dangling-backend bug.
```
