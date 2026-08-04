# Seedbox Integration — Design

**Date:** 2026-08-04
**Status:** Approved, pending implementation plan
**Supersedes:** `docs/superpowers/plans/2026-06-25-seedbox-integration.md` (Hetzner VPS, on stale branch `feat/seedbox-integration`)

## Goal

Meet private-tracker seeding requirements by moving torrenting for private trackers to a
rented seedbox slot, while Radarr, Sonarr, and Prowlarr stay in the k3s cluster and import
finished content automatically.

## Why a rented slot

The binding constraint is home upload bandwidth: **30–40 Mbps**. Saturated 24/7 that is
~324–432 GB/day, but delivering it means pinning the uplink at 100% permanently, competing
with Jellyfin remote playback, Nextcloud sync, and Immich uploads.

Monthly volume was never the real issue. **Ratio on private trackers is won in the burst
window** right after a release lands, when few seeders exist and demand is high. A 1 Gbit
uplink pushes several multiples of the torrent size through that window; 30 Mbps cannot,
regardless of monthly totals.

A secondary constraint made local hosting a non-starter independently: **Mullvad removed
port forwarding** (stopped issuing 2023-05-29, deleted all mappings 2023-07-01, no plans to
restore). The existing `apps/qbittorrent` + gluetun stack is therefore passive-only today —
it uploads only to peers that are themselves connectable. That is the likely root cause of
the seeding shortfall. Fixing it locally would mean either swapping gluetun to a
port-forwarding provider (AirVPN/Proton/Windscribe) or NAT-forwarding on OPNsense and
exposing the residential IP. Neither changes the 30–40 Mbps ceiling.

Rejected alternatives:

- **Cloudflare Tunnel** — HTTP(S) only; cannot accept inbound BitTorrent peer connections,
  and torrent traffic violates Cloudflare's ToS regardless.
- **Caddy reverse proxy** — same layer mismatch. `caddy-l4` can forward raw TCP but does not
  create inbound reachability; an OPNsense NAT rule would still be doing the actual work.
- **Local box outside the cluster** — solves neither bandwidth nor port forwarding. Would
  also put an internet-reachable torrent client on `192.168.30.0/24` with a pivot path into
  the cluster subnet.
- **Self-managed Hetzner VPS** (the June plan) — no cheaper than a slot once a seeding-sized
  volume is attached, adds Terraform + Ansible + patching for one pet VPS, and puts us
  personally in Hetzner's notice-and-takedown abuse loop.

## Provider

**seedit4.me, Sidekick Pro — €11.99/month, billed monthly.**

| Spec | Value |
|------|-------|
| Storage | 1500 GB HDD |
| Network | 2 Gbit in / 1 Gbit out |
| Upload allowance | 5 TB/month\* |
| Root access | No\* |
| IP | Shared |
| Apps | Up to 8; qBittorrent confirmed available |

\* Both figures carry an asterisk on seedit4.me's pricing page whose footnote has not been
read. "Downloads uncounted" is inferred from third-party reviews, not from the Pro plan card
itself — confirm before relying on it, since a combined allowance would change the sizing
argument entirely (this is exactly the ambiguity that ruled out seedhost).

Sizing rationale: **storage is the one resource already abundant at home** (12 TB on
worker-01), so the smallest tier is correct. The slot only holds what is actively seeding;
finished content is pulled home and seeds from the box for the tracker's required duration.

**Assumption, not a measurement:** monthly grab volume is taken as ~500 GB, which makes the
5 TB allowance ~10× need. This number was never measured. If actual grabs run past ~1.5
TB/month the tier choice should be revisited, since sustained ratio 3:1 on that volume would
approach the cap.

Chose the metered "Pro" family over the €16.99 unmetered "NL" family deliberately: unmetered
carries an unpublished Fair Use Policy, while 5 TB is a hard number that can be planned
against. Upgrading is a billing change, not a migration. **But see the open item on plan
family below — this choice is not yet safe to act on.**

Chose seedit4.me over seedhost.eu (cheaper per TB, 10 Gbps on every tier) because
seedhost's "Monthly Traffic" column tracks disk size almost exactly at low tiers
(1 TB/1 TB, 2/2, 3/3), which is the shape of a **combined** up+down budget — every GB
downloaded would eat paid-for upload. seedit4.me labels its allowance "Upload/Month" with
downloads unlimited, which is unambiguous. Seedhost remains the fallback if that reading
turns out wrong.

**TorrentLeech invite** ships with a valid plan and email — real added value, and it
resolves the shared-IP concern for that tracker: a provider whose IPs TL blocklisted could
not offer TL invites as a perk.

Do not prepay annually (€137 vs €143.88 is under 5%) until the provider is proven.

## Architecture

Two independent channels between cluster and seedbox. Nothing inbound to the home network;
no VPN and no tunnel on either path.

```
      ┌──────────────────── seedit4.me Sidekick Pro (nl137) ─────────────────────┐
      │  autobrr ──(IRC announce)──▶ qBittorrent 5 ──┬── category "ratio"        │
      │                                              └── category "media"        │
      │  completed downloads dir                                                 │
      └──────▲──────────────────────────────────────────────▲────────────────────┘
             │ 1. control: qBittorrent API over HTTPS       │ 2. data: SFTP :2097
             │    (outbound from cluster)                   │    (outbound, read-only)
      ┌──────┴──────────────────────────────────────────────┴────────────────────┐
      │ k3s                                                                      │
      │                                                                          │
      │  Radarr ─┐ download client #2          apps/rclone-seedbox (CronJob)     │
      │  Sonarr ─┤ + remote path mapping       rclone copy ──┐                   │
      │          │                                           ▼                   │
      │          │                        /data/downloads/seedbox/  (NFS)        │
      │          └──▶ import (hardlink) ──▶ /data/media/{tv,movies} (NFS)         │
      │                                                                          │
      │  qBittorrent + gluetun (unchanged) ──▶ public trackers                    │
      └──────────────────────────────────────────────────────────────────────────┘
```

Only `media`-category content is pulled home. `ratio`-category grabs seed in place on the
seedbox and are deleted there once their share limit is met.

### Channel 1 — control

Radarr and Sonarr each gain the seedbox qBittorrent as a **second** download client,
pointed at its public WebUI URL over HTTPS with credentials. Plain outbound HTTPS. The
existing local `apps/qbittorrent` behind gluetun is untouched and keeps serving public
trackers.

Prowlarr tags route per indexer: TorrentLeech → seedbox client, public trackers → local
client. Both clients coexist; this is additive.

### Channel 2 — data

**Endpoint (confirmed):** SFTP at `nl137.seedit4.me:2097`. No shell access — the box runs
ProFTPD (`mod_sftp`), so SFTP is served without an SSH login shell.

Two required rclone settings follow from that, per the
[rclone SFTP docs](https://rclone.org/sftp/):

- **`shell_type=none`** — rclone otherwise tries to open a remote shell session to detect the
  shell type. Setting it explicitly avoids repeated failed detection.
- **`disable_hashcheck=true`** — rclone's checksum support runs `md5sum`/`sha1sum` *as remote
  shell commands*. With no shell those fail on every transfer.

**A CronJob running `rclone copy` replaces the FUSE mount.** The June plan's privileged
mount pod is not used. `rclone copy` pulls new completed files from the seedbox into
`/data/downloads/seedbox/` on NFS; the *arr treat that as an ordinary local directory.

This is strictly less machinery, and the reason is not just simplicity:

| | FUSE mount (June plan) | `rclone copy` CronJob |
|---|---|---|
| Privileged container | required | **no** |
| hostPath + `Bidirectional` propagation | required | **no** |
| Stale-mount liveness probe | required | **no** |
| Pod pinned to worker-01 | forced by hostPath | not needed |
| *arr import | copy mount → NFS | **hardlink** NFS → NFS |

The last row matters most: content lands on NFS *before* the *arr see it, so import
hardlinks instead of copying — no second full-size write, and the seedbox keeps its own copy
and keeps seeding regardless. Eliminating the privileged pod also removes the only
security-relevant component in the design.

The cost is polling latency instead of a live view. Nothing downstream is latency-sensitive,
so this is not a real cost.

**Remote Path Mapping** in each *arr still maps the seedbox's reported path to
`/data/downloads/seedbox/...`, so the *arr can resolve what qBittorrent reports. Without it
the import fails — qBittorrent reports paths that do not exist in the *arr container.

If `rclone copy` has not finished when the *arr check, the import simply retries on the next
scan. The seedbox copy is authoritative throughout.

### Grab paths

Two independent paths now feed the seedbox qBittorrent:

1. **Prowlarr → Radarr/Sonarr → seedbox qBittorrent.** Curated — content actually wanted,
   pulled home and imported.
2. **autobrr → seedbox qBittorrent** (running on the seedbox, targeting localhost). Reacts to
   tracker IRC announces in seconds, where Prowlarr RSS polls on an interval. This is what
   actually wins the burst window the whole design is built around.

Path 2 content is grabbed for ratio, is not in the *arr wanted lists, and never leaves the
box. That is intentional — but see the disk-pressure requirement below.

**The two paths keep separate indexer configs.** autobrr does not read Prowlarr's; both
IPTorrents and TorrentLeech must be registered in each. Prowlarr answers "find me this thing"
for the *arr; autobrr answers "something just dropped." Both are confirmed present in
[autobrr's supported IRC-announce indexer list](https://autobrr.com/configuration/indexers).

autobrr's action targets the seedbox's local qBittorrent with category `ratio` — **not**
Radarr or Sonarr, which would turn ratio grabs into library imports and defeat the purpose.

## Components

| Component | Change | Notes |
|-----------|--------|-------|
| `apps/rclone-seedbox/{app.yaml,values.yaml}` | new | CronJob, not Deployment; `rclone copy` seedbox → NFS; `shell_type=none`, `disable_hashcheck=true`; explicit `resources.requests/limits`; `concurrencyPolicy: Forbid` |
| `apps/rclone-seedbox/sftp-creds.yaml` | new | sealed secret, SFTP credential |
| `secrets/registry.tsv` | modify | one row for the SFTP credential |
| `Justfile` | modify | add `wire-seedbox` |

No changes to `apps/radarr/values.yaml` or `apps/sonarr/values.yaml`: content arrives under
`/data/downloads/seedbox/` on the NFS volume they already mount at `/data`. The June plan's
hostPath edits, the `hostPathType` hazard, and the node-pinning requirement all disappear
with the FUSE mount.

No `vpa.yaml`: VPA targets long-running controllers, not CronJobs. Resources are set
explicitly instead — which the VPA-`Off` decision already required.

### Seedbox disk management — required, not optional

**On the Pro plan with autobrr grabbing for ratio, 1500 GB fills fast, and a full disk stalls
both grab paths.** This is a required part of the design.

The mechanism is **separate qBittorrent categories per grab path**, because the two have
incompatible deletion rules:

| Category | Fed by | Share limit | On limit reached |
|----------|--------|-------------|------------------|
| `ratio` | autobrr | global floor (below), plus margin | remove torrent **and files** |
| `media` | Radarr/Sonarr | global floor **plus transfer margin** | remove torrent and files |

**One global floor, not per-tracker floors.** Only two trackers are in scope (IPTorrents,
TorrentLeech), so the floor is the stricter of the two requirements applied to both. Splitting
into per-tracker categories doubles the config to buy back ratio only on the more lenient
tracker — do it later if the two requirements turn out to diverge meaningfully, not now.

Two constraints that a single shared rule would violate:

- **Never delete below the tracker's minimum seed time.** Aggressive auto-delete to reclaim
  space causes hit-and-run penalties — the exact failure the seedbox exists to avoid. Share
  limits must sit *above* the tracker requirement, never below.
- **Never delete `media` content before `rclone copy` has pulled it home.** Path 1 content is
  only safe to remove once it is on NFS. Give `media` a longer floor than `ratio`, since the
  transfer is bounded by home download speed.

Plus autobrr filter size ceilings, so a single oversized release cannot consume the disk.

### Design decisions that differ from the June plan

- **No Terraform, no Ansible.** Tasks 1–2 of the old plan (~600 of 1109 lines) are deleted
  outright — there is no machine to provision or configure.
- **No Tailscale.** Sidekick Pro has no root, so the tailnet path is unavailable. rclone
  connects to `nl137.seedit4.me:2097` instead of a Tailscale IP.
- **No privileged FUSE mount pod, no hostPath, no mount propagation, no node pinning.**
  Replaced by a `rclone copy` CronJob writing to NFS. This also deletes the liveness-probe
  requirement (a stale FUSE mount hangs without killing the process, so nothing would have
  recycled it) and the `hostPathType` start-order hazard that could have kept Radarr and
  Sonarr from starting.
- **`shell_type=none` and `disable_hashcheck=true`** on the rclone remote. ProFTPD's
  `mod_sftp` serves SFTP with no login shell, and rclone's checksum support shells out to
  `md5sum`/`sha1sum`. Without these, every transfer errors.
- **Secret sealing goes through `secrets/registry.tsv`**, not a bespoke `seal-*` Justfile
  target. `seal.sh` only does `--from-literal`, but `secrets/.secrets` is sourced by bash, so
  a multi-line key works as `RCLONE_SSH_PRIVATE_KEY="$(cat ~/.ssh/rclone_seedbox)"` if key
  auth is used. No script change needed either way.

### Storage rule compliance

Nothing in this design uses `local-path` or a hostPath. The CronJob writes to the existing
NFS volume (`192.168.30.194:/mnt/storage`), so `/data/downloads/seedbox/` inherits the same
durability as the rest of the media library. The CLAUDE.md `local-path` exceptions are not
invoked.

## Failure modes

| Failure | Effect | Handling |
|---------|--------|----------|
| Seedbox unreachable | CronJob run fails | next scheduled run retries; *arr keep running, nothing mounted to wedge |
| CronJob run overruns its schedule | overlapping copies | `concurrencyPolicy: Forbid` |
| `rclone copy` interrupted mid-file | partial file on NFS | `rclone copy` resumes/re-transfers next run; *arr import retries; seedbox copy authoritative |
| Seedbox disk full | both grab paths stall | category share limits + autobrr size ceilings (above) |
| Auto-delete fires before tracker minimum | hit-and-run penalty | share limits set above tracker requirement, never below |
| Auto-delete fires before content pulled home | content lost from library, still on tracker | `media` category floor set longer than `ratio` |
| Upload allowance exhausted (5 TB/mo) | seeding stops until billing reset | monitor; upgrade tier if it recurs |

## Out of scope

- Migrating public-tracker torrents off the local qBittorrent. It stays as-is.
- Media servers on the seedbox. Sidekick Pro has "No Media Servers"; Jellyfin, Radarr,
  Sonarr, and Prowlarr all stay in-cluster.
- Importing autobrr's ratio grabs into the library. They exist to seed and are deleted in
  place once the share limit is met.
- Cross-seeding tooling.
- Monitoring the seedbox in Prometheus. Worth doing later (upload allowance and disk are both
  worth alerting on) but not part of this work.

## Verification

1. CronJob completes; `/data/downloads/seedbox/` on NFS lists seedbox content.
2. Radarr and Sonarr each show two healthy download clients.
3. A TorrentLeech grab lands on the seedbox, not the local client.
4. That grab reaches NFS, imports into `/data/media/...`, and appears in Jellyfin.
5. The import **hardlinks** rather than copies — verify link count, not just presence.
6. The torrent keeps seeding on the seedbox after import.
7. A public-tracker grab still routes to the local gluetun client.
8. An autobrr grab lands in the `ratio` category, seeds, and is **not** imported.
9. A torrent reaching its share limit is removed with its files, and only after the tracker's
   minimum seed time.

## Resolved

- **Plan:** Sidekick Pro, €11.99/month. Public trackers permitted, 5 TB/month upload.
- **Transfer:** SFTP at `nl137.seedit4.me:2097`. No shell — ProFTPD `mod_sftp`.
- **Client:** qBittorrent 5. API v2, which is what the *arr expect.
- **Also on the box:** ProFTPD, ffmpeg, autobrr. Only qBittorrent and autobrr are used here.
- **autobrr's role:** ratio grabbing (Path 2), not merely a faster feed into the *arr. This is
  what makes seedbox disk management a required component rather than a later nicety.

## Open items

- **SFTP auth method.** Key auth is preferred, but with no shell it depends on whether the
  panel offers key upload or `~/.ssh/authorized_keys` is writable over SFTP. If key auth is
  attempted, note that ProFTPD's `mod_sftp` reads `AuthorizedUserKeys` in **RFC4716** format,
  not OpenSSH format (`ssh-keygen -e -m RFC4716` converts) — a common silent failure.
  Fallback is the account password via `rclone obscure`. Either way this changes only the
  sealed secret's contents and the rclone remote definition.
- **Exact completed-downloads path** on the slot — needed for both the CronJob source and the
  *arr remote path mapping. Read it off the box.
- **qBittorrent WebUI URL** as exposed by seedit4.me, for the download client config.
- **CronJob interval.** Frequent enough that imports feel prompt, infrequent enough not to
  hammer the SFTP endpoint. Start at 15 minutes, adjust on observed behaviour.
- **Seed requirements for IPTorrents and TorrentLeech** — the only two trackers in scope.
  Needed: minimum seed time (HnR window), minimum per-torrent ratio, and whether each applies
  per-torrent or account-wide. These live behind each tracker's login and are not guessed
  here; read them off the rules/FAQ pages. Required *before* auto-delete is enabled — turning
  it on without these numbers risks exactly the hit-and-run penalties the seedbox exists to
  avoid. Until then, run with auto-delete off and prune by hand.
- **autobrr IRC announce credentials** for both trackers: tracker passkey/RSS key (autobrr
  builds the `.torrent` URL from it), IRC nick, NickServ password if the network requires
  registration, and the announce bot's invite command. Adding an indexer in autobrr
  auto-configures its IRC network and channels, so only the credentials are manual.
- **TorrentLeech in Prowlarr**, if not already present — Prowlarr is the *arr search path and
  is configured independently of autobrr. Indexers must be registered in *both*; autobrr does
  not read Prowlarr's config.
