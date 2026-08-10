# wire-media: keep it manual, tighten docs and reliability

## Context

`just wire-media` is the one manual, human-triggered step in an otherwise fully GitOps repo (`main` branch auto-syncs everything in `apps/`, `platform/`, `system/` via ArgoCD). It port-forwards to Sonarr, Radarr, and Prowlarr and idempotently sets Sonarr/Radarr root folders and wires Prowlarr → Sonarr/Radarr as linked applications.

## Research

Root folders and Prowlarr application links live in each app's own SQLite config, on the NFS-backed `config` PVC. That config persists across pod restarts, redeploys, and node moves — it is not tied to the ArgoCD sync lifecycle at all. It's only lost if the PVC itself is deleted or the NFS share (`192.168.30.194:/mnt/storage`) is lost outright, and the latter is a repo-wide disaster (every app's config lives there) requiring a full restore-from-backup, not something `wire-media` addresses in isolation. So `wire-media` fires once per cluster lifetime (bootstrap), rarely again.

Several alternatives were investigated before settling on "keep it manual":

- **ArgoCD PostSync hook Job**: rejected — hook ordering isn't guaranteed across three separate `apps/` Applications in the same sync wave, so it would still need its own readiness-polling retry loop, plus a maintained image and RBAC, for a task that's an idempotent no-op almost every time it fires.
- **Configarr** (`raydak-labs/configarr`, a Recyclarr fork already YAML+CronJob-shaped like `apps/recyclarr` in this repo): supports declarative `root_folders` for Sonarr/Radarr (experimental, since v1.14.0), but doesn't manage Prowlarr as an instance or support Prowlarr "applications" (indexer sync links) at all — only covers half the problem.
- **DevOpsArr Terraform providers** (`terraform-provider-sonarr`/`-radarr`/`-prowlarr`): has purpose-built resources for exactly this (`prowlarr_application_sonarr`, root-folder resources), the most "correct" declarative fit found — but introduces Terraform into a repo that is currently 100% Ansible + Helm/ArgoCD, with no state-backend story and no answer to "what applies it" that doesn't just re-add a human/CI step.
- **`bjw-s-labs/helm-charts` `app-template`'s `cronjob` controller** (the pattern `apps/recyclarr` already uses): a custom `apps/wire-media` CronJob running the existing idempotent script in-cluster on a schedule was designed in detail and would have worked — no port-forward, no hook-ordering problem, reuses an existing pattern. Set aside below in favor of the simpler option, not because it was flawed.
- **`haijeploeg/arr-helm` (`piratestack` chart)**: a monolithic chart bundling Sonarr/Radarr/Bazarr/Prowlarr/Sabnzbd/Tautulli/Maintainerr into one release. Deployment-only (images, ingress, storage, security context) — no wiring automation, and adopting it means abandoning this repo's per-app `app-template` convention. Not applicable.
- **Community precedent check**: examined `pando85/homelab` (`apps/prowlarr`, `apps/sonarr` — notably also built on `app-template`) and `joryirving/home-ops`, plus TRaSH-Guides and the Servarr wiki. None of them automate Prowlarr application-linking or root-folder setup — every one treats it as a one-time manual UI/API step. Configarr's root-folder support is brand new and experimental; nothing found anywhere covers the Prowlarr-application half. This repo's existing idempotent curl+jq script is already ahead of the community norm (most setups are a one-time UI click-through, not even scripted).

**Conclusion**: there is no established pattern to catch up to, and the task's actual recurrence (once per cluster lifetime) doesn't justify a CronJob, hook, or new tool's ongoing maintenance cost. Keep it manual, and spend the effort tightening what's already there instead.

## Changes

### 1. `Justfile` — `wire-media` recipe: real readiness check

Replace the blind `sleep 4` after starting port-forwards with an explicit wait, before port-forwarding begins:

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s
```

Rationale: `sleep 4` is a fixed guess that races on a slow image pull or crash-looping pod, and on failure produces an opaque curl timeout deep in the helper functions. `kubectl wait` fails fast with a clear "pod never became ready" message, and matches the pattern the repo already requires elsewhere (`CLAUDE.md`: no `sleep`, use `kubectl wait` / `--timeout` / readiness probes). Pod label is `app.kubernetes.io/name=<app>` (confirmed via `kubectl get pods -n sonarr --show-labels`).

Port-forwarding and the existing `ensure_root_folder` / `ensure_prowlarr_app` helper functions are unchanged.

### 2. `README.md` — make the step discoverable

After the "Bootstrapping the Cluster" section, add a short "Post-Bootstrap: Wire Media Apps" note:

> Once `apps/` (wave 3) has synced and Sonarr/Radarr/Prowlarr are healthy in ArgoCD, run `just wire-media` to set root folders and wire Prowlarr → Sonarr/Radarr. This is a one-time step — the config it writes lives in each app's NFS-backed PVC and persists across redeploys — not a recurring operational task.

Placed right where the existing vague pointer ("see `just --list` ... wiring up media apps") already lives, replacing it with something explicit and sequenced.

### 3. `.claude/commands/add-app.md` — don't let a future arr app skip wiring

Add a note under Step 4 (Seal any secrets):

> If this app is part of the arr stack (Sonarr/Radarr/Lidarr/etc.) and needs root folders or Prowlarr wiring, also add it to the `wire-media` recipe in `Justfile` (an `ensure_root_folder` and/or `ensure_prowlarr_app` call, plus the readiness wait).

Add a checklist item at the bottom:

> - [ ] If arr-stack app: added to `wire-media` recipe in `Justfile`

This is the only gap in the "keep it manual" decision: neither `CLAUDE.md` nor `add-app.md` currently mentions the arr-stack wiring convention, so adding e.g. Lidarr later could silently skip it until someone notices root folders are missing in the UI.

## Out of scope

- No new `apps/` directory entry, container image, ArgoCD hook, or RBAC — architecture is unchanged.
- Bazarr → Sonarr/Radarr wiring and Jellyfin library setup remain manual and are unaffected — `wire-media`'s existing end-of-run printout of those manual steps stays as-is.
- No changes to `secrets/README.md` or the `secrets/registry.tsv` pattern — already accurate.

## Testing

- Run `just wire-media` against the live cluster after the `kubectl wait` change; confirm it still succeeds (idempotent no-op path, since root folders/Prowlarr links already exist) and that a deliberately-wrong label/namespace produces a clear `kubectl wait` timeout error rather than a curl failure.
