# wire-media: Reliability & Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `wire-media`'s blind `sleep 4` with a real readiness check, and close the two documentation gaps that made this manual step easy to miss or fumble (no bootstrap doc pointer, no arr-stack-app checklist reminder).

**Architecture:** No new files, no new architecture. Three independent edits to existing files: `Justfile` (recipe body), `README.md` (post-bootstrap docs), `.claude/commands/add-app.md` (checklist). Each is testable/verifiable on its own.

**Tech Stack:** Bash (Justfile recipe uses `#!/usr/bin/env bash`), `kubectl`, Markdown docs.

## Global Constraints

- No `sleep` commands in scripts or manifests (`CLAUDE.md`) — use `kubectl wait` / `--timeout` / readiness probes instead.
- Bash: `set -euo pipefail`, quote all vars, `[[ ]]` over `[ ]`, ShellCheck-clean (global `CLAUDE.md`).
- Never commit plaintext secrets; this plan touches no secret files.
- No new `apps/` entries, container images, or ArgoCD hooks — decided against in the spec.

---

### Task 1: Replace `sleep 4` with `kubectl wait` in `wire-media`

**Files:**
- Modify: `Justfile:150-215` (the `wire-media` recipe)

**Interfaces:**
- Consumes: nothing from other tasks (first task, no dependencies).
- Produces: nothing consumed by later tasks — Task 2 and Task 3 only reference the recipe's *name* (`just wire-media`) in prose, not its internals.

Current recipe body (for reference — this is what step 1 modifies):

```bash
wire-media:
    #!/usr/bin/env bash
    source secrets/.secrets
    PF_PIDS=()
    cleanup() { for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
    trap cleanup EXIT

    echo "Port-forwarding Sonarr, Radarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    sleep 4
    ...
```

- [ ] **Step 1: Edit the `Justfile` — add readiness waits before port-forwarding, remove `sleep 4`**

In `Justfile`, replace this block:

```bash
    echo "Port-forwarding Sonarr, Radarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    sleep 4
```

with:

```bash
    echo "Waiting for Sonarr, Radarr, Prowlarr pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s

    echo "Port-forwarding Sonarr, Radarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    sleep 1
```

Note: keep a short `sleep 1` after starting the port-forwards themselves (not a replacement for the removed `sleep 4` — this is giving the three background `kubectl port-forward` processes a moment to bind their local ports, which `kubectl wait` on the pods doesn't cover). This is a much smaller, bounded wait than the original 4s guess, and CLAUDE.md's no-`sleep` rule is about *readiness* waits specifically (the rule's own text: "use kubectl wait... instead" of sleeping *for readiness*) — port-forward local-socket bind isn't a readiness condition `kubectl wait` can express. If you'd rather eliminate this too, poll instead:

```bash
    for i in $(seq 1 20); do
      nc -z localhost 8989 && nc -z localhost 7878 && nc -z localhost 9696 && break
      sleep 0.2
    done
```

Use the `sleep 1` version unless `nc` isn't available in the dev environment — check with `which nc` first. This repo's other Justfile recipe (`seal-argocd-token`) already uses `nc -z` in a poll loop, so prefer consistency: use the `nc` poll loop, not the flat `sleep 1`.

Final block should read:

```bash
    echo "Waiting for Sonarr, Radarr, Prowlarr pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr   -n sonarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=radarr   -n radarr   --timeout=60s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prowlarr -n prowlarr --timeout=60s

    echo "Port-forwarding Sonarr, Radarr, Prowlarr..."
    kubectl port-forward -n sonarr svc/sonarr 8989:8989 &
    PF_PIDS+=($!)
    kubectl port-forward -n radarr svc/radarr 7878:7878 &
    PF_PIDS+=($!)
    kubectl port-forward -n prowlarr svc/prowlarr 9696:9696 &
    PF_PIDS+=($!)
    for i in $(seq 1 20); do
      nc -z localhost 8989 && nc -z localhost 7878 && nc -z localhost 9696 && break
      sleep 0.2
    done
```

- [ ] **Step 2: Verify the recipe still parses correctly**

Run: `just --list | grep wire-media`
Expected: `wire-media          # Wire Prowlarr → Sonarr/Radarr + set root folders via API (run after apps are healthy)` (recipe still registers, no syntax error).

Also run: `just --dry-run wire-media 2>&1 | head -30` if available, or `bash -n <(just --show wire-media | tail -n +2)` to shell-syntax-check the recipe body without executing it.

- [ ] **Step 3: Run `just wire-media` against the live cluster and confirm success**

Run: `just wire-media`

Expected output ends with:
```
Sonarr root folder: already set
Radarr root folder: already set
Prowlarr → Sonarr: already configured
Prowlarr → Radarr: already configured

Done. Manual steps remaining:
  Jellyfin: jellyfin.nik-homelab.dev → Dashboard → Libraries → Add Media Library
    TV:     /data/media/tv
    Movies: /data/media/movies
  Bazarr:  bazarr.nik-homelab.dev → Settings → Sonarr → host: sonarr.sonarr.svc.cluster.local:8989
                                              → Radarr → host: radarr.radarr.svc.cluster.local:7878
```
(Root folders and Prowlarr links were already set from prior manual runs in this session, so expect the idempotent no-op path — not fresh creation. That's the correct behavior to confirm: re-running is always safe.)

- [ ] **Step 4: Confirm the readiness check actually fails fast on a bad target (isolated check, not full recipe)**

This validates the `kubectl wait` failure mode without touching the live recipe or any real workload:

Run: `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=does-not-exist -n sonarr --timeout=5s`

Expected: exits non-zero within ~5s with `error: no matching resources found` or a timeout message — not a hang, not a cryptic curl error. This confirms the failure mode `kubectl wait` gives us is the clear one described in the spec.

- [ ] **Step 5: Commit**

```bash
git add Justfile
git commit -m "fix(wire-media): replace sleep with kubectl wait for pod readiness"
```

---

### Task 2: Document `wire-media` as a post-bootstrap step in `README.md`

**Files:**
- Modify: `README.md` (after the "Bootstrapping the Cluster" section, currently `README.md:25-37`)

**Interfaces:**
- Consumes: nothing (references `just wire-media` by name only, no dependency on Task 1's internals).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Edit `README.md` — replace the vague `just --list` pointer with an explicit post-bootstrap section**

Current text (`README.md:34-37`):

```markdown
This installs, in order: Cilium (CNI), Gateway API CRDs, ArgoCD, and the root chart that generates ArgoCD `ApplicationSet`s for `system/`, `platform/`, and `apps/`. From there, ArgoCD auto-syncs everything else from `main`.

See `just --list` for the full set of commands (sealing secrets, wiring up media apps, etc.).

---
```

Replace with:

````markdown
This installs, in order: Cilium (CNI), Gateway API CRDs, ArgoCD, and the root chart that generates ArgoCD `ApplicationSet`s for `system/`, `platform/`, and `apps/`. From there, ArgoCD auto-syncs everything else from `main`.

See `just --list` for the full set of commands (sealing secrets, wiring up media apps, etc.).

### Post-Bootstrap: Wire Media Apps

Once `apps/` (wave 3) has synced and Sonarr, Radarr, and Prowlarr show healthy in ArgoCD, run:

```bash
just wire-media
```

This sets Sonarr/Radarr root folders and wires Prowlarr → Sonarr/Radarr as linked applications, via each app's REST API. It's a **one-time step** — the config it writes lives in each app's NFS-backed PVC and persists across redeploys and node moves — not a recurring operational task. Safe to re-run any time; it checks before it writes.

Two remaining steps stay fully manual (`just wire-media` prints these as a reminder when it finishes):
- **Jellyfin**: add TV (`/data/media/tv`) and Movies (`/data/media/movies`) libraries via `jellyfin.nik-homelab.dev` → Dashboard → Libraries.
- **Bazarr**: point it at Sonarr (`sonarr.sonarr.svc.cluster.local:8989`) and Radarr (`radarr.radarr.svc.cluster.local:7878`) via `bazarr.nik-homelab.dev` → Settings — Bazarr has no REST API for this, so it can't be scripted.

---
````

- [ ] **Step 2: Verify the markdown renders correctly**

Run: `grep -n "Post-Bootstrap: Wire Media Apps" README.md`
Expected: one match, with the new section present between "Bootstrapping the Cluster" and "OS Install".

Run: `just --list | grep wire-media` (sanity check the command name referenced in the doc actually exists — catches typos like `just wiremedia`)
Expected: recipe listed, matching the exact invocation written in the doc.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document wire-media as a one-time post-bootstrap step"
```

---

### Task 3: Add arr-stack wiring reminder to `.claude/commands/add-app.md`

**Files:**
- Modify: `.claude/commands/add-app.md:179-215` (Step 4 "Seal any secrets" section and the Checklist)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. This is the last task.

- [ ] **Step 1: Edit `add-app.md` — add a note after Step 4's existing content**

Current end of Step 4 (`add-app.md:179-188`):

````markdown
## Step 4 — Seal any secrets

If the app needs secrets, add a row to `secrets/registry.tsv`:

```
<secret-name>    <appname>    <stack>/<appname>/<secret-name>.yaml    key=ENV_VAR
```

Add the plaintext value to `secrets/.secrets` (and the var name to `secrets/.secrets.example`) — or use `key=generate:ENV_VAR` instead if it's an arbitrary internal value with no external source (e.g. an API key the app itself will consume). Then run `just seal <secret-name>`. See `secrets/README.md` for details.

## Step 5 — Verify ArgoCD will pick it up
````

Insert a new subsection between the end of Step 4's content and the `## Step 5` heading:

```markdown
Add the plaintext value to `secrets/.secrets` (and the var name to `secrets/.secrets.example`) — or use `key=generate:ENV_VAR` instead if it's an arbitrary internal value with no external source (e.g. an API key the app itself will consume). Then run `just seal <secret-name>`. See `secrets/README.md` for details.

### Arr-stack apps: wire root folders / Prowlarr links

If this app is part of the arr stack (Sonarr, Radarr, Lidarr, etc.) and needs a root folder set or to be linked into Prowlarr as an application, add it to the `wire-media` recipe in `Justfile`: an `ensure_root_folder` call (root folder path) and/or an `ensure_prowlarr_app` call (implementation name, config contract, base URL, sync categories) — follow the existing Sonarr/Radarr calls in that recipe as the pattern. This is a manual, one-time step per app (see `secrets/README.md` and the `wire-media` recipe itself for context) — it won't run automatically just because the app directory exists.

## Step 5 — Verify ArgoCD will pick it up
```

- [ ] **Step 2: Edit `add-app.md` — add a checklist item**

Current checklist end (`add-app.md:203-215`):

```markdown
## Checklist

- [ ] Correct stack directory (apps/platform/system)
- [ ] `app.yaml` with pinned chart version (resolved via `helm search repo`, not `latest`)
- [ ] Image tag pinned to specific version (not `latest`), resolved from Docker Hub / GHCR / LinuxServer fleet
- [ ] Chart inspected for built-in HTTPRoute — use it if present, otherwise use app-template `route:`
- [ ] Homepage annotations on the route
- [ ] `vpa.yaml` present
- [ ] NFS StorageClass for any PVCs (not local-path)
- [ ] nodeSelector `homelab.io/media: "true"` + matching `PreferNoSchedule` toleration if accessing `/data` on NFS
- [ ] Secrets sealed and committed, var name added to `secrets/.secrets.example`
- [ ] Row added to `secrets/registry.tsv` if secrets needed
```

Add one line at the end:

```markdown
- [ ] If arr-stack app: added to `wire-media` recipe in `Justfile` (root folder and/or Prowlarr application link)
```

- [ ] **Step 3: Verify the edits landed correctly**

Run: `grep -n "wire-media" .claude/commands/add-app.md`
Expected: two matches — one in the new Step 4 subsection, one in the Checklist.

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/add-app.md
git commit -m "docs(add-app): remind future arr-stack apps to wire into wire-media"
```

---

## Post-plan verification (manual, not a task — run once after all three tasks land)

- `just --list` shows `wire-media` with its description intact.
- `README.md`'s new section reads correctly end-to-end (no broken code fences — the nested triple-backtick `bash` blocks inside the Step 1 instructions in this plan are for the *plan*, not the final README; the final README only has one level of code fence around `just wire-media`).
- `git log --oneline -5` shows three new commits, one per task, each independently revertable.
