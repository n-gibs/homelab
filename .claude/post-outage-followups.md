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

Still unexercised: restarting **worker-00**, which holds the `k3s` lease (the addon
apply leader) and is also the API endpoint and Tailscale subnet router. A leadership
change forces a full addon resync — the only path that would actually run a prune. The
structural proof above says it is safe; it has not been proven.

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
