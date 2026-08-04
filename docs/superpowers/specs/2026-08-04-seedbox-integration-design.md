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
                      ┌─────────────────── seedit4.me Sidekick Pro ───────────┐
                      │  qBittorrent (WebUI + API over HTTPS)                 │
                      │  /home/<user>/downloads/complete/                     │
                      └───────▲────────────────────────────────▲──────────────┘
                              │ 1. control: HTTPS API          │ 2. data: SFTP (read-only)
                              │    (outbound from cluster)     │    (outbound from cluster)
        ┌─────────────────────┴────────────────────────────────┴──────────────┐
        │ k3s — worker-01 (homelab.io/media=true)                             │
        │                                                                     │
        │  Radarr ─┐                              apps/rclone-mount           │
        │  Sonarr ─┤ download client #2           rclone mount :sftp          │
        │          │ + remote path mapping   ───▶ hostPath /mnt/rclone-seedbox │
        │          │                              (Bidirectional propagation) │
        │          └──▶ import copy ──▶ /data/media/{tv,movies} (NFS)          │
        │                                                                     │
        │  qBittorrent + gluetun (unchanged) ──▶ public trackers               │
        └─────────────────────────────────────────────────────────────────────┘
```

### Channel 1 — control

Radarr and Sonarr each gain the seedbox qBittorrent as a **second** download client,
pointed at its public WebUI URL over HTTPS with credentials. Plain outbound HTTPS. The
existing local `apps/qbittorrent` behind gluetun is untouched and keeps serving public
trackers.

Prowlarr tags route per indexer: TorrentLeech → seedbox client, public trackers → local
client. Both clients coexist; this is additive.

### Channel 2 — data

`apps/rclone-mount` runs rclone with `mount :sftp,...` against the seedbox's completed
downloads directory, targeting a hostPath on worker-01 with `mountPropagation:
Bidirectional` (requires `privileged: true`). Radarr and Sonarr mount the same hostPath
`HostToContainer` and read-only.

**Remote Path Mapping** in each *arr maps the seedbox's reported path
(`/home/<user>/downloads/complete/...`) to the local mount path, so Radarr can resolve what
qBittorrent tells it. Without this the import fails — qBittorrent reports paths that do not
exist in the *arr container.

Completed Download Handling then works normally: the *arr copies from the mount into
`/data/media/{tv,movies}` on NFS. **That copy is the WAN transfer**, running at home
download speed. The seedbox keeps its own copy and continues seeding.

## Components

| Component | Change | Notes |
|-----------|--------|-------|
| `apps/rclone-mount/{app.yaml,values.yaml,vpa.yaml}` | new | app-template; privileged; `--read-only`; `--vfs-cache-mode=off`; `preStop` fusermount -u; explicit `resources.requests/limits`; liveness probe |
| `apps/rclone-mount/rclone-ssh-key.yaml` | new | sealed secret, SFTP credential |
| `apps/radarr/values.yaml` | modify | add `persistence.seedbox` hostPath mount |
| `apps/sonarr/values.yaml` | modify | add `persistence.seedbox` hostPath mount |
| `secrets/registry.tsv` | modify | one row for the SFTP credential |
| `Justfile` | modify | add `wire-seedbox` |

### Design decisions that differ from the June plan

- **No Terraform, no Ansible.** Tasks 1–2 of the old plan (~600 of 1109 lines) are deleted
  outright — there is no machine to provision or configure.
- **No Tailscale.** Sidekick Pro has no root, so the tailnet path is unavailable. rclone
  connects to the provider's public SFTP host instead of a Tailscale IP.
- **`nodeSelector: homelab.io/media: "true"`**, not the old plan's
  `homelab.io/storage: "true"` — that label does not exist. Do not add a toleration;
  worker-01 has carried no taint since 2026-07-31.
- **Secret sealing goes through `secrets/registry.tsv`**, not a bespoke `seal-*` Justfile
  target. `seal.sh` only does `--from-literal`, but `secrets/.secrets` is sourced by bash, so
  a multi-line key works as `RCLONE_SSH_PRIVATE_KEY="$(cat ~/.ssh/rclone_seedbox)"`. No
  script change needed.
- **VPA `updateMode: "Off"`**, not the old plan's `"Auto"`. VPA evicting the rclone pod tears
  down the FUSE mount, and Radarr/Sonarr holding it `HostToContainer` would see a broken
  directory mid-import. Recommendations only; resize by hand during a quiet window.
  Consequence: since VPA will not set them, `resources.requests/limits` must be written
  explicitly in `values.yaml` per CLAUDE.md, not left to the recommender.
- **Liveness probe required.** A stale FUSE mount does not kill the rclone process — the
  mount hangs while the container stays "up", so nothing restarts it and the *arr see a
  wedged directory indefinitely. The old plan had no health check. Probe by statting the
  mountpoint (an `exec` probe, since there is no HTTP endpoint) so a stale mount recycles the
  pod.
- **`hostPathType: DirectoryOrCreate` on the *arr side too**, not the old plan's `Directory`.
  With `Directory`, Radarr and Sonarr fail to start whenever they are scheduled before
  rclone-mount has created `/mnt/rclone-seedbox` — a fresh worker-01 or a reboot would break
  two working apps for a feature that is only additive. This is a hard requirement: the
  seedbox path must never be able to take down the existing media stack.

### Storage rule compliance

`apps/rclone-mount` uses a hostPath, which is neither a PVC nor `local-path` — it is the
mount target for a remote filesystem, holding no persistent data of its own. Losing
worker-01 loses the mount, not any content. This does not need the CLAUDE.md `local-path`
exception.

## Failure modes

| Failure | Effect | Handling |
|---------|--------|----------|
| Seedbox unreachable | rclone mount stales; *arr imports fail | liveness probe stats the mountpoint and recycles the pod; imports retry on next *arr scan |
| rclone pod evicted/rescheduled | hostPath empties; *arr see empty dir | VPA `updateMode: Off`; pod pinned to worker-01; *arr keep running (`DirectoryOrCreate`) |
| Upload allowance exhausted | seeding stops until billing reset | monitor; upgrade tier if it recurs |
| Import copy interrupted | partial file in library | *arr retry; seedbox copy is authoritative |

## Out of scope

- Migrating public-tracker torrents off the local qBittorrent. It stays as-is.
- Media servers or *arr apps on the seedbox. Sidekick Pro has "No Media Servers"; Jellyfin,
  Radarr, Sonarr, and Prowlarr all stay in-cluster. Exactly one app is needed on the slot.
- Automated cleanup of the seedbox disk after the seed obligation expires. Manual for now;
  1500 GB is ample headroom to revisit later.
- Cross-seeding tooling.

## Verification

1. rclone pod Running; `ls /mnt/rclone-seedbox` on worker-01 lists seedbox content.
2. Radarr and Sonarr each show two healthy download clients.
3. A TorrentLeech grab lands on the seedbox, not the local client.
4. That grab imports into `/data/media/...` and appears in Jellyfin.
5. The torrent keeps seeding on the seedbox after import.
6. A public-tracker grab still routes to the local gluetun client.

## Open items

- **BLOCKING — which plan family does TorrentLeech require?** The Pro cards read "PUBLIC
  TRACKERS / Public Trackers Allowed"; the unmetered NL cards read "No Public Trackers".
  The intended reading is that Pro permits both and NL is private-only, so Pro is a superset.
  Two things make that worth confirming before paying:
  1. Public-tracker-permitted IP ranges see DMCA traffic, which is precisely why private
     trackers blocklist ranges. TL may accept only the private-only NL plans.
  2. The TL invite is the stated reason for choosing this provider over cheaper seedhost. If
     the invite is tied to the NL family, the correct plan is **Sidekick NL at €16.99**, not
     Sidekick Pro at €11.99 — and the metered-vs-unmetered argument above is moot.

  Ask seedit4.me pre-sales which plans the TorrentLeech invite applies to. A €5/month
  difference is not worth guessing at when the tracker access is the whole point.
- **SFTP auth method.** Key auth is preferred, but a no-root shared slot may not allow
  installing `~/.ssh/authorized_keys`. If not, fall back to the account password via
  `rclone obscure`. Resolve during implementation; it changes only the secret's contents and
  the rclone `args`.
- **Exact completed-downloads path** on the slot, needed for the remote path mapping.
  Read it off the box after signup.
- **qBittorrent WebUI URL/port** as exposed by seedit4.me, needed for the download client
  config.
- **`--vfs-cache-mode=off` is a starting point, not a conclusion.** Sequential import copies
  are fine, but *arr media probing seeks, and seeks over SFTP with no cache are expensive.
  If imports are slow or flaky, `--vfs-cache-mode=full` with a bounded `--vfs-cache-max-size`
  is the knob — it needs writable scratch space, so it changes the pod's volumes.
