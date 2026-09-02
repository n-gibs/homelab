# GitHub Actions CI for the homelab GitOps repo

Date: 2026-09-02
Status: approved, not implemented

## Problem

The repo has no CI. The `main` branch ruleset blocks force-push and deletion but
requires zero status checks, so any change merges unverified and ArgoCD deploys it
on the next sync. Every class of error this repo has hit is mechanically detectable
before merge:

- A duplicate top-level key in `values.yaml` silently ate an ArgoCD-managed
  HTTPRoute. Only `helmfile diff` caught it.
- A `values.yaml` key an upstream chart no longer reads renders to nothing, and
  ArgoCD reports the app healthy.
- Repo conventions in `CLAUDE.md` (namespace equals directory basename, no
  `Ingress`, PVCs must name a storageClass, VPA per app) are enforced only by
  review.

CD is out of scope. ArgoCD owns deployment and stays untouched.

## Goals

Block from `main`: manifests ArgoCD would reject, chart bumps that fail to render,
repo-convention drift, and tracked secrets.

Non-goal: verifying runtime behavior. CI proves a change renders and validates.
It does not prove the container starts. Renovate automerge is explicitly out of
scope for this iteration, so nothing merges without a human.

## Approach

Render only the directories a PR changes, not all forty. A weekly full render
covers the drift this misses.

Rejected alternatives:

- Render all forty dirs on every PR. Simpler, no path-filter logic, catches a
  yanked upstream chart version immediately. Rejected as roughly forty chart
  pulls of waste on a one-line PR.
- Lint and conventions only, no rendering. Cheapest and no network flake, but
  misses the failure that costs an outage. Rendering is the check that would
  have caught the lost HTTPRoute.

## Rendering contract

`scripts/render.sh <dir>` reproduces what the stack ApplicationSet in
`bootstrap/root/templates/stack.yaml` does. Release name and namespace both come
from `path.basename`, and every file in the directory except `app.yaml` and
`values.yaml` is applied as a raw manifest alongside the chart.

    helm template "$(basename "$dir")" "$chartName" \
      --repo "$chartRepo" --version "$chartVersion" \
      -n "$(basename "$dir")" -f "$dir/values.yaml"
    cat "$dir"/*.yaml   # excluding app.yaml and values.yaml

One script with three consumers: the CI gate, the base-versus-head PR diff, and a
local `just render <dir>`. If it drifts from `stack.yaml`, CI validates something
the cluster never runs, so the two are reviewed together.

All chart repos are public, including the two OCI ones
(`ghcr.io/immich-app/immich-charts`, `docker.io/envoyproxy`), so GitHub-hosted
runners suffice. No self-hosted runner.

`system/coredns` has no `app.yaml` by design and is skipped everywhere.
`bootstrap/root` renders from its own chart when `bootstrap/**` changes.

## Workflow: .github/workflows/ci.yml

Triggers: `pull_request`, `push` to `main`, and a weekly Friday `schedule` ahead
of Renovate's weekend run. Concurrency group per ref, cancel in progress.

| Job | Runs on | Does |
|---|---|---|
| `lint` | every PR | yamllint, `renovate-config-validator`, gitleaks; `ansible-lint ansible/site.yml` only when `ansible/**` changed |
| `conventions` | every PR | `scripts/check-conventions.py` |
| `render` | matrix over changed stack dirs from `dorny/paths-filter`, `fail-fast: false` | `render.sh` piped to kubeconform |
| `diff` | pull requests only | renders changed dirs at base and head, posts one sticky `gh pr comment`, full output as an artifact |
| `ci-ok` | always | aggregates every job above into one stable check name |

On a `schedule` event the filter step emits every stack directory instead of the
changed ones, so the weekly run is a full render through the same code path.

### ci-ok

A required status check needs a stable name, and matrix job names vary by
directory, so the ruleset requires `ci-ok` alone.

This job fails open if written naively. It MUST use `if: always()` and compare
each dependency's `result` against both `failure` and `skipped`. A job that never
ran is not a job that passed.

### yamllint

`.yamllint.yaml` sets `key-duplicates` to error. That single rule is the one that
would have caught the lost HTTPRoute. Line length off, truthy relaxed,
`ansible/vault.yml` excluded.

### kubeconform

    -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -ignore-missing-schemas

`-ignore-missing-schemas` is load-bearing and also the weakness: a CRD the
catalog lacks passes silently. Most of what is interesting in this repo is CRDs,
so the stronger half of this job is that `helm template` succeeded at all.

## scripts/check-conventions.py

Python standard library plus PyYAML. Every finding is fatal and reports
`file:line`. Wired to `just check` so it runs identically in CI and locally.

1. Every `{apps,platform,system}/*/` directory has `app.yaml` and `values.yaml`.
2. `app.yaml` carries exactly `chartName`, `chartRepo`, `chartVersion`, and the
   version is concrete, not `latest` and not a range.
3. No `kind: Ingress` anywhere in the repo.
4. Every `kind: PersistentVolumeClaim` names `storageClassName` explicitly. An
   implicit class means `local-path`, which is reserved for CNPG volumes.
5. Any `metadata.namespace` under a stack directory equals that directory's
   basename. Scoped to `metadata.namespace` only; cross-namespace references such
   as an HTTPRoute `parentRefs` pointing at `envoy-gateway-system` are legitimate
   and out of scope for this check.
6. `apps/*/` contains `vpa.yaml`. Skip list, from the exceptions that exist today:
   `jellyfin`, `rclone-seedbox`, `recyclarr`.
7. Nothing matching the gitignore secret list is tracked: `.vault_pass`,
   `pub-cert.pem`, `config/`, `ansible/vault.yml`, `.secrets`, `.secrets.generated`.
   (`ansible/vault.yml.example` is tracked and is fine.)

`scripts/test_check_conventions.py` builds a temporary directory tree and asserts
each check fires and each passes clean. Plain asserts, no framework.

## Branch ruleset

Add to the existing `main` ruleset: require a pull request before merging, and
require the `ci-ok` status check. Force-push and deletion protection stay.

## Out of scope

- Renovate automerge, and therefore any change to `renovate.json`. Dropped
  deliberately: CI green proves a chart renders, not that it runs, and this
  cluster's real failures have all been runtime. Revisit only with a signal
  stronger than schema validation.
- Anything requiring cluster access, including `helmfile diff` against the live
  cluster and `kubectl --dry-run=server`.
- Runtime and post-deploy verification, which is ArgoCD's and Alertmanager's job.

## Known implementation risks

- `-strict` on kubeconform may fail against upstream charts that ship stray keys.
  The fix is either dropping `-strict` or a per-chart exception list that rots.
  Prefer dropping it.
- The datreeio catalog may not cover InfisicalSecret or the Cilium policy CRDs.
  If coverage is thin enough, reconsider whether kubeconform earns its place
  next to a successful render.
- Some of the forty charts may not `helm template` cleanly today, for example if
  a chart demands a required value. Any that does not render is a real finding to
  fix, not a reason to loosen the gate.
- A chart bump's rendered diff can be hundreds of lines of regenerated checksum
  annotations and labels. If the comment proves unreadable in practice, cut the
  `diff` job rather than tuning it.
