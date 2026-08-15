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

### 1. VPN tunnel probe — ABANDONED 2026-08-14, after measurement

Step 0 measured gluetun's health server instead of assuming it, and the premise did not
survive. `http://qbittorrent.qbittorrent.svc.cluster.local:9999` returns **200 with an empty
body unconditionally** — including under sub-second polling through a confirmed tunnel outage
(gluetun's own log showed wireguard write errors and a VPN restart at the time). Both branches
this spec anticipated were wrong: the status never goes non-2xx, and there is no body to match
on. A probe against it would assert only that the health server process answers, which it does
whether or not the tunnel exists. Self-heal, separately measured, is ~27-31s.

gluetun's control server is live on `:8000` and does carry the real signal — `/v1/publicip/ip`,
`/v1/vpn/status` — but answers 401, so using it means configuring gluetun auth, opening the
port in `FIREWALL_INPUT_PORTS`, and adding a Service port: changes to a working VPN pod, for a
gap whose whole appeal was that it needed no new components. Not worth it on this evidence.
Revisit if a tunnel outage ever goes unnoticed and costs something.

**What ships instead.** The measurement exposed a live defect in existing config.
`apps/qbittorrent/values.yaml` states that the `health` port exists so Cleanuparr's Queue
Cleaner can gate on "is the tunnel up" rather than "is the internet up", and that a dead
tunnel would otherwise read as a queue full of stalled downloads to be struck. That gate
cannot trip: the endpoint answers 200 during exactly the outage it is supposed to catch. The
comment is the dangerous part — it is the reason someone would configure Cleanuparr to trust
this endpoint. Cleanuparr's connectivity check is UI state and does not appear in this repo,
so the fix here is to correct the claim at the source and record what was measured.

### 2. Immich metrics

Flip `immich.metrics.enabled` to `true` in `apps/immich/values.yaml`. The chart creates the
api and microservices ServiceMonitors. No hand-written ServiceMonitor, no new alert.

**Baseline, measured 2026-08-15T02:52:31Z, before the flip deployed:**
`prometheus_tsdb_head_series` = **423452**. The after-measurement compares against this
number, and Prometheus retains 10d, so it can also be re-derived from a range query if the
comparison slips.

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
