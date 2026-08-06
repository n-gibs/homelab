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
  app.yaml             # chartName/chartRepo/chartVersion — Renovate-managed
  values.yaml          # container, service, HTTPRoute, persistence
  config-pvc.yaml      # local-path PVC + rationale
  backup-cronjob.yaml  # nightly SQLite backup to /data/backups/cleanuparr
  vpa.yaml             # standard VPA, Recreate
```

Deliberately absent:

- **No `arr-api-key.yaml` / sealed secret.** Cleanuparr has no env-var configuration for arr
  connections — everything operational lives in its SQLite database, entered via the web UI.
  There is nothing to seal.
- **No `limitrange.yaml`.** That exists in `apps/sonarr/` for VPA request:limit-ratio reasons;
  the VPA's own `minAllowed` floor covers this app.
- **No `/data` volume on the Cleanuparr pod.** Follows from excluding orphan/hardlink cleanup.
  Blacklist Sync reads its list from an HTTPS URL, not a local file, so the app itself needs no
  filesystem access to media. The backup CronJob does mount NFS at `/data`, but that is a separate
  pod with a separate lifetime — the app never sees the media share.

### Container

| Field | Value |
|---|---|
| Image | `ghcr.io/cleanuparr/cleanuparr` |
| Tag | `2.10.3` (latest release, 2026-08-02) |
| Port | `11011` |
| Env | `PORT=11011`, `PUID=1000`, `PGID=1000`, `UMASK=022`, `TZ=America/Los_Angeles` |

Pinned to a release tag, not `latest` — the project's own docs warn that `latest` ships breaking
changes. Renovate handles bumps like every other image in the repo.

The GitHub *release* tag is `v2.10.3`, but the container tag carries no `v` prefix. Verified
against the registry: `ghcr.io/cleanuparr/cleanuparr:2.10.3` returns a manifest, `v2.10.3` 404s.

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

The durability objection to `local-path` carries less weight than it appears to. worker-01 is
itself the NFS server, so the `nfs` class was never giving this volume a second *node* — it was
giving it a second *disk* on the same node (a 10.9T spinning USB drive) versus the internal NVMe
that `local-path` uses. The trade is real but small, and it is bought back by the backup below.

**Sized once.** `local-path` cannot be expanded in place. 2Gi against a settings database plus
logs is generous.

### Backup

The preferred option is the app's own backup feature, but Cleanuparr has **none** — no
System → Backup equivalent anywhere in its settings or docs. So this falls to the CronJob case: a
nightly job in `apps/cleanuparr/backup-cronjob.yaml` writing to `/data/backups/cleanuparr`,
alongside the arrs' own backups on the NFS share.

This puts the backup in a different failure domain from the volume: `local-path` on worker-01's
internal NVMe for the live database, the USB-attached spinning disk for the backups.

**Mechanism.** The CronJob mounts two volumes:

| Volume | Mount | Note |
|---|---|---|
| `cleanuparr-config-local` (existing PVC) | `/config`, read-only where possible | RWO — see below |
| `nfs` `192.168.30.194:/mnt/storage` | `/data` | Same direct NFS mount the media apps use |

**On mounting an RWO volume twice:** `ReadWriteOnce` is a per-*node* constraint, not per-pod —
two pods on the same node may both mount it. The `local-path` PV carries node affinity, so the
scheduler is forced to place the backup pod on the same node as Cleanuparr, which makes this safe
rather than lucky. (`ReadWriteOncePod` would forbid it; that is not the class in use here.)

**Why not `cp`.** SQLite in WAL mode spreads committed state across `.db`, `.db-wal`, and
`.db-shm`; copying them with `cp` while the app is writing can produce a torn, unrestorable
backup. The correct approach is SQLite's online backup API, which takes a consistent snapshot of
a live database.

**Image: `python:3.13-alpine`.** Python's stdlib `sqlite3` module exposes
`Connection.backup()` — the online backup API — so this needs no `sqlite3` CLI, no `apk add` at
runtime, and no new third-party image. It is an official image, so Renovate tracks it like
everything else. (Checked first whether an image already in the cluster would do: the
linuxserver arr images do not ship the `sqlite3` binary.)

**What gets backed up.** Cleanuparr creates one database per internal context (`data`, `events`,
`users`), so the job globs `/config/*.db` rather than naming files. It also copies
`cleanuparr.json` and the DataProtection keys, which live in `/config` and are not in the
databases. Log files are skipped.

Output is a single dated archive per run, with `find -mtime +14 -delete` retention matching the
pattern in `apps/nextcloud/pg-backup.yaml`.

**Monitoring — do not skip this.** `system/monitoring-system/prometheusrule-backups.yaml` covers
new CronJobs generically for the "runs but never succeeds", "stopped being scheduled", and
"suspended" cases, so those need no edit. But `BackupCronJobMissing` is the one deliberately
non-generic rule: it counts CronJobs matching `.+-db-backup` and alerts when the count is `< 2`.
Naming this job **`cleanuparr-db-backup`** brings it under that guard, which means the threshold
must be raised to `< 3` and the alert's summary and description updated to name three jobs.
Left unchanged, the rule silently tolerates one backup disappearing entirely.

**Recovery from NVMe loss:** delete the PVC, let it recreate empty, extract the newest archive
from `/data/backups/cleanuparr/` back into `/config`, restart the pod. Failing that, the manual
path still exists — re-enter arr URLs, API keys, and job settings in the UI, roughly 15 minutes;
the API keys are all recoverable from `secrets/.secrets` since they are `generate:`-derived.

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

Merge the five files, plus the `BackupCronJobMissing` threshold bump to `< 3`. ArgoCD syncs; the
PVC binds on first consumer. Confirm the pod is Running, the route resolves, and the UI loads. Set
**Dry Run ON** immediately, before configuring anything that could act.

Create `/data/backups/cleanuparr` on the NFS share and trigger the backup CronJob manually
(`kubectl create job --from=cronjob/cleanuparr-db-backup`) to prove it can mount the RWO volume
alongside the running pod and write a non-empty archive. Better to find that out now than during
a restore.

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
- Backup CronJob completes and writes a non-empty archive to `/data/backups/cleanuparr`.
- `BackupCronJobMissing` is not firing after the threshold bump (proves the new job is counted).
- Phase 2 exit: Dry Run logs show correct identification and zero false positives.

## Open questions

None blocking. One item to check during implementation rather than design: whether
`cleanuparr.png` exists in the Homepage icon set, with an `mdi-` fallback if not.

## Documentation

`CLAUDE.md` and `.claude/commands/add-app.md` both said "always NFS, never local-path" — guidance
that today's four migrations had already invalidated. Both were corrected alongside this spec:
SQLite config volumes now go on `local-path` as a rule rather than an exception, with durability
supplied by a scheduled backup to the NFS share. That is why this deployment ships a backup
CronJob rather than treating one as optional.
