# Apps monitoring gaps — design

Date: 2026-08-14
Status: approved, not implemented

## Problem

An audit of `apps/` found that generic pod health and reachability are well covered, but
three specific "the pod is Running and the app is broken" signals are missing. Of the 17
app directories, exactly one (`nextcloud`) carries an app-level `PrometheusRule`, and three
stateful apps appear on no dashboard beyond their rows in the blackbox probe dashboard.

### What already covers apps, and must not be rebuilt

- `system/monitoring-system/values.yaml` sets no `defaultRules` key, so kube-prometheus-stack's
  defaults are live for every namespace: `KubePodCrashLooping`, `KubePodNotReady`,
  `KubeDeploymentReplicasMismatch`, `KubePersistentVolumeFillingUp`.
- `system/blackbox-exporter/probes.yaml` probes all 13 user-facing hostnames end to end —
  DNS, gateway, HTTPRoute, served certificate, app — and alerts `EndpointDown` at 5m.
- `system/monitoring-system/dashboard-media-stack.yaml` covers 13 media namespaces.
- `dashboard-backups.yaml`, `dashboard-cronjobs.yaml`, and `prometheusrule-backups.yaml`
  cover every app backup path.
- `platform/cloudnative-pg/dashboard.yaml` covers the Postgres behind nextcloud, vaultwarden
  and immich.

### The three gaps in scope

1. **The gluetun tunnel is unmonitored.** Its health server already listens on
   `0.0.0.0:9999` and is already a named port on the `qbittorrent` Service, because
   Cleanuparr's Queue Cleaner gates on it. Nothing in Prometheus reads it. A dead Mullvad
   tunnel stalls every torrent at once while every pod stays Running and every probe stays
   green.
2. **Immich exports no metrics.** `apps/immich/values.yaml` has `immich.metrics.enabled: false`.
   Chart 0.13.1 creates the ServiceMonitors itself when that is true — verified with
   `helm show values oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.1`.
3. **Nextcloud, vaultwarden and immich are on no dashboard.** The media dashboard's `$media`
   constant lists 13 namespaces and deliberately excludes these three.

### Out of scope, by decision

Exporter sidecars for the arrs and qBittorrent (`exportarr`, `qbittorrent-exporter`) and a
Jellyfin metrics plugin were considered and rejected for now: 6–7 new containers on a
three-node cluster where worker-00 is already the density hotspot. Revisit when an arr
incident actually goes undetected. Per-app `PrometheusRule`s for nextcloud/vaultwarden/immich
beyond what exists are also out of scope — the default rules cover pod health, blackbox
covers reachability, and writing immich alerts before a single immich metric has been scraped
is guessing at failure modes.

## Design

### 1. VPN tunnel probe

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
- New `VPNTunnelDown`: `probe_success{probe_class="vpn"} == 0`, `for: 5m`, `severity: warning`.

Warning, not critical: Mullvad server rotation flaps the tunnel, and the consequence is
stalled downloads, not a user-facing outage. 5m is five consecutive failures at the file's
60s interval, matching the reasoning already documented for `EndpointDown`.

### 2. Immich metrics

Flip `immich.metrics.enabled` to `true` in `apps/immich/values.yaml`. The chart creates the
api and microservices ServiceMonitors. No hand-written ServiceMonitor, no new alert.

### 3. Dashboard for the non-media stateful apps

One new `system/monitoring-system/dashboard-apps.yaml` — a ConfigMap in `monitoring-system`
labelled `grafana_dashboard: "1"`, following `dashboard-media-stack.yaml` exactly, including
its documented caveat that no `FOLDER_ANNOTATION` is set on the sidecar so a `grafana_folder`
annotation would be silently ignored.

One dashboard, not three: nextcloud, vaultwarden and immich share a shape — user-facing,
stateful, CNPG behind them — and three near-identical dashboards would be three places to
edit. A hidden `$apps` constant holds the namespace list, the way `$media` does, so the list
lives in one place and every panel derives from it.

Panels: replicas unavailable; container restarts 24h; restarts by app; CPU by app; memory by
app; log lines/sec by app; error+warn lines/sec by app; recent errors. These are the
media-stack panels re-scoped, which is the point — they come from signals that already exist
(cAdvisor, kube-state-metrics, Loki) and need nothing added to any app.

**No Postgres panels.** `platform/cloudnative-pg/dashboard.yaml` already covers all three
databases and duplicating it would create two panels to keep in sync.

**Storage panels need care, or must be omitted.** The same NFS trap the media dashboard
documents applies here, and worse, because the storage is mixed:

| Claim | Backing |
|---|---|
| `nextcloud-data` | NFS (static PV, `storageClassName: ""`) |
| `immich-library` | NFS (static PV, `storageClassName: ""`) |
| `vaultwarden-data` | `nfs` |
| `nextcloud-html` | `local-path` |
| `vaultwarden-data-local` | `local-path` |

`kubelet_volume_stats_*` on the NFS-backed claims reports the whole 12TB filesystem, so
those three would each show an identical, meaningless number. A used-% panel is therefore
restricted to the `local-path` claims, and a panel comment states why the others are absent.
Bulk NFS capacity is already on the media dashboard's library panels.

Immich job-queue and ML panels are deliberately deferred to a follow-up: they can only be
authored honestly against metric names observed after step 2 is live.

## Sequencing

Steps 1 and 3 are independent. Step 3's optional immich-specific panels depend on step 2, so
step 2 lands before step 3 regardless.

Each step is its own commit, and nothing merges to `main` until it is confirmed live in the
cluster — `main` reflects applied state.

## Verification

- **Probe:** the `vpn` target appears Up in Prometheus targets before the alert is written.
  Trip-test `VPNTunnelDown` by temporarily inverting its expression under an invented
  severity, so no route matches and nothing notifies; `amtool` runs in the Alertmanager pod,
  not the Prometheus pod, which has no shell.
- **`EndpointDown` narrowing:** confirm in the Prometheus expression browser that
  `probe_success{probe_class!="vpn"}` still returns all 13 pre-existing targets. This is the
  step most likely to silently delete alerting coverage.
- **Immich:** both chart-created ServiceMonitors show Up targets before step 3 begins.
- **Dashboard:** JSON parsed with `json.load` before commit; after sync, every panel renders
  a value rather than "No data".

## Risks

- Narrowing `EndpointDown` is a change to a working critical alert covering 13 endpoints, to
  accommodate one new target. If the label selector is wrong, coverage disappears silently.
  This is why it has its own verification step rather than being folded into the probe's.
- `HEALTH_SERVER_ADDRESS` and the `health` Service port exist for Cleanuparr. Prometheus
  becomes a second consumer of an endpoint another app depends on; the probe is read-only at
  60s, so the risk is negligible, but the coupling should be noted in the values comment so
  neither consumer is removed on the assumption it is the only one.
