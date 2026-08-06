# Cleanuparr Deployment — Design

**Date:** 2026-08-06
**Status:** Approved, not yet implemented

## Motivation

On 2026-08-06 two releases carrying `.scr` executables (Sugar 2024 S02E08, Silo S03E06) reached
the Sonarr queue from the LimeTorrents indexer — three identically-sized 1.21 GB payloads across
unrelated shows, a deliberate repackaging pattern. Each required manual identification,
blocklisting in Sonarr, and removal from qBittorrent. LimeTorrents was removed from Prowlarr,
but that fix is reactive and indexer-specific: the next unmoderated source repeats the problem.

Cleanuparr closes the loop by matching filenames inside downloads against a community-maintained
blocklist and removing/blocking them automatically, then triggering a replacement search.

Secondary value: cleaning stalled and failed-import downloads that currently sit in the queue
until noticed, and proactive missing/cutoff-unmet searching.

## Scope

In scope:

- **Malware Blocker** — filename blocklist matching, remove + blocklist + re-search.
- **Blacklist Sync** — push the same list into qBittorrent's "Excluded file names".
- **Queue Cleaner** — failed-import and stalled download cleanup.
- **Missing + cutoff-unmet search** — proactive Sonarr/Radarr searching.
- **Seeding cleanup** — remove torrents after a seeding threshold.

Out of scope:

- **Orphaned / no-hardlink cleanup.** Requires `/data` mounted at the exact path qBittorrent
  reports, and a path mismatch deletes real library files. The feature's value here is low
  (disk is not under pressure) and the failure mode is unrecoverable. Excluding it also removes
  the need for any `/data` mount at all, which simplifies the deployment materially.
- **Cleanuparr's own notifications** (Notifiarr/Apprise). Alertmanager already exists; a second
  channel for the same signal is duplicated plumbing. Revisit if Cleanuparr's actions need
  alerting distinct from cluster health.
- **PostgreSQL via CloudNativePG.** SQLite is the documented default and adequate at this scale.

### Note on Qui

Qui was selected on 2026-08-04 for tracker-aware seed reaping. Qui runs **only on the seedbox**,
so there is no in-cluster overlap: Cleanuparr owns seeding cleanup for the cluster's qBittorrent,
Qui owns it on the seedbox. No coordination needed.

## Architecture

Standard app-template deployment in `apps/cleanuparr/`, picked up automatically by the `apps`
ApplicationSet (sync wave 3) via the `app.yaml` file generator.

```
apps/cleanuparr/
  app.yaml          # chartName/chartRepo/chartVersion — Renovate-managed
  values.yaml       # container, service, HTTPRoute, persistence
  config-pvc.yaml   # local-path PVC + rationale
  vpa.yaml          # standard VPA, Recreate
```

Deliberately absent:

- **No `arr-api-key.yaml` / sealed secret.** Cleanuparr has no env-var configuration for arr
  connections — everything operational lives in its SQLite database, entered via the web UI.
  There is nothing to seal.
- **No `limitrange.yaml`.** That exists in `apps/sonarr/` for VPA request:limit-ratio reasons;
  the VPA's own `minAllowed` floor covers this app.
- **No `/data` volume.** Follows from excluding orphan/hardlink cleanup. Blacklist Sync reads
  its list from an HTTPS URL, not a local file, so no filesystem access to media is required.

### Container

| Field | Value |
|---|---|
| Image | `ghcr.io/cleanuparr/cleanuparr` |
| Tag | `2.10.3` (latest release as of 2026-08-02) |
| Port | `11011` |
| Env | `PORT=11011`, `PUID=1000`, `PGID=1000`, `UMASK=022`, `TZ=America/Los_Angeles` |

Pinned to a release tag, not `latest` — the project's own docs warn that `latest` ships breaking
changes. Renovate handles bumps like every other image in the repo.

**Verify before applying:** confirm the ghcr tag is `2.10.3` and not `v2.10.3`. The GitHub
*release* tag is `v2.10.3`; the container tag convention is not documented and must be checked
against the registry rather than assumed.

No `nodeSelector`. Cleanuparr mounts no NFS and touches no media files, so it does not need
`homelab.io/media`. The local-path PV binds it to whichever node it first schedules on, and the
`Recreate` strategy (app-template default) keeps it there.

### Storage

`cleanuparr-config-local`, `local-path`, 2Gi, ReadWriteOnce, consumed via
`persistence.config.existingClaim`.

This is a fourth instance of the SQLite-over-NFS exception established today for
sonarr/radarr/lidarr/prowlarr. Same reasoning: `/config` holds a SQLite database, and SQLite over
NFS does not work reliably — Sonarr logged 996 "database is locked" errors in a week, one of which
stalled the nightly refresh for 35 minutes and jammed the task queue hard enough that
`/api/v3/queue` stopped answering.

Two details specific to this volume:

- **No backup path, deliberately.** Unlike the arrs, Cleanuparr has no scheduled-backup feature
  writing to `/data/backups/`. Recovery from NVMe loss is: delete the PVC, let it recreate empty,
  re-enter the arr URLs, API keys, qBittorrent credentials, and job settings in the UI. Roughly
  15 minutes of clicking. The API keys are all recoverable from `secrets/.secrets` because they
  are `generate:`-derived. Building a backup path for 15 minutes of re-entry is not worth it.
- **Sized once.** `local-path` cannot be expanded in place. 2Gi against a settings database plus
  logs is generous.

The PVC manifest carries **no** `argocd.argoproj.io/sync-wave` annotation. `local-path` is
`WaitForFirstConsumer`, so the PVC stays `Pending` — which ArgoCD reads as unhealthy — until its
consumer is scheduled. An earlier wave deadlocks the sync permanently. Same reasoning as
`apps/nextcloud/html-pvc.yaml` and `apps/sonarr/config-pvc.yaml`.

### Networking

HTTPRoute on the `homelab` Gateway at `cleanuparr.nik-homelab.dev`, with the standard Homepage
annotations (group: Media).

The Gateway VIP is announced on the LAN by Cilium L2, so the Cloudflare record resolves publicly
but points at an RFC1918 address on `192.168.30.0/24`. Nothing is internet-routable; access is
LAN or Tailscale, same as every other app.

This matters for one Cleanuparr setting. **"Disable Auth for Local Addresses"** treats
`10.0.0.0/8` as trusted, and Envoy presents a pod IP from that range, so every request through
the Gateway will appear local and bypass login. Given the Gateway is not internet-reachable this
is acceptable and convenient rather than a hole — but it should be a conscious choice, and
**"Trust Forwarded Headers" must stay OFF** (with it on, `X-Forwarded-For` becomes spoofable and
the bypass could be reached by anything that can talk to Envoy).

**Verify:** that `cleanuparr.png` exists in the dashboard-icons set used by Homepage. If not,
fall back to an `mdi-` icon rather than shipping a broken tile.

## Configuration

All runtime configuration lives in the SQLite database, entered through the UI. This is a genuine
gap versus the rest of the repo — it is not GitOps-managed and not reproducible from `main`. It is
accepted rather than worked around: Cleanuparr offers no file-based or env-based config for these
settings, and the recovery cost is the 15 minutes noted above.

### Connection targets

| Service | URL |
|---|---|
| Sonarr | `http://sonarr.sonarr.svc.cluster.local:8989` |
| Radarr | `http://radarr.radarr.svc.cluster.local:7878` |
| Lidarr | `http://lidarr.lidarr.svc.cluster.local:8686` |
| qBittorrent | qBittorrent's ClusterIP service |

API keys come from `secrets/.secrets` (the `*_API_KEY` values already registered in
`secrets/registry.tsv`).

### Malware Blocker

| Setting | Value | Rationale |
|---|---|---|
| Blocklist Path | `https://cleanuparr.pages.dev/static/blacklist` | Community list; official lists auto-reload every 5 min |
| Blocklist Type | Blacklist | Whitelist inverts the meaning |
| **Delete if any file is blocked** | **ON** | **Critical.** Default is OFF, which removes a download only when *every* file matches. The 2026-08-06 payload was a `.scr` alongside a decoy video — under the default it would have been kept with the `.scr` merely marked skipped. This toggle is the entire point of the deployment |
| Ignore Private | ON | Cluster uses public indexers only |
| Delete Private | OFF | H&R risk on private trackers |
| Process downloads with no content ID | OFF | Without a content ID, no replacement search can be triggered |
| Schedule | every 5 minutes | Cheap; catches payloads before completion |

Blocklist patterns support `*ext`, `ext*`, `*ext*`, exact match, and `regex:<expr>`.

**Lidarr gets no blocklist initially.** The official lists are documented for Sonarr and Radarr
only; music container and extension names differ enough that a TV/movie list risks false
positives on legitimate audio files. Add a Lidarr-specific list later if warranted.

### Blacklist Sync

Distinct mechanism from Malware Blocker: it writes the list into qBittorrent's **"Excluded file
names"** so the file is never written to disk at all — prevention rather than post-hoc cleanup.
Syncs hourly to all enabled qBittorrent clients when the content hash changes.

- Blacklist Path: same HTTPS URL as above.
- **Manual step required:** Cleanuparr populates the "Excluded file names" field but does **not**
  enable it. The setting must be turned on in qBittorrent's own options or the sync is inert.

### Queue Cleaner

Strike-based, three independent subsystems. `Max Strikes` minimum is 3, and strikes accumulate
one per run — so the real grace period is *strikes × schedule interval*. At a 5-minute schedule,
3 strikes is 15 minutes.

**Failed Import.** `Max Strikes` 0 disables; otherwise ≥3. `Pattern Mode: Exclude` with patterns
such as `manual import required` and `recently aired`, so items that merely need attention are
not reaped. Patterns are case-insensitive plain substrings — no regex, no wildcards — and must
never contain the `{0}`-style placeholders from the arrs' message templates, since the real
message carries the substituted value. `Change Category` is available as a softer alternative to
deletion, moving the item to the arr's post-import category instead.

**Stalled.** Enable `Reset Strikes on Progress`, and set `Minimum Progress to Reset` to a real
value. Left blank, *any* progress resets the count, so a torrent trickling a few KB per run never
accumulates strikes. `Downloading Metadata Max Strikes` is separate and global (qBittorrent only).

**Slow — disabled initially.** This is the highest-risk rule group. qBittorrent runs through
Mullvad using *userspace* WireGuard at MTU 1170, so throughput is both lower and lumpier than
bare metal; a naive floor like `1MB/s` would reap healthy downloads. Leave slow rules off, observe
actual speed distributions, then add a rule with a threshold grounded in that data.

**Enable `Internet Connectivity Check` in General settings.** On failure the Queue Cleaner skips
its run rather than striking every download. Worth having given this cluster's history of node
and network incidents.

## Rollout

Phased so that the high-value, low-risk half ships and proves itself before anything with tunable
thresholds is switched on.

### Phase 0 — Prerequisite (before deploying)

In Prowlarr: Settings → Apps → each app → Show Advanced → enable **Sync Reject Blocklisted
Torrent Hashes While Grabbing**. Without this, blocked releases return to the queue on the next
search and the whole exercise is defeated. Doing it in Prowlarr covers Sonarr, Radarr, and Lidarr
in one place.

### Phase 1 — Deploy with everything off

Merge the four files. ArgoCD syncs; the PVC binds on first consumer. Confirm the pod is Running,
the route resolves, and the UI loads. Set **Dry Run ON** immediately, before configuring anything
that could act.

### Phase 2 — Malware Blocker + Blacklist Sync

The direct answer to the `.scr` incident, and the low-risk half: a filename match is unambiguous,
and neither feature needs threshold tuning.

1. Configure arr connections and the qBittorrent client.
2. Configure Malware Blocker per the table above (Sonarr and Radarr only).
3. Configure Blacklist Sync, then enable "Excluded file names" in qBittorrent.
4. Observe Dry Run logs. Verify it identifies known-bad patterns and — more importantly — flags
   nothing legitimate.
5. Turn Dry Run **off**. Malware Blocker is now live.

### Phase 3 — Queue Cleaner

Only after Phase 2 has run clean for several days.

1. Re-enable Dry Run.
2. Configure Failed Import and Stalled rules. Slow rules stay off.
3. Enable Internet Connectivity Check.
4. Observe logs across at least one full download cycle, including a genuinely stalled torrent if
   one appears.
5. Turn Dry Run off.

### Phase 4 — Searching and seeding cleanup

Missing/cutoff-unmet search and seeding cleanup, one at a time, each with a Dry Run observation
period. These are convenience features; they wait until the cleanup path is trusted.

## Verification

- Pod Running, ArgoCD Synced/Healthy, `cleanuparr-config-local` Bound.
- `cleanuparr.nik-homelab.dev` serves the UI over LAN and Tailscale.
- Homepage tile appears in the Media group with a working icon.
- "Trust Forwarded Headers" is OFF.
- Config survives a pod delete (proves the PVC is actually mounted and written).
- Phase 2 exit: Dry Run logs show correct identification and zero false positives.

## Open questions

None blocking. Two items to check during implementation rather than design:

1. The exact ghcr tag string for 2.10.3.
2. Whether `cleanuparr.png` exists in the Homepage icon set.

## Follow-up

`CLAUDE.md`'s storage rule lists two `local-path` exceptions (replicated CNPG, and volumes
reconstructible from an image). Today's migrations plus this deployment establish a third —
SQLite databases whose loss is recoverable from an arr backup or by re-entering settings. The rule
text should be amended to describe that exception rather than having five app directories each
justify it in a comment.
