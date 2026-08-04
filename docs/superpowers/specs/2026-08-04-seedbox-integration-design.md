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

| Category | Fed by | Save path | Purpose |
|----------|--------|-----------|---------|
| `ratio` | autobrr | its own dir | seeds in place, never imported |
| `media` | Radarr/Sonarr | its own dir | pulled home by the CronJob, then imported |

**Categories separate save paths only — share limits are global.** One global
inactive-seeding-time limit of 10 days satisfies both: `media`'s only additional requirement is
surviving until `rclone copy` pulls it home, which takes hours, and 10 days clears that by
orders of magnitude. Two differing limits would be config with no behavioural difference.

Per-category share limits do exist, but only from **qBittorrent 5.2.0** (right-click category →
Edit Category); before that, limits are global or per-torrent. Since the global limit suffices,
this design does not depend on that version.

**Where each setting lives** — autobrr does not know or fetch tracker rules:

| Setting | Configured in |
|---------|---------------|
| Category and save path at grab time | autobrr → qBittorrent action |
| Inactive seeding time limit + removal action | qBittorrent → Options → BitTorrent → Seeding Limits |
| Grab rate, size ceilings, freeleech preference | autobrr → filters |

Exact values for qBittorrent → Options → BitTorrent → **Seeding Limits**:

| Field | Setting |
|-------|---------|
| When ratio reaches | unchecked |
| When total seeding time reaches | unchecked |
| When inactive seeding time reaches | **checked, `14400`** |
| then | **Remove torrent and its content** |

Three specifics that are easy to get wrong:

- **The fields are minutes and default to 1440** — one day. Checking the box without changing
  the value deletes after 24 hours inactive, an HnR warning on every TL grab. 10 days = 14,400.
- **"Remove torrent" ≠ "Remove torrent and its content".** The former leaves files on disk and
  reclaims nothing, which defeats the rule's only purpose.
- **The `then` action is shared across all three conditions**, not per-condition — a further
  reason to leave the ratio limit unchecked.

**autobrr's "Release Cleanup Jobs" are not disk cleanup.** They delete autobrr's own release
*history* records — database rows, not torrents or files — so they reclaim no seedbox space
whatsoever. Configuring one in the belief that it manages disk would let the disk fill while
the job reports success. Disk reclamation is the qBittorrent share limit, and only that.

Pruning history is optional housekeeping (the table grows with every announce processed across
two `#announce` channels). If enabled, keep a generous window — 30 days or more — because
autobrr uses release history for duplicate detection, and an aggressive window risks re-grabbing
releases it already handled. Deletion is permanent. Not enabled for now.

**Separate save paths per category are load-bearing, not cosmetic.** The CronJob's rclone
source is the `media` directory alone. Sharing one save path would make `rclone copy` pull
ratio-only grabs home as well — content whose entire purpose is to seed in place — wasting
home download bandwidth and NFS capacity on data that is never imported.

**One global floor, not per-tracker floors.** Only two trackers are in scope (IPTorrents,
TorrentLeech), so the floor is the stricter of the two requirements applied to both. Splitting
into per-tracker categories doubles the config to buy back ratio only on the more lenient
tracker — do it later if the two requirements turn out to diverge meaningfully, not now.

#### Evict on inactive seeding time only

qBittorrent's three share-limit conditions — ratio, total seeding time, and **inactive**
seeding time — are **concurrent: the action fires as soon as any one is met**
([API reference](https://qbittorrent-api.readthedocs.io/en/latest/apidoc/torrents.html)).
Action is `RemoveWithContent`.

Therefore: **set the inactive-seeding-time limit and leave ratio and total seeding time
unlimited.** Setting a ratio limit would delete a torrent the moment it hit that ratio — which
means deleting the best earners exactly when they are earning. Inactive time evicts dead
weight instead: torrents nobody is pulling from any more, which are precisely the ones
occupying disk without producing upload.

#### The two trackers' actual rules

| | Account-wide | Per-torrent |
|---|---|---|
| **IPTorrents** | ratio above **0.96** (warning below; download **freeze below 0.3**) | none |
| **TorrentLeech** | ratio **0.4** after 6 GB downloaded (warning, 7 days to cure) | **1:1, or seed the user-class minimum time — else Hit & Run** |

IPTorrents is the stricter **account-wide** floor (0.96 covers TL's 0.4). TorrentLeech is the
only source of a **per-torrent** obligation, so it sets the eviction floor.

#### Deriving the safe inactive-time floor

TL's per-torrent obligation is satisfied by ratio ≥ 1:1 **or** by elapsed seed time ≥ the
user-class minimum. The risk with inactive-time eviction is a torrent nobody leeches being
removed at ratio 0.2 before that time elapses — an HnR warning.

Set the **inactive-seeding-time limit ≥ TL's user-class minimum seed time** and that cannot
happen: inactive time only accrues while the torrent is idle, so total elapsed seeding time is
always ≥ inactive time. When the inactive limit fires, the class minimum has necessarily
already passed, and the obligation is met regardless of ratio.

That also restores the single-global-floor simplification: the floor is TL's class minimum,
applied to both trackers. IPT, having no per-torrent rule, is safe under it automatically.

**TL minimum seeding time by user class:**

| Class | Minimum |
|-------|---------|
| Registered | **10 days** |
| Power User | 8 days |
| Super User | 7 days |
| Extreme User | 6 days |
| TL God | 4 days |
| VIP User | none |

**Floor = 10 days** on a new Registered account. Revisit on class promotion — dropping to 4
days at TL God nearly triples effective disk capacity, so this number is worth re-reading
rather than setting once and forgetting.

#### The 10-day floor sets a hard grab-rate ceiling

Every torrent occupies disk for at least 10 days, so steady-state usage is
`grab rate × 10 days`. Against 1500 GB:

**≈150 GB/day sustainable, or ~4.5 TB/month.**

Two things follow. First, that is remarkably close to the plan's 5 TB/month upload allowance —
the two limits are balanced, so neither is obviously the binding one. Second, **autobrr filter
discipline has to bound grab *rate*, not just per-release size.** A per-release size ceiling
alone permits unlimited small grabs, and 1500 GB divided by a 10-day hold fills quietly.

#### Never abandon a partially-downloaded TL torrent

TL's seeding clock **only accrues on fully-downloaded torrents. Partial downloads can only be
satisfied by seeding to 1:1** — there is no time-based escape. So a grab cancelled or removed
mid-download is an HnR liability that no share-limit setting can clear. If a download is
aborted, either let it finish and serve the 10 days, or seed the partial to 1:1.

**Ratio and total-seeding-time limits stay unlimited.** Setting a ratio limit of 1.0 would
satisfy TL and then immediately delete — capping every torrent at the minimum instead of
letting the good ones keep earning. TL only requires 0.4 account-wide; there is no reason to
stop a torrent at 1.0.

#### Prefer freeleech in autobrr's filters

IPTorrents freeleech torrents **count upload but not download**. Filtering autobrr toward
freeleech is the highest-leverage tactic available under an account-wide ratio rule: ratio
rises at zero ratio cost. autobrr has explicit freeleech filter support. This is a filter
configuration, not a code change, but it is the single most effective thing in this design for
the stated goal.

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
- **Trackers:** IPTorrents and TorrentLeech, both configured in autobrr with IRC announce. No
  NickServ registration needed on either; nick-to-account linking done via the channel bot.
- **Seed rules, both trackers:** read off their FAQs. IPT — account ratio above 0.96, freeze
  below 0.3, no per-torrent rule. TL — account ratio 0.4 after 6 GB, plus per-torrent 1:1 or
  the user-class minimum seed time (10 days at Registered). TL sets the eviction floor.

## Open items

- **SFTP auth method.** Key auth is preferred, but with no shell it depends on whether the
  panel offers key upload or `~/.ssh/authorized_keys` is writable over SFTP. If key auth is
  attempted, note that ProFTPD's `mod_sftp` reads `AuthorizedUserKeys` in **RFC4716** format,
  not OpenSSH format (`ssh-keygen -e -m RFC4716` converts) — a common silent failure.
  Fallback is the account password via `rclone obscure`. Either way this changes only the
  sealed secret's contents and the rclone remote definition.
- **The `media` category's completed-downloads path** on the slot — the CronJob source and the
  *arr remote path mapping. Specifically the category's path, not the global save path, per the
  separate-save-paths requirement above.
- **qBittorrent WebUI URL** as exposed by seedit4.me, for the download client config.
- **CronJob interval.** Frequent enough that imports feel prompt, infrequent enough not to
  hammer the SFTP endpoint. Start at 15 minutes, adjust on observed behaviour.
- **Grab-rate budget in autobrr's filters.** The 10-day floor caps sustainable grabs at
  ~150 GB/day; filters must bound rate, not only per-release size. Needs a concrete filter
  configuration, and revisiting whenever the TL user class changes.
- **autobrr IRC announce credentials** for both trackers: tracker passkey/RSS key (autobrr
  builds the `.torrent` URL from it), IRC nick, and the IRC key pasted into autobrr's
  pre-filled invite command. **No NickServ registration was required** — the bot nick alone
  was accepted, and the invite command does the authorization. Adding an indexer
  auto-configures its IRC network and channels. All seedbox-side UI config, outside the repo —
  no GitOps artifacts.

  Two silent-failure modes to check rather than assume: connected-but-not-joined means the
  invite command was refused; joined-but-silent means the nick format lacks a required
  `|autodl`/`|bot` suffix, or `#announce` is gated behind a minimum user class. Verify the
  network shows connected *and* the channel joined, then prove the chain end-to-end with one
  deliberately narrow throwaway filter before trusting it.
- **TorrentLeech in Prowlarr**, if not already present — Prowlarr is the *arr search path and
  is configured independently of autobrr. Indexers must be registered in *both*; autobrr does
  not read Prowlarr's config.
