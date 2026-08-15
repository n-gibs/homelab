# Apps monitoring gaps — design

Date: 2026-08-14
Status: approved, not implemented

## Problem

An audit of `apps/` found generic pod health and reachability well covered, and two
"the pod is Running and the app is broken" signals missing. Of the 17 app directories,
exactly one (`nextcloud`) carries an app-level `PrometheusRule` — but that asymmetry is
mostly fine, and the audit's job was to separate the parts of it that aren't.

### What already covers apps, and must not be rebuilt

- `system/monitoring-system/values.yaml` sets no `defaultRules` key, so kube-prometheus-stack's
  defaults are live for every namespace: `KubePodCrashLooping`, `KubePodNotReady`,
  `KubeDeploymentReplicasMismatch`, `KubePersistentVolumeFillingUp`.
- `system/blackbox-exporter/probes.yaml` probes all 17 user-facing hostnames end to end —
  DNS, gateway, HTTPRoute, served certificate, app — and alerts `EndpointDown` at 5m.
- `system/monitoring-system/dashboard-media-stack.yaml` covers 13 media namespaces.
- `dashboard-backups.yaml`, `dashboard-cronjobs.yaml`, and `prometheusrule-backups.yaml`
  cover every app backup path.
- `platform/cloudnative-pg/dashboard.yaml` covers the Postgres behind nextcloud, vaultwarden
  and immich.

### The two gaps in scope

1. **The gluetun tunnel is unmonitored.** Its health server already listens on
   `0.0.0.0:9999` and is already a named port on the `qbittorrent` Service, because
   Cleanuparr's Queue Cleaner gates on it. Nothing in Prometheus reads it. A dead Mullvad
   tunnel stalls every torrent at once while every pod stays Running and every probe stays
   green.
2. **Immich exports no metrics.** `apps/immich/values.yaml` has `immich.metrics.enabled: false`.
   Chart 0.13.1 creates the ServiceMonitors itself when that is true — verified with
   `helm show values oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.1`.

### Out of scope, by decision

**Exporter sidecars** for the arrs and qBittorrent (`exportarr`, `qbittorrent-exporter`) and
a Jellyfin metrics plugin: 6–7 new containers on a three-node cluster where worker-00 is
already the density hotspot. Revisit when an arr incident actually goes undetected.

**A dashboard for nextcloud / vaultwarden / immich.** This was in an earlier draft and was
cut on its own merits. Postgres panels belong to `platform/cloudnative-pg/dashboard.yaml`
already. Storage panels don't survive contact with the actual volumes: `nextcloud-data`,
`immich-library` and `vaultwarden-data` are all NFS-backed, so `kubelet_volume_stats_*`
reports the whole 12TB filesystem for each — the same trap `dashboard-media-stack.yaml`
documents — and of the two `local-path` claims left, `vaultwarden-data-local` is the dormant
rollback volume from the Postgres migration (`apps/vaultwarden/values.yaml:78` mounts
`vaultwarden-data`, not it), leaving `nextcloud-html` as the single real series. What
remained after those cuts was restarts, CPU, memory and log rate — which kube-prometheus-stack's
shipped per-namespace dashboards already provide. Build it when the want for it has come up
twice, not before.

**Per-app `PrometheusRule`s** for nextcloud / vaultwarden / immich beyond what exists.
Default rules cover pod health, blackbox covers reachability, and writing immich alerts
before a single immich metric has been scraped is guessing at failure modes.

## Design

### 1. VPN tunnel probe

#### Step 0 — measure gluetun's failure behaviour first (blocking)

Measured directly against the qbittorrent Service on 2026-08-14, breaking the tunnel with
`kubectl exec ... -c gluetun -- ip link set tun0 down` and polling continuously through three
separate break/recover cycles:

- **Healthy:** `200 OK`, `Content-Length: 0` — body is always empty.
- **Unhealthy (tunnel down, gluetun mid-restart):** also `200 OK` with an empty body. In all
  three trials, sub-second-interval polling never once observed a non-2xx status or any body
  content, including during the window gluetun's own logs confirm the tunnel was down and it
  was actively restarting the VPN process.
- **Self-heal timing:** gluetun's healthcheck doesn't react instantly — wireguard write errors
  start immediately, but the periodic health loop only detects the failure and restarts the
  VPN ~27–31s later (observed in two trials), reconnecting within ~1–2s of that. The `:9999`
  health server is not gated on this internal state at all; it reported 200 continuously
  before, during, and after the outage.

This breaks both branches the design assumed. Non-2xx-when-unhealthy is false (confirmed
above), and the fallback — a body-matching module keyed on the healthy body string — has
nothing to key on, since the body is identical (empty) in both states. A regex module built
from an empty healthy-body string is a no-op match: it would pass unconditionally and add no
detection value over `http_2xx`.

**Decisions:**
- **Module:** stays `http_2xx`. Do not add a `http_2xx_body` module — there is no body
  content that differs between healthy and unhealthy to match against. This probe is
  effectively a liveness check on the health server process, not a discriminator of tunnel
  state; it will not catch the failure mode tested here (a transient break gluetun self-heals
  within ~30s). It would only fire for an outage gluetun has already given up retrying —
  crash-looped, credentials revoked, provider down — which is a narrower guarantee than the
  original design assumed, but is the only one this endpoint can honestly provide.
- **`for:` duration:** `5m`. Observed self-heal (27–31s) is well under the 5m floor set by
  the qBittorrent Deployment being single-replica, so the floor governs regardless of
  self-heal speed.

#### The probe

Add a third `Probe` to `system/blackbox-exporter/probes.yaml`, named `vpn`, module `http_2xx`,
targeting `http://qbittorrent.qbittorrent.svc.cluster.local:9999`.

This is a deliberate exception to that file's stated "public hostnames, not Services" rule.
That rule exists so probes test the whole browser path rather than re-testing pod readiness.
Here there is no route to gluetun and no browser path to test: the fact under measurement is
whether the tunnel is up, which is not a fact any other signal in the cluster carries. The
comment in the file must say this, or the next reader will "fix" it.

**The existing `EndpointDown` alert must be narrowed at the same time.** It is
`probe_success == 0` with no target selector, so a new probe target inherits a critical alert
by default. Give the new target a `probe_class: vpn` label via
`targets.staticConfig.labels`, then:

- `EndpointDown` becomes `probe_success{probe_class!="vpn"} == 0`. Existing targets carry no
  `probe_class` label at all, and PromQL's `!=` matches the empty label, so their behaviour
  is unchanged.
- New `VPNTunnelDown`: `probe_success{probe_class="vpn"} == 0`, `for:` per step 0,
  `severity: warning`.

Warning, not critical: Mullvad server rotation flaps the tunnel, and the consequence is
stalled downloads, not a user-facing outage. Note also what this alert is and isn't —
Cleanuparr already *gates* on this endpoint, so nothing here changes cluster behaviour. The
value is being told, rather than finding out from a queue that stopped moving.

### 2. Immich metrics

Flip `immich.metrics.enabled` to `true` in `apps/immich/values.yaml`. The chart creates the
api and microservices ServiceMonitors. No hand-written ServiceMonitor, no new alert.

**Measure the cardinality cost.** Prometheus holds 10.1GB of blocks in a 20Gi Longhorn volume
at 10d retention — headroom, but not unbounded, and immich's telemetry includes per-endpoint
histograms. Record `prometheus_tsdb_head_series` immediately before the flip and again an
hour after. If the increase is a meaningful fraction of the existing head, scope immich's
telemetry down rather than absorbing it silently; the volume expands in place if the answer
is that the data is worth the space.

## Sequencing

The two items are independent and each is its own commit. Nothing merges to `main` until it
is confirmed live in the cluster — `main` reflects applied state.

## Verification

- **Step 0 measurement** is recorded in the commit message, not just acted on. The next
  person to touch the module choice needs the status codes.
- **Probe:** the `vpn` target appears Up in Prometheus targets before the alert is written.
  Trip-test `VPNTunnelDown` by temporarily inverting its expression under an invented
  severity, so no route matches and nothing notifies; `amtool` runs in the Alertmanager pod,
  not the Prometheus pod, which has no shell.
- **`EndpointDown` narrowing:** confirm in the Prometheus expression browser that
  `probe_success{probe_class!="vpn"}` still returns all 17 pre-existing targets. This is the
  step most likely to silently delete alerting coverage.
- **Immich:** both chart-created ServiceMonitors show Up targets, and the head-series delta
  is recorded.

## Risks

- Narrowing `EndpointDown` is a change to a working critical alert covering 17 endpoints, to
  accommodate one new target. If the label selector is wrong, coverage disappears silently.
  This is why it has its own verification step rather than being folded into the probe's.
- The qBittorrent pod is a single replica, so the probe fails during every restart and image
  pull. `for:` has to be long enough to swallow a normal restart, which is the same knob
  step 0 is tuning from the other direction — pick the value that satisfies both, and if
  they conflict, favour the longer one and accept slower detection.
- `HEALTH_SERVER_ADDRESS` and the `health` Service port exist for Cleanuparr. Prometheus
  becomes a second consumer of an endpoint another app depends on; the probe is read-only at
  60s, so the risk is negligible, but the coupling should be noted in the values comment so
  neither consumer is removed on the assumption it is the only one.
