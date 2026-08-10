# Post-Outage Follow-Ups — 2026-07-28 DNS Outage

Resilience work left over from the 2026-07-28 incident. The original two items addressed
the fact that the outage went unnoticed for roughly an hour rather than the outage itself.
Both are done: the dead-man's switch (2026-07-29) and CoreDNS HA (2026-07-29). Item 4
(worker-00 time sync) is done as of 2026-07-30 — root cause was a mass `kill -TERM` sweep
during the snapshotter migration, and chrony was one of four services it killed.

Item 5 (worker-00 out of inotify instances) was found *and* closed on 2026-07-30 — it was
live when found: PID 1 itself could not allocate an inotify fd.

Item 6 (a correctly-delivered warning nobody noticed) is done as of 2026-07-30: a warning
still firing after 2h now escalates to critical and re-notifies hourly.

**Open: Item 3 only.** Both it and Item 6 were about the alerting pipeline's last hop, and
fixing one did not help the other:

- **Item 3** — ntfy returned 4xx on a since-replaced Alertmanager pod. Not currently
  recurring; see "The warning alert nobody saw was *not* Item 3" for the measurement that
  de-escalated it. *The channel refused the message.*
- **Item 6** (done) — a `severity: warning` fired for 38h, was delivered successfully, and
  nobody noticed, because the ntfy route carries `repeat_interval: 12h`. Raised out of the
  Item 4 investigation and **the only failure that investigation actually proved.**
  *The message arrived and did not register.*

Every item after the first two was found *while verifying* an earlier one. Item 5 came out
of clearing two apparently-cosmetic failed units left over from Item 4.

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

**Workaround at the time:** delete that node's cilium agent pod; it rebuilds the LB maps
from k8s state. Went 23 → 0, DNS restored, no side effects.

**Root cause (found 2026-07-30): two cilium-agent processes on one node.** k3s carries
`KillMode=process`, so `systemctl stop k3s` leaves the containerd-shims — and the agent
inside them — running. systemd logs it plainly:

```
Jul 29 01:57:43 worker-00 systemd[1]: Stopping k3s.service...
Jul 29 01:57:43 worker-00 systemd[1]: k3s.service: Unit process 1836 (containerd-shim) remains running after unit stopped.
```

Normally k3s reattaches to that shim on restart and nothing is duplicated. Here the
snapshotter migration meant it built a *new* agent container instead, at `01:58:57` — with
no shutdown logged for the old one, and both of its ports already taken by it:

```
Failed to launch hubble ... listen tcp :4244: bind: address already in use
Failed to serve cilium-health API ... listen tcp 192.168.30.129:4240: bind: address already in use
```

Nothing else on the node binds those two ports, so that is direct proof two agents were
live at once. They then wrote the same shared BPF LB maps from independent in-memory
backend-ID allocators, each deleting backends the other had just written — so every service
whose backend pod appeared after the split pointed at a backend ID that no longer existed.
CoreDNS was recreated 62s in, which is why it surfaced as a DNS outage. (The map divergence
itself was not captured live; the split brain is proven, this last step is inferred from it.)

**Fix:** `ansible/roles/common/tasks/main.yml` — the k3s `ExecStartPre` drop-in now kills any
surviving agent before k3s starts, making "exactly one agent per node" an invariant. The
previous socket guard, which made a restart against a healthy agent a no-op, was precisely
what allowed the duplicate, so it is gone.

**Not the cause — ruled out with evidence:** leaked local endpoints from CNI-ADD timeouts.
On 2026-07-30 worker-00 held 11 leaked endpoints and **0** dangling backends simultaneously,
and correctly programmed a brand-new backend (`loki-0`) 50 minutes after an agent restart.
Leaks are real but are not this.

### Open: prevention is deferred, detection is in place

Current state is **detected, not prevented**. `KillMode=process` is untouched, so the
duplicate can still occur; `CiliumAgentDuplicate` now catches it in ~1–2 min instead of
days. Recovery is still manual (delete that node's agent pod).

Deferred by decision on 2026-07-30, ahead of the physical move: the trigger needs a k3s
restart **without** a reboot *plus* a pod-sandbox rebuild. It has happened once, caused by
the snapshotter migration that is now complete, and a power-cycle cannot trigger it (the
kernel restarts, so no process survives to collide). So the move itself is not exposed.

**Findings for whoever picks this up — these were proven on worker-02, don't re-derive:**

- The obvious fix, a Cilium `extraInitContainers` reap, is **viable in principle**: the init
  containers *do* re-run on this path. Verified against the incident — they ran 01:58:50–56,
  immediately before the failing agent at 01:58:57. `extraInitContainers` also renders
  *last*, right before `cilium-agent`.
- But `nsenter --pid=/hostproc/1/ns/pid` **cannot work from a container**:
  `reassociate to namespace 'ns/pid' failed: Invalid argument`. The kernel forbids `setns()`
  into an *ancestor* PID namespace, and the host's is an ancestor of the container's. No
  capability changes this. `--mount` works fine; only `--pid` is impossible.
- It works only with pod-level `hostPID: true` (then drop `--pid` entirely — the container
  is already in the host PID namespace). Confirmed: host PID 1 = `systemd`, host
  `/usr/bin/pkill` present, `pgrep -x cilium-agent` sees the real agent, 260 host processes
  visible. The chart exposes **no** `hostPID` key, so this needs a helmfile
  `strategicMergePatches` on the DaemonSet — which then has to survive every Renovate bump.
- Pod-level `securityContext.appArmorProfile.type: Unconfined` is **required**; without it
  even opening `/hostproc/1/ns/mnt` fails with `Permission denied` under Ubuntu's default
  AppArmor profile. The agent pod already sets this, but a standalone test pod must too.
- **Trap:** if `nsenter` fails, the shell after it never runs — so an `exit 0` *inside* that
  shell does not protect you. The init container exits non-zero, the agent never starts, and
  the node loses CNI. Any reap here must be wrapped so the **outer** process always exits 0
  (`/bin/sh -c 'nsenter ... || echo WARNING; exit 0'`).
- Don't borrow the chart's `hostproc` volume: it only exists
  `{{- if or .Values.cgroup.autoMount.enabled .Values.sysctlfix.enabled }}`, so the pod
  becomes unschedulable — no CNI on that node — if either is ever disabled. Declare a own
  volume via `extraVolumes` instead.

The other two shapes considered: change k3s `KillMode` (biggest hammer — every k3s restart
then bounces every pod on the node), or a host-side systemd guard that acts only when
`pgrep -xc cilium-agent` is genuinely >1 (native PID access, no chart patch, but needs a
timer to catch the ~70s window after k3s start, making it a periodic watchdog).

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

**The first attempt did not fire, and the reason is worth remembering:** the check was
still on healthchecks.io's *defaults* — period 1 day, grace 1 hour — so a 35-minute outage
was well inside tolerance. Creating the check is not configuring it. Period 15m / grace 10m
has to be set explicitly, and until it is, the switch silently tolerates a day of downtime.

With 15m/10m set, a second 35-minute silence tripped it correctly: last ping 19:39Z, down
event at 20:03Z (= 15m period + 10m grace, to the minute), ntfy notification delivered, and
the check recovered on its own when the silence expired. **This switch has been seen to
fire.**

Note *which* ntfy delivered that page: healthchecks.io's own ntfy integration, not
Alertmanager → ntfy. That is the point — the notification hop must not run through the
cluster it is watching. Alertmanager's only job here is the outbound ping.

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

## Done — CoreDNS HA (2026-07-29)

Three CoreDNS pods now back `kube-dns` (10.43.0.10), one per node, with a
PodDisruptionBudget (`maxUnavailable: 1`) over every `k8s-app=kube-dns` pod. Verified
live: DNS resolves from a pod on all three nodes, and
`cilium-dbg bpf lb list | grep -c 'not found'` is 0 on all three agents after the
endpoint change.

**What was actually missing was two things, not four.** k3s's packaged manifest already
ships a `kubernetes.io/hostname` topologySpreadConstraint (`maxSkew: 1`,
`DoNotSchedule`) and resource requests/limits. It has **no `replicas` field at all** —
it relies on the Kubernetes default of 1. So the real gaps were replicas and a PDB.

**Option (a) is structurally impossible.** CoreDNS is a `k3s.cattle.io/v1 Addon`, not a
HelmChart — `kubectl get helmcharts -A` returns nothing, and the Deployment's
`objectset.rio.cattle.io/owner-gvk` reads `Kind=Addon`. HelmChartConfig only overrides
HelmChart CRs, so there is nothing for it to attach to. Ruled out on evidence.

**What was built is neither (a) nor (b).** A second Deployment, `coredns-ha`
(`system/coredns/coredns-ha.yaml`), 2 replicas. Its pods carry `k8s-app=kube-dns`, so
the existing Service adopts them as extra endpoints with no Service change; the spread
constraint selects that same label, so it counts k3s's pod too and no two CoreDNS pods
share a node. It mounts k3s's own `coredns` ConfigMap, so the Corefile and the
`NodeHosts` file k3s keeps current are not duplicated. k3s's replica is never touched,
so there was no DNS gap at any point and the dead-man's switch was never paused.

Deployed by a standalone Application (`bootstrap/root/templates/coredns-ha.yaml`)
because the stack ApplicationSets are git *file* generators globbing
`<stack>/*/app.yaml` and hardcode `destination.namespace` to the directory basename —
these objects have no chart and must live in `kube-system`. Needs `just bootstrap-root`
once; the manifests themselves auto-sync from `main`.

The official `coredns/coredns` chart was evaluated and rejected *for the additive
shape*. It can be bent into it — `k8sAppLabelOverride: kube-dns`,
`deployment.skipConfig: true`, `fullnameOverride: coredns` (the only way to point the
config volume at k3s's ConfigMap), `deployment.name: coredns-ha` (to dodge the
Deployment name collision that override causes), `zoneFiles: [{filename: NodeHosts}]`
to smuggle a second key into the volume — but two of those values exist purely as
tricks, and the chart has no `namespaceOverride` (every template hardcodes
`.Release.Namespace`), so it needs the same custom Application anyway. **If CoreDNS is
ever taken over outright (`--disable=coredns`), the chart is the right answer** and all
of those workarounds disappear.

**Restart survival — tested, not assumed.** Two independent checks:
- The addon's objectset contains exactly `deployment/coredns`, `configmap/coredns`,
  `serviceaccount/coredns`. Wrangler prunes by `objectset.rio.cattle.io/hash`, a label
  `coredns-ha` does not carry, so an addon re-apply cannot see it.
- `systemctl restart k3s` on worker-02: Deployment, PDB and pods all survived with 0
  restarts, DNS held on all three nodes, addon checksum unchanged.

- `systemctl restart k3s` on **worker-00** — the `k3s` lease holder (addon apply leader),
  etcd leader, API endpoint and Tailscale subnet router, so the restart that actually
  re-runs the addon reconcile. Fingerprinted before and after: `coredns-ha` Deployment and
  the PDB came back with **identical UIDs and `generation: 1`**, and all three pods kept
  their original UIDs with 0 restarts — so they were neither pruned nor
  deleted-and-resurrected by ArgoCD selfHeal. Addon checksum unchanged, lease reacquired
  by worker-00, all 28 apps Synced/Healthy, Tailscale pods survived. DNS resolved from a
  freshly created pod on every node afterward, including worker-00, so the known
  post-restart stale-Cilium-CNI sandbox failure did not occur; 0 dangling backends on all
  three agents.

  Tip for repeating this: the serving cert covers every server, so
  `kubectl --server=https://192.168.30.136:6443` gives an out-of-band view while
  worker-00's own API is down.

One honesty note on scope: the checksum was unchanged across the restart, so the
controller may have short-circuited rather than performing a full wrangler apply. What is
proven is that a lease-holder restart does not disturb `coredns-ha`; the label-based
objectset argument above is what rules out pruning in general.

**The honest limit.** This reduces blast radius. It does not prevent the 2026-07-28
failure mode. worker-00's agent had stopped programming *any* new backend, so a CoreDNS
replica created after that fault would have dangled too, while pods that already held a
working entry kept resolving. What helps there is noticing the agent is wedged
(`bpf lb list | grep 'not found'`), not having more replicas.

**Two gaps left open deliberately:**
1. The `coredns-ha` image is pinned (`rancher/mirrored-coredns-coredns:1.14.4`) and
   Renovate does not track it — there is no `app.yaml`. Bump it when k3s bumps. A
   Renovate rule would push CoreDNS *ahead* of k3s and manufacture skew rather than
   prevent it.
2. ~~Delete the `coredns-ha` Application and the extra replicas vanish silently.~~
   **Closed 2026-07-29** by `system/monitoring-system/prometheusrule-coredns.yaml`:
   `CoreDNSRedundancyLost` (`sum(up{job="coredns"}) < 2`, for 15m) plus
   `CoreDNSScrapeTargetsMissing` (`absent(...)`, for 30m) so a disabled exporter cannot
   silence the first one. No new ServiceMonitor was needed — the stack's existing coredns
   Service selects `k8s-app=kube-dns`, so it already scrapes both deployments.
   Both are `severity: warning`, which the Alertmanager route sends to ntfy —
   **so delivery is subject to Open Item 3**; ntfy was returning 4xx as of this date.
   Verified loaded in Prometheus and not firing at 3 instances; expression shape checked
   by inverting the threshold (`< 4` returns 3, so the comparison does emit a series when
   breached). Not yet trip-tested by actually scaling to 1 replica.

**Side effect: `just bootstrap` was already broken before this work.** The first
`bootstrap-root` failed with an SSA field-manager conflict. helm is now **v4.2.3**,
which server-side-applies by default (v3 was client-side), and
`argocd-applicationset-controller` held `.spec.generators` on the `platform` and `apps`
ApplicationSets. Pre-existing: any `root` upgrade would have hit it. The ApplicationSets
themselves were never modified — the apply was rejected, not partially written. Fixed by
reclaiming ownership once:

```
helmfile sync -f bootstrap/helmfile.yaml -l name=root --args "--force-conflicts"
```

Use `sync`, not `apply` — with `apply`, `--args` leaks into the `helm diff` plugin,
which rejects the flag. `helm(Apply)` now owns `.spec.generators` on all three, so this
should not recur and no Justfile change was made. Do **not** attempt to fix it with
`kubectl apply --server-side` of the rendered chart: that strips
`meta.helm.sh/release-name` and `app.kubernetes.io/managed-by: Helm`, breaking helm's
ownership of the objects outright (confirmed via `kubectl diff` before running it).

**Verification recipe.** A pinned `busybox:1.37` pod per node (`nodeName` pinned,
`tolerations: [{operator: Exists}]`) checking resolution three ways — via
`/etc/resolv.conf`, against `10.43.0.10` directly, and forwarding to `hc-ping.com`
(the dead-man's switch dependency) — plus `cilium-dbg bpf lb list | grep -c 'not found'`
per agent. Sanity-check the checker by pointing `CLUSTER_DNS` at a bogus IP and
confirming it reports FAILED; `kubectl run --attach` falls back to log streaming and
still propagates the container exit code.

---

## Open Item 3 — ntfy.sh Is Silently Rejecting Notifications

**Deferred deliberately on 2026-07-30, not overlooked.** The proposed fix — a non-ntfy
receiver for `AlertmanagerFailedToSendAlerts` so "delivery is broken" does not travel through
the broken channel — needs a credential for a second channel (Discord webhook, Telegram bot,
or SMTP). None exists in `secrets/registry.tsv` and there is no `smtp`/`smarthost` config in
the repo. Decision was to leave it open rather than add a channel just to have one: alert
escalation (Item 6) now makes `AlertmanagerFailedToSendAlerts` loud on its own — it fired for
13.3h in the 7d before that shipped, which would now escalate to critical and re-notify
hourly. What remains genuinely uncovered is *total* ntfy failure with an otherwise healthy
pipeline: the escalated critical routes through ntfy too, so it is lost with everything else,
and the dead-man's switch does **not** catch this — the snitch pings `hc-ping.com` through a
separate receiver, so it keeps reporting healthy while ntfy alone refuses. That residual gap
is the whole of Item 3, and it is accepted for now.

Found 2026-07-29 while verifying the dead-man's switch.
`alertmanager_notifications_failed_total{integration="webhook",reason="clientError"}` had
reached **184** on the then-running Alertmanager pod, and was actively incrementing by one
every 5 minutes from 17:22Z to 18:04Z. `clientError` means a 4xx *response* — the request
reached `https://ntfy.sh` and was refused, so this is not a DNS or connectivity fault.

Be careful reading that number — it is **not** 184 lost alerts. The counting unit is one
*notification*, i.e. one POST carrying one **alert group**, which may hold many alerts. And
a failed notification is never written to the notification log, so the identical group is
re-attempted on the next `group_interval` tick. `+1 every 5 minutes` is therefore the
signature of *one stuck group retrying*, not 184 distinct notifications: at 5m ticks that is
~288/day, so 184 is plausibly a single group failing for ~15 hours.

Metric semantics worth knowing before drawing conclusions from any of these (verified
against the help text on Alertmanager 0.32.2):

- `alertmanager_notifications_total` is *attempted* notifications, not successful ones.
  Successes are `total - failed`.
- `alertmanager_notification_requests_total` counts individual HTTP attempts, so
  `requests > notifications` means in-pipeline retries are happening.
- `reason="clientError"` is specifically a **4xx response**. The webhook retrier treats 2xx
  as success and 5xx as retryable, so a 4xx is abandoned immediately. Connection, DNS and
  timeout faults land in `other` / `contextDeadlineExceeded` instead — which is how you tell
  "ntfy refused this" apart from "ntfy was unreachable".
- `alertmanager_notifications_suppressed_total{reason="silence"}` is the direct way to
  confirm a silence took effect. Prefer it over inferring suppression from gaps in
  `notifications_total`, which is shared across every webhook receiver.

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

---

## Done — Alert Escalation (Item 6, closed 2026-07-30)

**A warning still firing after 2h becomes a critical that re-notifies every hour until it
is fixed or silenced. Nothing else got louder.** That sentence is the whole change; the
distinction it turns on is "a persisting condition becomes impossible to ignore" versus
"more alerts", and the second one would have made this worse.

Shipped in `7b0f05d`, two halves that only work together:

- `system/monitoring-system/prometheusrule-alert-escalation.yaml` —
  `WarningAlertFiringTooLong` fires when any `severity: warning` has been firing >2h, at
  `severity: critical`. One rule for the whole class instead of reclassifying 148 alerts
  one at a time. It matches `warning` and emits `critical`, so it cannot match itself.
- `system/monitoring-system/values.yaml` — a `severity = "critical"` child route above the
  existing `warning|critical` route, with `repeat_interval: 1h`.

**Why the route change is not optional.** Escalation alone adds exactly one more message to
the same 12h stream. ntfy's generic webhook renders no priority, so a lone critical looks
identical to a warning in the notification list — which is the thing that failed. The route
makes the escalated critical keep arriving.

**Why it does not raise volume.** The new route matches `severity = "critical"` only;
warnings are untouched, and nothing was firing at critical when it shipped. Measured over
the previous 7d of Prometheus data, exactly two alerts would have escalated:
`NodeClockNotSynchronising` (28.2h) and `AlertmanagerFailedToSendAlerts` (13.3h) — both
real, both previously ignored, zero false positives. If escalation ever does get noisy the
knob is the `> 7200` in the rule and the `repeat_interval: 1h` on the route, not the
warning cadence.

**Deliberate consequences, decided rather than inherited:**

- The original warning keeps notifying too. The existing inhibit rule is
  `severity = critical` → `severity =~ warning|info` with `equal: ['namespace','alertname']`,
  and an escalation necessarily has a different `alertname`, so it cannot suppress its own
  source. Wanted: the pair reads as "this is still broken", not as a replacement.
- `label_replace` copies the source name into `escalated_alert`, because Prometheus
  overwrites `alertname` with the rule name and the notification would otherwise not say
  which alert escalated.
- The critical route overrides `group_by` to `['alertname','escalated_alert','namespace']`.
  Node-level alerts carry no `namespace` label at all, so under the top-level
  `group_by: ['namespace']` every namespace-less alert collapses into one group sharing a
  single `repeat_interval` timer — part of why the clock alert was so quiet.
- A silence on the source alert does **not** suppress the escalation: silences are an
  Alertmanager concept and `ALERTS` still reports a silenced alert as firing. Silence
  `escalated_alert="<source>"` as well. This is stated in the alert's own description.

**Verification.** Pre-merge, against the rendered config: `amtool check-config` SUCCESS, and
route order proven first-match-wins empirically by renaming the critical route's receiver in
a throwaway copy (`critical -> null`, `warning -> ntfy`) rather than trusting the docs. The
expression was run against live Prometheus including the inverted-threshold check
(`> 99999999` returns empty, so the comparison genuinely gates).

Post-merge: Alertmanager reloaded **in place at 18:28:23Z — no pod restart** (still 2/2, 24h
uptime, `alertmanager_config_last_reload_successful = 1`), the generated route tree is
`Watchdog → deadmanssnitch` / `critical → ntfy` / `warning|critical → ntfy` in that order,
and Watchdog's `0s`/`1m`/`5m` intervals are byte-for-byte unchanged. One webhook
notification landed in the following 10m with zero failures; since Watchdog was the only
firing alert, that notification *is* the snitch, which is the cleanest attribution that
counter allows.

Then an actual trip test, because "the rule is inactive and the config is valid" proves
nothing about a rule that has never fired. A temporary `PrometheusRule` (not in the repo,
`kubectl`-applied, deleted after) fired a synthetic source alert and a copy of the escalation
rule at a 90s threshold, using invented severities `ztestwarn`/`ztestesc` — confirmed via
`amtool config routes test` to match no route matcher, so the whole test routed to `'null'`
and generated **zero notifications**. It tripped on schedule and produced:

```
labels: {alertname: ZTestEscalation, alertstate: firing,
         escalated_alert: ZTestSyntheticWarning, severity: ztestesc}
summary: ZTestSyntheticWarning has been firing for over 2h and is still unresolved
```

That is what validated the annotation Go template end to end — including that
`{{ $labels.alertname }}` would have been useless here and the `escalated_alert` copy was
necessary. It also caught a stray `` `  . `` in the rendered text where `instance` and
`namespace` were both absent, fixed by collapsing the conditional onto one line (YAML `>-`
folding was injecting the spaces) and re-rendered against the same live test rule.

**What this does not fix.** Not Item 3. An escalated critical still routes through ntfy, so
if ntfy starts refusing again the escalation is lost with everything else. They are
independent: Item 3 is "the channel refused the message", this was "the message arrived and
did not register."

The unblocked slice of Item 3 would be a **non-ntfy** receiver for
`AlertmanagerFailedToSendAlerts`, so "delivery is broken" does not travel through the broken
channel. **Blocked on a credential, not on a decision:** `secrets/registry.tsv` has no SMTP
row and no `smtp`/`smarthost` config exists anywhere in the repo, so there is nothing to
point `email_configs` at yet. A second ntfy topic is not a substitute — same shared
dependency, no benefit. Note the 7d measurement above shows `AlertmanagerFailedToSendAlerts`
itself firing for 13.3h, so escalation now at least makes Item 3 *loud* when it recurs,
through the very channel it is complaining about.

<details>
<summary>Original Item 6 write-up (kept for the reasoning trail)</summary>

Raised 2026-07-30 out of Item 4. **This is the only failure the Item 4 investigation
actually proved**, and it is not a delivery bug — which is what makes it easy to lose.

`NodeClockNotSynchronising` fired for 38 hours. Prometheus evaluated it correctly.
Alertmanager routed it correctly. ntfy accepted every POST (0 failures over the pod's
22.9h; see the Item 4 write-up). Nobody noticed. Every layer did its job and the outcome was
still a node with no clock for a day and a half.

The mechanism is cadence, not plumbing. The generated route is:

```yaml
- receiver: ntfy
  matchers: [severity =~ "warning|critical"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h        # <-- this
```

At `repeat_interval: 12h`, ~30 hours of continuous firing yields **two or three**
notifications total, interleaved with everything else 148 alert rules emit. A
`severity: warning` that never escalates is indistinguishable from noise.

Note this also governs both CoreDNS redundancy alerts (`CoreDNSRedundancyLost`,
`CoreDNSScrapeTargetsMissing`) — both are `severity: warning`, so a silent loss of DNS
redundancy would surface exactly as weakly as the clock did.

**Deliberately not changed yet.** Which alerts are worth interrupting a person for is a
judgment call, not a bug fix, and the wrong answer here makes fatigue *worse*. Options,
roughly in increasing order of intrusiveness:

- **Escalate on duration.** A rule that fires when a `warning` has been firing for >N hours,
  at `severity: critical`. Catches the whole class rather than tuning alerts one at a time,
  and reuses the existing critical route. Probably the best value.
- **Shorten `repeat_interval` for node-level warnings only.** A child route matching
  `alertname =~ "NodeClock.*|CoreDNS.*"` with something like 2h. Narrow, cheap, but has to
  be maintained per-alert.
- **Reclassify.** `NodeClockNotSynchronising` on an etcd control-plane node is arguably
  critical, not a warning. Smallest change, fixes only this alert.

Do **not** address this by raising alert volume globally — that is the direct cause of the
fatigue being described.

Worth pairing with Item 3: both are about the alerting pipeline's last hop, and a fix for
one does not help the other. Item 3 is "the channel refused the message"; Item 6 is "the
message arrived and did not register."

</details>

---

## Done — worker-00 Time Sync (Item 4, closed 2026-07-30)

**Root cause: collateral damage from a mass `kill -TERM` sweep, not anything systemic.**

At `02:14:38Z` on 2026-07-29, during the containerd snapshotter migration on worker-00,
a sweep issued `sudo kill -TERM <pid>` against **the entire process table**. The giveaway
is in the sudo log: the first kill of the batch is

```
COMMAND=/usr/bin/kill -TERM PID
```

— the literal string `PID`, i.e. the *header row* of `ps -eo pid,etimes,comm`. So the
filter matched every line including the header. An earlier batch 45 seconds before
(`02:13:53Z`) had killed only 16 high PIDs, so the filter worked that time; on the retry
it degenerated to "everything". The shape of a numeric awk comparison against an empty
threshold variable (`$2 > ""` → string compare → always true).

The sweep was hunting an orphaned process holding `:9100` (node-exporter's port) left over
after `systemctl stop k3s` + `rm -rf /var/lib/rancher/k3s/agent/containerd` — the session
polled `ss -lptn sport = :9100` three times and `ps -o etimes= -p 917397` five times
around it.

**This will not recur on worker-01 or worker-02 on its own.** It was ad-hoc interactive
work, not automation: `grep -rniE 'kill -TERM|etimes|pkill|xargs.*kill'` across the repo
finds nothing. The 16-minute gap after the Cilium agent recovered at `01:58:56Z` was
coincidence — same maintenance session, not an incident-response reflex.

**chrony was not the only casualty.** The sweep SIGTERM'd four services; none carries
`Restart=`, so all four stayed dead silently:

| Unit | State found 2026-07-30 | Impact |
|------|------------------------|--------|
| `chrony` | `inactive` | the `NodeClockNotSynchronising` alert |
| `thermald` | `inactive` | no thermal management on a ProDesk Mini for 38h |
| `fail2ban` | `failed` | no SSH brute-force protection |
| `wpa_supplicant` | `inactive` | none — wired-only node, left alone |

`chrony` had `Restart=no`, which is Debian's packaged default. A stray SIGTERM is a
**clean** exit (`status=0/SUCCESS`), so `Restart=on-failure` would not have covered it
either — only `Restart=always` does.

**Fixed** in `ansible/roles/common/tasks/main.yml` (ships via `just provision`, not ArgoCD):

- `chrony` and `thermald` added to base packages (explicit rather than "whatever the
  Ubuntu installer left").
- `chrony`, `thermald`, `fail2ban` ensured `enabled` + `started`.
- A `chrony.service.d/override.conf` drop-in with `Restart=always` / `RestartSec=5s`.
  An explicit `systemctl stop chrony` still wins — systemd never restarts a unit that was
  deliberately stopped.

Verified: `just provision` converged all three nodes (`failed=0`), and all three now report
`NTP service: active`, `System clock synchronized: yes`, `Restart=always`, with chrony,
thermald and fail2ban active.

**One gap left open deliberately:** only `chrony` got `Restart=always`. `thermald` and
`fail2ban` are installed, enabled and started, but a second stray SIGTERM would leave them
dead again exactly as before — `just provision` is the only thing that would bring them
back. Rationale: clock skew on an etcd control-plane node is the failure that hurts, and
the drop-in is per-unit. Add the same override for either if it ever goes missing again;
the task in `ansible/roles/common/tasks/main.yml` is a copy-paste with the name changed.

**Clock adjustment was a slew, not a step.** Re-measured immediately before starting the
service: `0.052917s` (up from `0.050767s` 23 minutes earlier). `chrony.conf` carries
`makestep 1 3`, so it only steps above 1 second — 53ms slews. Confirmed after the fact:
no step entry in the journal, and offset settled to `+116µs` against
`ntp-nts-3.ps5.canonical.com`. Alertmanager was on worker-02 at the time, so the
dead-man's switch was never near the adjusted node. No silence was needed and none was
created.

**Trip-tested, not assumed.** Reproduced the exact 2026-07-29 failure on worker-00 —
`kill -TERM $MainPID`, producing the same `chronyd exiting` /
`Deactivated successfully` pair — and systemd brought it back in 5s:

```
17:19:01 chronyd exiting
17:19:01 chrony.service: Deactivated successfully.
17:19:06 chrony.service: Scheduled restart job, restart counter is at 1.
17:19:06 Started chrony.service
17:19:11 Selected source 185.125.190.123
```

`NRestarts=1`, back in sync. Note `systemctl show -p MainPID` can read stale immediately
after the kill; trust `NRestarts` and the journal, not a PID diff.

### The warning alert nobody saw was *not* Item 3

Checked directly, because the answer decides whether Item 3 is urgent. **It is not the
cause — ntfy delivered these fine.** Over the current Alertmanager pod's 22.9h life:

- `alertmanager_notifications_failed_total` increase = **0** in every
  integration/reason pair.
- 213 webhook notifications attempted, 213 HTTP requests — so not even an in-pipeline retry.
- Zero `notify`/`error` lines in 24h of Alertmanager logs.

`NodeClockNotSynchronising` was firing the whole time (3581 firing samples over 38h of
Prometheus uptime). The generated route sends `severity =~ "warning|critical"` to `ntfy`
with **`repeat_interval: 12h`**, so ~30 hours of firing produced only two or three
notifications, successfully delivered and never looked at. **That is alert fatigue, not
lost delivery.**

So Item 3 stays where it was in priority. Two honest caveats: the current Alertmanager pod
postdates Item 3's 184 `clientError`s, so the counter reset (which is Item 3's own point —
a restart launders the symptom); and `integration="webhook"` is shared by `ntfy` and
`deadmanssnitch`, so a clean total cannot be attributed to `ntfy` alone. What it *can*
rule out is any 4xx at all in that window, since a failure of either receiver would land
in the same counter.

Also cleared while here: worker-02's `mnt-storage.mount` was in `failed` state; the
provision run remounted it (`11T, 24% used`).

**This finding is what Open Item 6 exists for.** Detection worked and delivery worked; the
notification still failed to reach anyone. That is a routing/cadence problem, not a
pipeline problem, and it is the one thing this incident actually proved.

<details>
<summary>Original Item 4 write-up (superseded — kept for the evidence trail)</summary>

Found 2026-07-30 while verifying the CoreDNS HA work. `NodeClockNotSynchronising` is
firing for `192.168.30.129:9100` (worker-00) and has been since roughly 02:25Z on
2026-07-29. Not caused by the CoreDNS work — chrony stopped ~20h before that restart.

Already established — don't re-derive:

- chrony `4.8-2ubuntu1` is installed and `enabled` on worker-00, but `inactive (dead)`.
  worker-01 and worker-02 both report `NTP=yes` / `NTPSynchronized=yes` with chrony active.
- It exited **cleanly**: `chronyd exiting`, `Deactivated successfully`,
  `Main PID: 1271 (code=exited, status=0/SUCCESS)` at **2026-07-29 02:14:38 UTC**, after
  running since Jul 11 20:49. A clean exit means something asked it to stop; it did not
  crash or OOM. Nothing tried to restart it.
- **No dpkg activity at that time** (`grep "2026-07-29 02:" /var/log/dpkg.log` is empty),
  so a package upgrade is ruled out as the trigger. `unattended-upgrades` *is* enabled and
  its dpkg log was last written Jul 29 06:40 — after the stop, so not the cause.
- `systemd-timesyncd` is `not-found` on all three nodes; chrony is the only time source.
- **Ansible does not manage time sync at all** — `grep -rniE 'chrony|ntp|timesync' ansible/`
  returns nothing. Node provisioning never ensured it, so this was only ever "whatever the
  Ubuntu installer left running."
- Drift measured **without touching the clock** via `sudo chronyd -Q -t 8`:
  `System clock wrong by 0.050767 seconds` as of 2026-07-30 16:29Z. At that size chrony
  slews rather than steps, so starting it is safe — but **re-measure before acting**, drift
  grows. Do not compare `date` across nodes over ssh; that measures ssh latency, not skew.

Two questions, in order:

1. **Why did chrony cleanly exit?** 02:14:38Z on Jul 29 is ~16 minutes after the Cilium
   agent recovered at 01:58:56Z in the 2026-07-28 incident. That may be coincidence, but if
   something stops chrony during incidents, worker-01 and worker-02 will do it eventually
   too — and a fix that only restarts the service papers over that. Check the full journal
   around that window for whatever issued the stop (`journalctl --since '2026-07-29 02:00'
   --until '2026-07-29 02:20'`), not just the chrony unit.
2. **Make time sync durable and provisioned.** The likely home is
   `ansible/roles/common/tasks/main.yml`: ensure chrony installed, enabled *and* started on
   all three. That is an ansible change, so it deploys via `just provision`, not ArgoCD.

Worth checking while you are here: a `severity: warning` alert fired for ~38 hours and
nobody noticed. That is either alert fatigue or direct evidence that Open Item 3 (ntfy
returning 4xx) is losing real notifications. If it's the latter, Item 3 is more urgent than
it currently reads. Query `ALERTS{alertname="NodeClockNotSynchronising"}` history and
compare against `alertmanager_notifications_failed_total`.

Safety notes specific to this work:

- worker-00 is simultaneously the kubeconfig API endpoint, the etcd leader and the
  Tailscale subnet router. The serving cert covers every server, so
  `kubectl --server=https://192.168.30.136:6443` gives an out-of-band view if you disturb
  it.
- **Never step the clock on an etcd control-plane node without measuring first.** A large
  backwards step can expire etcd leases and upset TLS validity windows. Slew if at all
  possible; `chronyd -Q` measures without adjusting.
- Rollback for starting the service is just `sudo systemctl stop chrony`. The part that is
  not trivially reversible is the clock adjustment itself, which is why you measure first.
- The healthchecks.io dead-man's switch is live (period 15m, grace 10m, fires ~25m after
  pings stop). Clock work should not touch DNS, but check which node Alertmanager is on
  before adjusting that node's clock. If you need a silence, always pass `--duration` so it
  self-expires, and never leave the healthchecks.io check paused.
- Do not trust ntfy to confirm anything during this work — see Open Item 3. Verify with
  `timedatectl`, `chronyc tracking`, and Prometheus directly.

</details>

---

## Done — worker-00 Out of inotify Instances (Item 5, found and closed 2026-07-30)

Found while clearing the last two `failed` units left by the Item 4 kill sweep. It was a
**live** fault at the time, not historical.

`fs.inotify.max_user_instances` is **128** — the kernel default, untuned — on every node.
Root on worker-00 is at that ceiling right now and cannot allocate a single new instance:

```
$ sudo python3 -c '...libc.inotify_init1(0)...'
exhausted after 0 new instances: errno=24 (Too many open files)
```

Even PID 1 is failing:

```
Jul 30 17:43:43 worker-00 systemd[1]: Failed to allocate inotify fd: Too many open files
Jul 30 17:43:43 worker-00 systemd[1]: systemd-ask-password-wall.path: Failed to enter waiting state: Too many open files
```

13 occurrences in the last 30 days of journal, first at **Jul 29 06:08:47**
(`systemd-networkd-wait-online[951088]: Could not create manager: Too many open files`),
most recent today. `systemctl reset-failed` + `start` on the two
`systemd-ask-password-*.path` units **fails to clear them** — the units cannot enter their
waiting state without an inotify fd. They are benign in themselves (headless node, nothing
prompts for a password); they are useful as a canary.

### It is not a leak — it is pod density against an untuned ceiling

Investigated before touching the sysctl, because a real leak would exhaust 1024 just as
happily as 128. It is not one. The limit is charged **per-UID**, and `uid=0` is the one
that is full:

| Node | `uid=0` inotify fds | running pods | `containerd-shim` fds / procs | `k3s-server` fds |
|------|--------------------|--------------|-------------------------------|------------------|
| worker-00 | **129 / 128** | 37 | 72 / 37 | 44 |
| worker-02 | 79 / 128 | 14 | 32 / 14 | 34 |

**Exactly one `containerd-shim` process per running pod, each holding 2 inotify fds.**
37 shims × 2 = 74, plus k3s-server's 44, plus ~11 from `systemd`/`tailscaled`/`agetty`/etc
= 129. The marginal cost is ~2.2 fds per pod, and worker-00 carries 37 of the cluster's 68
running pods (54%).

Three independent reasons this is not a leak:

1. **No idle instances.** Zero processes hold an inotify fd with zero watches — across 60
   holders on worker-00 and 28 on worker-02. Every instance is in active use.
2. **Age is anti-correlated.** worker-00's `k3s-server` was 2,025s old holding 44 fds;
   worker-02's was 71,349s old — **35× older** — holding 34. A leak grows with uptime.
   This shrinks with it.
3. **The count is predicted by pod count.** `79 + (37 − 14) × 2.2 ≈ 129`.

So the ceiling of 128 is simply too low for worker-00's density. **worker-00 has zero
headroom right now** — the next pod scheduled there cannot get a shim watch, and neither
can any daemon that needs one. worker-02 has room for roughly 22 more pods before it hits
the same wall.

A methodology note for anyone repeating this: do **not** dedupe inotify fds by
`stat().st_ino`. Every anonymous inode shares a single inode in the `anon_inodefs`
superblock, so that collapses the entire audit to one row. Count fds per UID from
`/proc/*/fd/*` where `readlink` is `anon_inode:inotify`, and read watch counts from
`inotify wd:` lines in the matching `/proc/<pid>/fdinfo/<fd>`.
The audit script is at `.claude/scripts/inotify-audit.py`.

**Why this matters more than two cosmetic failed units.** This is the exact shape of the
2026-07-28 fault: a process that runs, reports healthy, and silently stops noticing
changes. worker-00's Cilium agent stopped programming BPF backends while
`cilium-dbg status --brief` still said `OK`. An agent that cannot establish an inotify
watch fails precisely that way.

**But do not call it the cause of that incident.** The first journal occurrence
(Jul 29 06:08) *postdates* the agent wedge (Jul 29 01:58), so on the evidence available it
does not predate the failure it resembles. Journal retention may simply not reach further
back. Unproven, worth proving.

**Fix is standard Kubernetes node tuning**, and it belongs in
`ansible/roles/common/tasks/main.yml` next to the Item 4 work:

```yaml
- name: Raise inotify limits for Kubernetes workloads
  ansible.posix.sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-inotify.conf
    reload: true
  loop:
    - { name: fs.inotify.max_user_instances, value: "1024" }
    - { name: fs.inotify.max_user_watches, value: "524288" }
  become: true
```

**Applied 2026-07-30** via `just provision` (`changed` on all three nodes, `failed=0`).
Took effect on reload — no reboot, no k3s restart, no pod disruption.

`max_user_watches` was *not* near its limit (288 used of 123,584); raised for symmetry
because it costs nothing.

1024 instances gives worker-00 room for roughly 400 pods at the measured ~2.2 fds/pod,
against a kubelet default cap of 110 pods per node. That is deliberate headroom, not a
guess: the audit rules out a leak, so the only growth term is pod count, and pod count is
already capped well below the new ceiling.

Verified after applying:

- The `inotify_init1` probe that previously reported `exhausted after 0 new instances`
  now creates 200 without error.
- Both `systemd-ask-password-*.path` units cleared with `reset-failed` + `start` and
  **stayed** cleared — they had been un-clearable while the limit was hit, which is what
  makes them a useful canary.
- **Zero failed units on all three nodes** (worker-02's `mnt-storage.mount` also cleared).
- `/etc/sysctl.d/99-inotify.conf` written, so it survives reboot.
- Cluster undisturbed: no not-ready pods, 28/28 ArgoCD apps Synced/Healthy, and
  `cilium-dbg bpf lb list | grep -c 'not found'` = 0 on all three agents.
