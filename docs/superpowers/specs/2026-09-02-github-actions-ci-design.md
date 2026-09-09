# GitHub Actions CI and bootstrap/ansible CD for the homelab repo

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

ArgoCD owns deployment for everything under `apps/`, `platform/`, and `system/`,
and stays untouched. Two parts of the repo sit outside it entirely, and today both
are applied by hand from a laptop with no diff and no record:

- `bootstrap/` is applied by `just bootstrap` (`helmfile apply` over Cilium,
  ArgoCD, and the root ApplicationSet).
- `ansible/` is applied by `just provision`.

Those two get a plan-and-apply flow driven from the pull request. Nothing else does.

## Goals

Block from `main`: manifests ArgoCD would reject, chart bumps that fail to render,
repo-convention drift, and tracked secrets.

For `bootstrap/` and `ansible/`: show the diff on the pull request before
anything is applied, make the apply a deliberate labelled action rather than a
merge side effect, and keep the invariant that `main` reflects applied state.

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
`ansible/group_vars/all/vault.yml` excluded.

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
   `pub-cert.pem`, `config/`, `ansible/group_vars/all/vault.yml`, `.secrets`, `.secrets.generated`.
   (`ansible/group_vars/all/vault.yml.example` is tracked and is fine.)

`scripts/test_check_conventions.py` builds a temporary directory tree and asserts
each check fires and each passes clean. Plain asserts, no framework.

## CD for bootstrap and ansible

### Why it is not merge-triggered

The operating rule for this repo is that `main` reflects applied state, so a
change merges only once it is live. A merge-triggered apply inverts that and
opens a window where `main` is ahead of the cluster. Instead the apply runs from
the pull request, and the merge is the last step.

That ordering also matters because of what these two commands do. `just provision`
runs the k3s role against all three servers; the collection restarts k3s on every
run, which is why the recipe is pinned to `--forks=1`. That rolling control-plane
restart is the operation behind two past incidents: the stale Cilium CNI conflist
that let kubelet report Ready on a broken node, and the dangling BPF backends
left by two cilium-agents on one node. `just bootstrap` applies Cilium itself.
Neither belongs on an automatic trigger.

### Workflow: .github/workflows/cd.yml

A separate file from `ci.yml` so cluster credentials live nowhere near the
workflow that runs on every pull request.

| Job | Trigger | Does |
|---|---|---|
| `plan-bootstrap` | PR touching `bootstrap/**`, on every push | Tailscale up, `just bootstrap-diff`, sticky PR comment |
| `plan-ansible` | PR touching `ansible/**`, on every push | Tailscale up, `just dry-run` with `--diff`, sticky PR comment |
| `apply-bootstrap` | `pull_request` `labeled`, label is `apply`, `bootstrap/**` changed | `just bootstrap` against the PR head SHA, result posted as a PR comment |
| `apply-ansible` | `pull_request` `labeled`, label is `apply`, `ansible/**` changed | `just provision` against the PR head SHA, result posted as a PR comment |

Operator flow: read the plan comment, add the `apply` label, watch it land,
confirm cluster health, then merge.

`concurrency: { group: cluster-apply, cancel-in-progress: false }` spans both
apply jobs. A half-applied helmfile or a mid-flight `--forks=1` rolling restart
must never be cancelled, and the two must never race.

Each apply job removes the `apply` label as its final step. The `labeled` event
fires once, so a stale label on a branch that has since been pushed to would
otherwise read as applied when it is not. Re-applying is always an explicit
re-label.

Apply jobs check out `github.event.pull_request.head.sha`, which is what the plan
diffed and what was reviewed. The ruleset requirement that branches be up to date
before merging makes the head SHA and the merge result identical, so what was
applied is exactly what lands on `main`.

No GitHub Environment gate. Adding the label is already the deliberate human
action, and this repo has a single account with write access. An approval prompt
on top of a manual label is a second door on the same doorway.

### Cluster access

The cluster is on `192.168.30.0/24` behind OPNsense, unreachable from a
GitHub-hosted runner, and the actor running `just provision` must not live on a
machine it is about to restart. `tailscale/github-action` joins the runner to the
tailnet as an ephemeral node tagged `tag:ci`; the worker-02 subnet router already
advertises the route. One mechanism for both commands, and being external means a
k3s restart cannot kill the job mid-run.

Rejected: a self-hosted runner on a node. Credentials would stay in the cluster,
but the only spare machines are the three k3s nodes, so `provision` eventually
restarts the node running the job.

Repository secrets:

| Secret | Use |
|---|---|
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` | ephemeral tailnet node, `tag:ci` |
| `SSH_PRIVATE_KEY` | the `homelab` user's ed25519 key, for ansible |
| `ANSIBLE_VAULT_PASSWORD` | written to `.vault_pass` at runtime |
| `KUBECONFIG_B64` | helmfile and kubectl; server must point at a node IP, not `127.0.0.1` |

The tailnet ACL needs `tag:ci` granted the `192.168.30.0/24` route, and the OAuth
client scoped to issue auth keys for that tag.

The repository is public, so pull requests from forks receive no secrets. Every
job in this workflow carries
`if: github.event.pull_request.head.repo.full_name == github.repository` so a
fork PR skips cleanly instead of failing red on missing credentials. Only accounts
with write access can apply the `apply` label.

### Plan jobs stay advisory

Only `ci-ok` is a required status check. A plan job depends on Tailscale and on
the cluster being reachable, and a network hiccup there is not a reason to block
a merge.

### Runner prerequisites

`helm` with the `helm-diff` plugin, `helmfile`, `just`, `kubectl`, `ansible`, and
`just deps` for the Galaxy collections.

## Branch ruleset

Add to the existing `main` ruleset: require a pull request before merging,
require the `ci-ok` status check, and require branches to be up to date before
merging. The last one is load-bearing for CD, not hygiene: it is what makes the
head SHA that was applied identical to the merge result. Force-push and deletion
protection stay.

## Out of scope

- Renovate automerge, and therefore any change to `renovate.json`. Dropped
  deliberately: CI green proves a chart renders, not that it runs, and this
  cluster's real failures have all been runtime. Revisit only with a signal
  stronger than schema validation.
- `kubectl --dry-run=server` in CI. The CI jobs stay credential-free; anything
  needing the cluster lives in `cd.yml`.
- Runtime and post-deploy verification, which is ArgoCD's and Alertmanager's job.
- Mechanically blocking a merge on a successful apply. It would need `ci-ok`
  re-run by hand after every apply, which buys nothing when a single account
  presses merge.
- CD for `apps/`, `platform/`, and `system/`. ArgoCD already owns those.

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
- `ansible-playbook --check` on the k3s role is likely to report failures that
  mean nothing, because check mode skips tasks whose registered results later
  tasks read. If `plan-ansible` proves noisy, scope it to `--tags common` rather
  than treating a red comment as signal.
- `just provision` remains the riskiest action in the repo. The label gate makes
  it deliberate, not safe. The Cilium CNI conflist gate and the dangling BPF
  backend alert are the things to have in view when applying it.
