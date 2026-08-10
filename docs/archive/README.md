# Archived docs

Work that shipped. These are kept for the *why* — the evidence behind a decision, the failure
mode that motivated it, the recovery path if it recurs — not as instructions to follow. Anything
here may describe hardware or config that has since changed; the repo is the source of truth for
current state.

Nothing here is live work. If a doc still has open items, it doesn't belong in this directory.

| Doc | What it records |
|-----|-----------------|
| [`g6-migration.md`](g6-migration.md) | The single-server → 3-node HA control plane conversion (merged 2026-07-08). Explains why all 3 nodes are server+worker and why worker-01 carries a label rather than a taint. |
| [`hdd-running-hot.md`](hdd-running-hot.md) | Root cause of the 12TB WD Elements idling at 56–61C against a 65C ceiling (2026-07-31): the fanless enclosure, not the workload. Backs the temperature alerts in `system/monitoring-system/`. |
| [`hdd-rack-mount.md`](hdd-rack-mount.md) | Execution runbook for shucking that drive and rack-mounting it on a WAVLINK adapter, in three parts-gated stages. |
| [`post-outage-followups.md`](post-outage-followups.md) | The 2026-07-28 DNS outage follow-ups. Five closed: dead-man's switch, CoreDNS HA, alert escalation, worker-00 time sync, inotify exhaustion. **Item 3 (ntfy.sh silently rejecting notifications) was still open when this was archived** — see that section if notifications look healthy but never arrive. |

## Shipped plans and specs

`superpowers/{plans,specs}/` holds the design spec and implementation plan for each feature that
is now live. The checkboxes in these plans were never ticked during execution — ignore them; the
repo is what says whether something shipped.

| Feature | Shipped |
|---------|---------|
| [wire-media manual step](superpowers/plans/2026-07-09-wire-media-manual-step.md) | `just wire-media` |
| [Loki logging](superpowers/plans/2026-07-10-loki-logging.md) | `system/loki`, `system/alloy` |
| [ntfy alerting](superpowers/plans/2026-07-15-ntfy-alerting.md) | `system/monitoring-system` — but see Item 3 above, ntfy delivery has a known open defect |
| [Immich](superpowers/plans/2026-07-27-immich-deployment.md) | `apps/immich` |
| [Nextcloud](superpowers/plans/2026-07-31-nextcloud-deployment.md) | `apps/nextcloud` |
| [Seedbox integration](superpowers/plans/2026-08-04-seedbox-integration.md) | `apps/rclone-seedbox`, `just wire-seedbox` |
| [Self-hosted Renovate](superpowers/plans/2026-08-06-selfhosted-renovate.md) | `platform/renovate` |

Cleanuparr stays in `docs/superpowers/` rather than here: it is deployed, but Tasks 8–10 (the
Malware Blocker, Queue Cleaner and seeding-cleanup phases) are UI config that hasn't been done.
