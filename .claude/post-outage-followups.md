# Post-Outage Follow-Ups — 2026-07-28 DNS Outage

Resilience work left over from the 2026-07-28 incident. Both items address the fact that
the outage went unnoticed for roughly an hour rather than the outage itself. Item 1 is
done (2026-07-29); Item 2 is still open.

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

## Done — Dead-Man's Switch (2026-07-29)

Detection was never the gap — 31 PrometheusRules / 148 alert rules are active, including
`KubePodNotReady` and `TargetDown`. **Delivery** was the gap: `Watchdog` fires continuously
while the alerting pipeline is healthy, and it was routed to the `'null'` receiver, so a
broken alerting path produced silence rather than a page. On 2026-07-28 Prometheus,
Alertmanager and Grafana all ran on worker-00 — the node whose DNS died — and Alertmanager's
own service was one of the 23 dangling frontends, so rules fired with nowhere to go.

ntfy cannot cover this; it has no absence detection. The watcher has to sit outside the
blast radius, so it is healthchecks.io (free): Alertmanager POSTs Watchdog outbound to
`https://hc-ping.com/<uuid>` every 5m, and the check alerts on the *absence* of those
pings. Check config: period 15m, grace 10m, so it tolerates two missed pings.

Shipped in two commits, deliberately:

- `86d6463` — sealed secret `deadmanssnitch-url` + `secrets/registry.tsv` row
- `efa2a9e` — `alertmanagerSpec.secrets` entry, Watchdog → `deadmanssnitch` receiver
  (`url_file`, `send_resolved: false`, `group_wait: 0s`, `group_interval`/`repeat_interval`
  5m), stale TODO removed. The `'null'` receiver stays — the top-level route still uses it
  as the default.

**Why two commits:** if the Secret does not exist when Alertmanager tries to mount it, the
pod cannot start and you lose *all* alerting. Seal first, confirm the SealedSecret has
decrypted into a real Secret in `monitoring-system`, then merge the values change.

Verified: Secret present and decrypted before the values change; Alertmanager 2/2 Ready
with 0 restarts after it (pod rescheduled worker-00 → worker-02); secret mounted at
`/etc/alertmanager/secrets/deadmanssnitch-url/url`; `deadmanssnitch` receiver present in
the generated config; `alertmanager_notifications_total{integration="webhook"}` increments
with `alertmanager_notifications_failed_total{...}` 0 in every category — a wrong UUID
would surface as `clientError`.

Trip-tested by silencing Watchdog for 30m via
`amtool silence add 'alertname=Watchdog' --duration=30m` (self-expiring, so it restores
itself even if the session dies). The cluster side behaved: healthchecks.io's own ping log
showed one ping at 18:06Z, a 35-minute gap, then pings resuming at 18:41Z the moment the
silence expired.

**It did not fire, and the reason is worth remembering:** the check was still on
healthchecks.io's *defaults* — period 1 day, grace 1 hour — so a 35-minute outage was well
inside tolerance. Creating the check is not configuring it. Period 15m / grace 10m has to
be set explicitly, and until it is, the switch silently tolerates a day of downtime.

Two cadence facts that make those numbers work:

- `group_interval` must be well under `repeat_interval`. With both at 5m the measured
  cadence was one ping per **10m**, because the dispatcher only re-evaluates a group on
  `group_interval` ticks and at the 5m tick the 5m repeat has not strictly elapsed.
  `group_interval: 1m` restores the intended 5m ping.
- At 5m pings, 15m period / 10m grace tolerates two missed pings, goes late at 15m, and
  alerts at 25m.

Also confirm the check has notification integrations attached (ntfy + email). A check that
goes down and notifies nobody is indistinguishable from a healthy one.

**Do not "harden" this by pinning an IP for hc-ping.com.** If cluster DNS breaks,
Alertmanager cannot resolve it, the ping stops, and the switch fires — that is the entire
point. Pinning an IP would break TLS SNI and delete the signal.

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

---

## Open Item 3 — ntfy.sh Is Silently Rejecting Notifications

Found 2026-07-29 while verifying the dead-man's switch.
`alertmanager_notifications_failed_total{integration="webhook",reason="clientError"}` had
reached **184** on the then-running Alertmanager pod, and was actively incrementing by one
every 5 minutes from 17:22Z to 18:04Z. `clientError` means a 4xx *response* — the request
reached `https://ntfy.sh` and was refused, so this is not a DNS or connectivity fault.

That is ~184 alert notifications Alertmanager believes it failed to deliver.

**Two reasons it stayed invisible.** `AlertmanagerFailedToSendAlerts` did fire, but the
counter is per-pod-lifetime, so the alert self-resolved when the pod restarted at 18:06Z
without anything being fixed — a restart launders the symptom. And the alert's own delivery
path is ntfy, the thing that is broken, so when it matters most it cannot reach you. The
dead-man's switch does not close this: it only proves Alertmanager → hc-ping works.

Note `alertmanager_notifications_total{integration="webhook"}` is shared by the `ntfy` and
`deadmanssnitch` receivers, so it cannot attribute a success or failure to either. To tell
them apart, use healthchecks.io's own ping log for the snitch and Alertmanager's logs for
ntfy.

Diagnose in this order — the status code decides everything, and nothing is currently
logged because the failures stopped:

1. Catch the next occurrence: `kubectl -n monitoring-system logs
   alertmanager-monitoring-system-kube-pro-alertmanager-0 -c alertmanager | grep -i notify`
   — Alertmanager logs the response body on webhook failure.
2. Or reproduce deliberately: POST an Alertmanager-shaped JSON body (~2KB) to the URL in
   `secrets/.secrets` (`NTFY_WEBHOOK_URL`) and read the status directly.

Candidate causes, most to least likely:

- **429 — ntfy.sh free-tier rate limiting.** Fits the shape best: a steady one-per-5-minute
  failure is a group retrying at `group_interval` while being throttled. 148 alert rules on
  a shared public instance is a lot of publishes.
- **413/400 — payload.** Alertmanager posts its own JSON schema (~2KB observed); ntfy may
  reject the size or content.
- **401/403 — auth.** If the URL carries a token that has expired or the topic was claimed.

Mitigation depends on the cause, but the structural problem is that every alert path
except the snitch terminates at one free third-party service. Worth considering:

- An SMTP/email receiver for `AlertmanagerFailedToSendAlerts` specifically, so the alert
  about broken delivery does not depend on the broken channel. A second ntfy *topic* does
  not help — ntfy.sh itself is the shared dependency.
- Self-hosting ntfy removes the rate limit but moves the notifier *inside* the blast
  radius, which is the mistake that caused the 2026-07-28 blackout. If you do it, keep an
  off-cluster channel for monitoring's own alerts.

Do not "fix" this by raising `repeat_interval` to reduce the failure count. That hides the
counter without delivering the notifications.
