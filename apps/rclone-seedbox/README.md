# Seedbox

The seedbox is `nl137.seedit4.me` (seedit4.me shared plan, user `seedit4me`). It runs its own
qBittorrent; the cluster's qBittorrent is a separate instance for public trackers. This
directory holds the rclone CronJob that copies completed seedbox downloads to NFS.

Two-category design: private-tracker grabs go to the seedbox (ratio matters), public grabs go
to the in-cluster qBittorrent behind gluetun.

## Routing — per-indexer download client

Nothing routes a grab automatically. Each *arr picks the download client per indexer, and an
indexer left on "Any" falls to the lowest-priority client, which is the local qBittorrent
(priority 1) rather than the seedbox (50). **Every private tracker must be pinned by hand, in
each of Lidarr, Sonarr and Radarr, whenever it is added**: Settings -> Indexers -> the indexer ->
Show Advanced -> Download Client -> Seedbox. Prowlarr does not sync this field, so a `fullSync`
neither sets nor clears it.

An unpinned private tracker seeds on the local client, where `removeCompletedDownloads: true`
removes the torrent after import and the pod is not reliably up. That is a hit-and-run, and
Yu-Scene issued one for two Underoath albums before the mapping was set.

Current state, verified 2026-08-19: IPTorrents, TorrentLeech and YUSCENE pinned to Seedbox in all
three arrs. Knaben, The Pirate Bay, EZTV and YTS deliberately left on Any.

## Seed criteria — one rule per tracker

The indexer's Seed Ratio and Seed Time are not preferences. An *arr writes both into qBittorrent
as a per-torrent share limit, and qBittorrent stops the torrent when the first of them lands. The
fields therefore have to encode that tracker's own hit-and-run rule, and the rules disagree with
each other.

| Tracker | Their requirement | Seed Ratio | Seed Time |
|---|---|---|---|
| YUSCENE | 120h seedtime after completion, regardless of ratio | blank | `7800` (130h) |
| TorrentLeech | per-torrent 1:1 **or** the seedtime for your user class | `1` | `14400` (10 days) |
| IPTorrents | account ratio above 0.96, no per-torrent seedtime stated | blank while under 0.96 | blank |
| seedpool | 10-day seedtime on every release, account ratio 1:1 | blank | `15120` (10.5 days) |

Ratio satisfies TorrentLeech, so a limit of 1 discharges the obligation and stops the torrent.
One that never reaches 1.0 never stops and banks seedtime instead, which is the other half of
their rule. Setting both fields is safe there because either condition satisfies them.

TorrentLeech's seedtime falls with user class: 10 days at Registered, 8 at Power User, 7 at Super
User, 6 at Extreme User, 4 at TL GOD, none for VIP. The 10-day figure above is the Registered
floor, so it holds at any class. The account is VIP as of 2026-08-24, which owes no seedtime at
all, but VIP is a donor perk that lapses, and the obligation returns the day it does.

TorrentLeech also enforces a site-wide ratio of 0.4 once you have downloaded 6GB, separately from
anything per-torrent. Below that floor a ratio limit of 1 is actively harmful: it stops each
torrent at the moment it stops helping, capping the only mechanism that lifts the account back
over the line. Leave both fields blank while the site ratio is underwater, and set the table's
values once it is clear.

IPTorrents polices the account, not the torrent. Their rules state a ratio obligation above
0.96, a system warning below it that lifts once you pass 0.95 again, and a download freeze below
0.3. They state no per-torrent seedtime, so nothing there forces a stop, and the same reasoning
as TorrentLeech applies: while the account sits under its floor a limit of 1 caps the only thing
that lifts it. Set it to 1 once the account is clear, for the reaping.

seedpool is Yu-Scene's shape with a longer clock: 10 days of seedtime on every release,
freeleech included, and no per-torrent ratio requirement at all. Its 1:1 is an account
obligation. Torrents under 10% downloaded are exempt, a torrent 3 days offline is marked
Unsatisfied, and enough Unsatisfieds cut your download slots to one. Fines clear them; so does
finishing the seedtime.

seedpool's freeleech is broad enough to matter for the ratio problem: all individual TV episodes,
all individual anime episodes, all remuxes and all music packs. Upload counts and download does
not, so grabs there raise the site ratio instead of lowering it. The 10-day seedtime still applies
to every one of them.

Yu-Scene accepts no ratio in place of the 120 hours, so a ratio on YUSCENE is a trap: it stops
the torrent short of the obligation and earns the warning it looks like it should prevent. Their
0.7 figure is the demotion floor for your account, unrelated to hit-and-run.

Yu-Scene's enforcement, for the record: seedtime counts only from 100% completion, a pre-warning
PM arrives after 3 days disconnected and a warning after 5, warnings stay active 30 days or until
you seed the warned torrent for 5 days, expired ones remain permanent marks, and 3 active
warnings disable downloads.

Changing a field fixes future grabs only. The limit is written into qBittorrent at grab time, so
torrents already running keep the old one until it is changed by hand in the seedbox WebUI.

`altHUB` is in Prowlarr as well and belongs to none of this: it is a usenet indexer, so it has no
seeding, ratio or hit-and-run rules to encode. It also has no download client, since both clients
in every arr speak torrent, so its grabs failed for want of one. RSS, automatic search and
interactive search are therefore off in all three arrs. Turn them back on once a usenet client
exists; the indexer definition itself stays in place meanwhile.

Current state, verified 2026-08-24, and matching the table: YUSCENE Seed Time 7800 and seedpool
15120 in all three arrs, Sonarr's season-pack fields alongside them; ratio blank on all four
trackers; every private torrent indexer pinned to the Seedbox client.

## The sync job

`values.yaml` is a CronJob, not a Deployment (hence no `vpa.yaml`): every 10 minutes it runs
`rclone copy` from the seedbox's `.../qbittorrent/media` to `/data/downloads/seedbox` on NFS,
pinned to worker-01 (the NFS server) and running as uid/gid 1000 so the *arrs can hardlink the
result. The `ratio` category is deliberately not synced — those torrents exist to seed, not to
import. `concurrencyPolicy: Forbid` plus the `--size-only` comparison are both load-bearing; the
reasons are in the comments next to them. `just sync-seedbox` triggers a run out of band.

## Access

| What | Value |
|------|-------|
| SFTP | `nl137.seedit4.me:2097`, ProFTPD mod_sftp, **no login shell** |
| qBittorrent WebUI (local) | `http://localhost:9148`, plain HTTP, no TLS |
| qBittorrent WebUI (public) | `https://203.nl137.seedit4.me/qbittorrent` — behind nginx basic auth |
| Download path | `/home/seedit4me/torrents/qbittorrent/{media,ratio}` |

`WebUI\LocalHostAuth=false`, so anything running *on* the seedbox connects to port 9148 with no
credentials. Credentials for the public path are `SEEDBOX_QBT_*` in `secrets/.secrets`.

There is no shell on the seedbox, so to read a config file, `rclone cat` it over SFTP from a
throwaway pod using the existing sealed secret:

```bash
kubectl -n rclone-seedbox run qbtconf --rm -i --restart=Never --image=rclone/rclone:1.68.2 \
  --overrides='{"spec":{"containers":[{"name":"x","image":"rclone/rclone:1.68.2",
  "command":["sh","-c","rclone cat seedbox:.config/qBittorrent/qBittorrent.conf"],
  "envFrom":[{"secretRef":{"name":"rclone-seedbox-sftp"}}],
  "env":[{"name":"RCLONE_CONFIG_SEEDBOX_TYPE","value":"sftp"},
         {"name":"RCLONE_CONFIG_SEEDBOX_HOST","value":"nl137.seedit4.me"},
         {"name":"RCLONE_CONFIG_SEEDBOX_PORT","value":"2097"},
         {"name":"RCLONE_CONFIG_SEEDBOX_SHELL_TYPE","value":"none"},
         {"name":"RCLONE_CONFIG_SEEDBOX_DISABLE_HASHCHECK","value":"true"}]}]}}'
```

## Seed reaping — qui

Disk on a shared seedbox is finite, so completed seeds have to be deleted eventually. qBittorrent
5.0.1 (what seedit4.me pins) can't express "ratio AND seeding time" — its three share limits are
OR'd into one global action, and per-category limits need 5.2.0. So reaping is done by
[qui](https://github.com/autobrr/qui) (autobrr's qBittorrent WebUI), installed on the seedbox from
the one-click app list, which evaluates rule conditions natively and gives AND logic plus a
dry-run preview.

qui config:

- Instance URL `http://localhost:9148`, no TLS, no credentials needed.
- **Local Filesystem Access: on.** qui and qBittorrent are the same user on the same host, so
  paths resolve directly. This enables hardlink detection, which is what stops a ratio rule from
  deleting files a cross-seeded torrent is still serving.
- No indexers. qui matches trackers off each torrent's announce URL; indexers stay in Prowlarr.

qui automation rules are state on the seedbox, **outside GitOps**. This file is the source of
truth for what they should be; qui has an API if they ever need to be version-controlled.

### Tracker requirements

Both trackers publish an *overall site* ratio floor. Only TorrentLeech also publishes a
per-torrent rule, and that is the one a deletion rule can actually violate.

**IPTorrents**

- Site ratio must stay above 0.96; below that the account is warned. Warning clears above 0.95.
- Below 0.30 the account is frozen from downloading.
- No published per-torrent hit-and-run rule.

**TorrentLeech** (site ratio rules, plus [the HnR wiki](https://wiki.torrentleech.org/doku.php/hnr))

- Site ratio 0.4 minimum after 6GB downloaded; 7 days to recover from a warning.
- Per-torrent minimum is **1:1**, satisfied *either* by ratio *or* by seeding for the user-class
  minimum time. FreeLeech is not exempt — the download doesn't count against ratio, but the
  seed-back obligation is identical.
- Seeding time only accrues on *fully* downloaded torrents. Anything **>=10% downloaded** that
  stops before 1:1 lands on the HnR list, and a partial can only be cleared by seeding to 1:1.

| User class | Minimum seeding time |
|------------|---------------------|
| Registered | 10 days |
| Power User | 8 days |
| Super User | 7 days |
| Extreme User | 6 days |
| TL God | 4 days |
| VIP User | none |

We are **Registered** (account created 2026-08-05), so 10 days. Bump the threshold down if we get
promoted; the class is on the profile page.

Two things from the wiki that shape the rules:

- **The tracker's ratio counts, not the client's, and the tracker lags ~30 minutes.** The wiki's
  own advice is to pause a torrent and wait 60 minutes before removing it. qui only ever sees
  client-side numbers, so the thresholds below carry a deliberate margin rather than firing at
  exactly 1.0 / exactly 10 days.
- **A single HnR is a *reminder*, not a warning.** It takes 50 concurrent reminders held for 5
  straight days to earn an account warning, warnings expire after a month of good behaviour, and 3
  of them disable the account. Reminders also clear by resuming the torrent, or by spending TL
  Points / Surplus Upload Credit (ratio above 1.0). So a handful of mistakes is survivable — this
  is a system to stay well clear of, not a tripwire.

The snatchlist tab on the profile shows per-torrent seeded time and ratio; the HnR tab shows what's
outstanding. Those are the ground truth if a rule ever looks wrong.

### Workflows

One workflow per tracker. Scope the tracker with the workflow's own tracker-pattern field (suffix
form, `.torrentleech.org`) rather than a condition — qui matches tracker patterns outside the
query builder.

**`tl-reap`** — tracker `.torrentleech.org`, action **Remove files but preserve if cross-seeds
detected** (`deleteWithFilesPreserveCrossSeeds`):

```
Uploaded / Size >= 1.05
  OR
( Progress = 100  AND  Seeding Time >= 950400 )
```

The OR mirrors the tracker rule exactly: 1:1 satisfies the per-torrent minimum, otherwise the
user-class seed time does. `Progress = 100` is required because TL only accrues seeding time on
fully downloaded torrents — a partial has to reach 1:1 no matter how long it sat there, and without
this guard the time branch would delete partials straight onto the HnR list.

The thresholds are 1.05 and 11 days, not 1.0 and 10 days, because qui reads client stats while TL
judges on tracker stats that lag ~30 minutes. The 5% and 1-day margins absorb that skew. Don't
trim them to look tidy — that margin is the whole reason this is safe to run unattended.

**`ipt-reap`** — tracker `.iptorrents.com`, same action:

```
Uploaded / Size >= 1.05  AND  Seeding Time >= 259200
```

Plain AND, because IPT publishes no per-torrent minimum — only the site-wide 0.96 floor. The
3-day term is swarm-health courtesy, not a requirement.

Two details that matter:

- **`Uploaded / Size`, not `Ratio`.** The docs call this out explicitly: `Ratio` is distorted on
  cross-seeded torrents, where uploads from one copy inflate another's ratio. TL's 1:1 is measured
  against torrent size, so `Uploaded / Size` is both the safer and the literally correct field.
- **Duration fields are in seconds.** 11 days = `950400`, 3 days = `259200`. If the input offers
  units, use them; if it's a bare number, it's seconds.

`deleteWithFilesPreserveCrossSeeds` over plain `deleteWithFiles`: if a release is cross-seeded, the
torrent is removed but the files stay so the other copy keeps seeding. Requires Local Filesystem
Access to be on.

### Supporting workflows

**`unreg-reap`** — tracker `*`, condition `Is Unregistered is true`, action **Delete (keep files)**.

Torrents the tracker has deleted. They seed to nobody forever and earn nothing, so there is no
obligation to preserve them. Keep-files rather than remove-with-files on purpose: "unregistered"
can be a transient announce error, so a false positive should cost nothing. The orphan scan
reclaims the disk on its next pass — that pairing is why keeping files here is not a leak.

**`freespace-guard`** — tracker `*`, condition `Free Space < <threshold>` AND `State is completed`,
action **Remove files but preserve if cross-seeds detected**. Must be **last in sort order.**

This is the emergency valve that stops a full disk from wedging every download on a fixed
shared-plan quota. It is also the one workflow here that **deliberately ignores tracker
obligations** — with tracker `*` it will delete TL torrents short of 1:1 and short of 10 days,
which is by definition a hit-and-run. That is an accepted trade, not an oversight:

- Last in sort order matters because delete is first-match-wins, so `tl-reap` and `ipt-reap` get
  every torrent they are entitled to before this rule sees it.
- Set the threshold low enough that it fires only in a genuine emergency. If it runs routinely,
  the real problem is grabbing more than the plan can seed back, and the fix is upstream in
  Sonarr/Radarr, not here.
- The HnR cost is survivable by design: reminders only become an account warning at 50 held for 5
  consecutive days, and they clear by resuming or by spending TL Points / surplus credit.

Docs caveat: if only cross-seeded torrents match, this can remove many torrents while freeing zero
bytes, because preserved files don't count toward the space projection.

**`Has Missing Files`** is worth knowing about but not worth a workflow yet. It flags completed
torrents whose files have vanished from disk. Since rclone *copies* rather than moves, files
disappearing on the seedbox means something genuinely broke, so it makes a decent canary. Needs
Local Filesystem Access.

Not used, and why: speed limits (no contention on a seedbox), category and move actions
(seedit4.me already sorts into `media`/`ratio`), external programs, and qui's own notifications —
anything worth paging about should go through the cluster's Alertmanager instead.

### Building them

Automations live per-instance — open the seedbox instance, go to its Automations section, and
create a new workflow. Do `tl-reap` first, since its OR group is the fiddly one.

1. **Name** it `tl-reap`. Leave the interval at the 15-minute default: the background service
   scans every 20s but honours per-workflow intervals, and nothing here is time-critical.
2. **Tracker pattern**: `.torrentleech.org`. The leading dot is the documented *suffix* form, so it
   covers the bare domain and any subdomain (`tracker.torrentleech.org`). No regex, no wildcards.
3. **Conditions.** The query builder nests AND/OR groups, and rows can be dragged to reorder. The
   target shape is an outer **OR** with two children, the second being an inner **AND**:

   ```
   OR
   ├── Uploaded / Size  >=  1.05
   └── AND
       ├── Progress      =   100
       └── Seeding Time  >=  950400
   ```

   Each row is `IF | field | operator | value`. Leave the `IF / IF NOT` toggle on `IF` throughout —
   nothing here is negated. Ignore the `.*` regex toggle; every condition is numeric.
4. **Action**: Delete → *Remove files but preserve if cross-seeds detected*. Delete is a
   **standalone action** — qui won't let it combine with tags or share limits, so this workflow
   does nothing else.
5. Watch the **live impact preview** as you build. It shows the impacted count plus a sample of
   matching torrents and updates on every edit — if it lights up with more than you expect while
   the conditions are half-finished, that is the preview being correct about an incomplete rule,
   not a bug.
6. **Dry-run now** from the workflow dialog before enabling. Results go to the activity log
   (Automations section, 7-day retention). A dry run matching nothing logs a `dry_run_no_match`
   row — so silence means it never fired, not that it passed.
7. Enable it. Then repeat for `ipt-reap`: tracker `.iptorrents.com`, a plain AND of the two
   conditions, same action. Then `unreg-reap`, and `freespace-guard` last of all.

`Apply Now` runs a workflow immediately and bypasses the interval check — useful once, but on a
delete workflow it is live, not a simulation. Dry-run first, always.

Ordering: workflows evaluate in sort order and **first match wins for delete**, so the two reapers
can't fight; their tracker patterns are disjoint anyway. Same torrent won't be re-processed within
2 minutes (debounce), which is why a dry-run immediately followed by another can look inert.
