# Self-hosted Renovate — design

**Date:** 2026-08-06
**Status:** approved, not implemented

## Problem

Renovate has never run against this repo. The repo has a complete `renovate.json` —
`config:recommended`, four custom regex managers covering `app.yaml` chart versions,
`values.yaml` image tags, and the k3s version in `ansible/group_vars/` — but the hosted
Mend app has produced zero PRs and zero issues in the repo's entire history. It never
opened its onboarding PR, which means the GitHub App was never installed on
`n-gibs/homelab`.

Installing the app is two clicks and no infrastructure, so self-hosting is not the only
fix. It is the chosen fix for one reason that outlives the onboarding problem: merging to
`main` in this repo deploys to the cluster via ArgoCD, and the hosted app holds write
access to that repo. Self-hosting keeps the credential and the runner inside the cluster,
and makes run logs directly readable instead of hidden behind a third-party dashboard.

## Approach

Deploy the **official Renovate Helm chart** into `platform/renovate/`. The chart *is* a
CronJob — that is the entire chart. Hand-rolling a CronJob manifest would duplicate it and
lose Renovate's own image-tag tracking, and the repo already prefers an app's official
chart over the default `app-template`.

```
platform/renovate/
  app.yaml      # chart source, parsed by Renovate
  values.yaml   # schedule, image pin, global config, secret ref
```

The platform ApplicationSet globs `platform/*/app.yaml` and hardcodes
`destination.namespace` to the directory basename, so this is discovered automatically and
lands in namespace `renovate`. No bootstrap change, no ApplicationSet edit.

The `renovate` namespace needs no manifest: `bootstrap/root/templates/stack.yaml` sets
`syncOptions: [CreateNamespace=true]`, so ArgoCD creates it on first sync. Note that a
`chartVersion` bump in `app.yaml` requires an **ApplicationSet** refresh, not an
Application refresh, per the repo's existing behaviour.

There is no HTTPRoute and no Homepage annotation — Renovate has no web UI.

### Rejected alternatives

- **Hand-written CronJob manifest.** Strictly more YAML than the official chart, which
  already templates the CronJob, the config file, env, and RBAC.
- **Self-hosted GitHub App.** Short-lived tokens and a bot identity are genuinely better
  security, but cost an app registration, a PEM private key, an installation ID, and a
  second sealed secret. Not worth it for a single-repo single-user homelab.
- **Just install the hosted Mend app.** Rejected per the Problem section — it leaves a
  third party with write access to a repo where merge equals deploy.

## Chart and image

| | Value |
|---|---|
| Chart | `renovate` |
| Chart repo | `https://docs.renovatebot.com/helm-charts` |
| Chart version | `46.251.0` |
| Chart's bundled appVersion | `43.288.0` |
| **Image tag actually used** | **`44.14.3`** |

The image is pinned ahead of the chart's bundled `appVersion` on purpose. Both tags were
verified present in `ghcr.io/renovatebot/renovate` before this was written.

`app.yaml`:

```yaml
chartName: renovate
chartRepo: https://docs.renovatebot.com/helm-charts
chartVersion: 46.251.0
```

This matches the repo's first custom manager (`chartName` / `chartRepo` / `chartVersion`
with a `helm` datasource), so chart bumps land in the existing `helm charts` PR group with
`automerge: false`.

The image override in `values.yaml` overrides **only the tag**:

```yaml
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
image:
  tag: 44.14.3
```

This is deliberate and load-bearing, for two independent reasons.

First, the chart splits the image across `image.registry` (`ghcr.io`) and
`image.repository` (`renovatebot/renovate`). Writing
`repository: ghcr.io/renovatebot/renovate` would produce
`ghcr.io/ghcr.io/renovatebot/renovate`. The chart defaults are already correct, so only the
tag needs overriding.

Second, the tag-only form is what the repo's **first** `values.yaml` matchString matches
(comment → `image:` → `tag:`). The second matchString requires `repository:` immediately
after `image:`; because the chart's own value ordering is `registry`, `repository`, `tag`,
any override that includes `registry` would match *neither* pattern and Renovate would
silently stop tracking its own version — no error, just a dependency that never updates.

Verified by running both `renovate.json` matchStrings against the exact `values.yaml` text
above: the tag-only pattern returns one hit with
`depName=ghcr.io/renovatebot/renovate`, `currentValue=44.14.3`.
**No new custom manager is required.**

Two consequences of the pin, both accepted:

- **Chart and image drift on purpose.** Renovate bumps `chartVersion` and `image.tag`
  independently, in different PR groups. The chart will keep declaring an older
  `appVersion`; that is cosmetic, the pinned tag wins.
- **`44` is a major ahead of the chart's `43`.** The chart only templates env vars, args,
  and the config file, so a Renovate major cannot break the *chart* — it can only break
  Renovate's own config validation. The dry-run first pass (below) catches that before any
  PR is opened.

## Configuration split

Two files, two distinct jobs. Nothing moves between them.

- **`values.yaml` — where to run.** The chart's `renovate.config` is an **inline string**,
  not a YAML map. With `configIsJavaScript: true` it is written into a ConfigMap as
  `config.js`, mounted at `/usr/src/app/config.js`, and pointed at by `RENOVATE_CONFIG_FILE`:

  ```yaml
  renovate:
    configIsJavaScript: true
    config: |
      module.exports = {
        platform: 'github',
        onboarding: false,
        repositories: ['n-gibs/homelab'],
        hostRules: [
          {
            hostType: 'docker',
            matchHost: 'docker.io',
            username: 'nikgibs',
            password: process.env.DOCKER_HUB_TOKEN,
          },
        ],
      };
  ```

  `onboarding: false` is explicit rather than relied upon; a committed `renovate.json`
  already suppresses onboarding, but self-hosted Renovate defaults `onboarding` to true and
  the explicit setting removes any chance of a stray onboarding PR.

  **JavaScript rather than JSON, deliberately.** This is the shape Renovate's own Docker
  Hub documentation uses, and it is what lets credentials stay out of git: the committed
  file holds only `process.env.*` references, while the values come from the sealed secret
  at runtime. The alternative — passing the whole `hostRules` array as a JSON string in
  `RENOVATE_HOST_RULES` — works, but fails *silently*: Renovate's env parser logs a
  malformed array at `debug` level and continues with no host rules at all, leaving a green
  CronJob quietly making anonymous, rate-limited Docker Hub calls. A broken `config.js`, by
  contrast, makes Renovate error and exit, which trips the existing `CronJobJobFailed`
  alert. Loud beats silent.
- **`renovate.json` (repo root) — what to update.** Unchanged. All four custom managers,
  all `packageRules`, the Nextcloud major-version rule, and the `every weekend` schedule
  stay exactly as they are.

## Schedule

**CronJob runs twice daily, at 03:00 and 15:00 (`0 3,15 * * *`). `renovate.json` keeps
`"schedule": ["every weekend"]`.**

Renovate no-ops outside its own schedule, so PR behaviour is unchanged from the current
config's intent. The run cadence is driven entirely by how the existing alerting reads it.

The existing `CronJobNotSucceeding` alert in
`system/monitoring-system/prometheusrule-backups.yaml` fires when a CronJob has not
succeeded in 26 hours, and carries **no label selector** — it applies cluster-wide, to this
CronJob, automatically. That single threshold rules out both obvious schedules:

- **Weekly** breaches 26h every single week and would page forever.
- **Daily** technically works but leaves only two hours of margin. One transient failure —
  a blipped GitHub API call, a slow registry — pages you. For a backup job that is correct.
  For a dependency-update bot whose entire output is reviewed as pull requests, it is noise.

**Twice daily resolves it without touching a single monitoring rule.** A run every 12 hours
means one failure self-heals well inside the window and stays silent, while 26 hours without
success now implies *at least two consecutive failures* — which is a genuinely broken bot
worth waking up for. The alert gets strictly more meaningful, not merely quieter.

The cost is a second run per day against roughly 15 dependencies, which is negligible even
with a cold cache. It also gets you fresh logs within twelve hours instead of twenty-four
when debugging config.

Running daily makes the existing alert correct with **zero edits to the monitoring rules**,
and has the side benefit of producing fresh logs on demand rather than once a week.

Set via the chart's `cronjob.schedule` and `cronjob.timeZone`, the latter
`America/Los_Angeles` to match the repo's existing timezone convention. The chart's own
default is `0 1 * * *`, so this changes both the hour and the cadence.

`CronJobOverdue` (schedule missed by more than an hour) is unaffected by the twice-daily
change — it measures against the next scheduled time, not the interval.

## Cache

**Leave `renovate.persistence.cache.enabled` at the chart default of `false`.**

The chart's values comment recommends a persistent SQLite cache, and that advice is sound
at scale — it spares repeated datasource lookups between runs. It is not worth it here.
This is one small repo with roughly 15 tracked dependencies; the saving is a few seconds
per run against the cost of a PVC. That PVC would also have to be `local-path`, since it
holds SQLite and SQLite over NFS deadlocks — which pins the CronJob to a single node for a
cache that is by definition reconstructible.

The one argument for enabling it is that a cold cache re-queries Docker Hub every run,
which is the same rate limit the host rules below exist to raise. If logs ever show
rate-limit errors *despite* those credentials, enabling the cache is the next lever —
`local-path`, sized small, per the repo's third local-path case (a performance cache, not a
system of record).

## Secrets

One sealed secret, `renovate-env`, in namespace `renovate`, consumed by the chart's
top-level `existingSecret` value. The chart mounts it as `envFrom.secretRef`, so every key
in the secret becomes an environment variable — verified by rendering the chart. Sealed
table-driven per `secrets/README.md` — add the values to
`secrets/.secrets`, add one row to `secrets/registry.tsv`, run `just seal renovate-env`. No
new Justfile recipe.

Registry row (tab-separated, matching the existing column layout):

```
renovate-env    renovate    platform/renovate/renovate-env.yaml    RENOVATE_TOKEN=RENOVATE_TOKEN,DOCKER_HUB_TOKEN=DOCKER_HUB_TOKEN
```

Both are **raw credentials**, not structured config — the structure lives in the committed
`config.js` and reaches the token through `process.env`.

The Docker Hub **username is deliberately not sealed**. It is an identifier, not a secret,
and a sealed secret is unreviewable: config hidden in there can only be answered by
decrypting from the live cluster. Inlining it in `values.yaml` keeps "which Docker Hub
account is this?" a question git can answer. The repo is private, so this exposes nothing.

### `RENOVATE_TOKEN` — fine-grained PAT

A **fine-grained** PAT scoped to `n-gibs/homelab` only.

| Permission | Level | Why |
|---|---|---|
| Contents | Read/write | push update branches |
| Pull requests | Read/write | open and update PRs |
| Issues | Read/write | Dependency Dashboard |
| Metadata | Read | mandatory, auto-granted |

`Workflows` is **not** granted — this repo has no `.github/workflows/`. Grant it only if CI
workflows are added later, otherwise Renovate will fail to push any branch touching them.

A deploy key cannot be used. Deploy keys are SSH credentials for the git transport only;
the GitHub REST API does not accept them, so Renovate could push a branch and would then
fail to open the PR or maintain the Dependency Dashboard issue. (GitHub has no "deploy
token" — that is a GitLab concept, and GitLab deploy tokens have the same limitation.)

A classic `repo`-scoped PAT was considered and rejected: it is valid against every repo the
account can reach, so a leak of the cluster secret would expose the whole GitHub account
rather than one homelab repo.

**Rotation:** fine-grained PATs expire, capped at one year. This needs a calendar reminder.
Expiry presents as Renovate failing with a 401 and the `CronJobJobFailed` alert firing.

### `DOCKER_HUB_TOKEN` — Docker Hub credentials

One raw value, consumed by the `hostRules` entry in `config.js` above alongside the inlined
username `nikgibs`. The token needs only **public repo read-only** scope; Renovate reads
tags, it does not pull images.

`matchHost` is `docker.io`, matching Renovate's own documented Docker Hub example. Note it
is *not* `https://index.docker.io`, which an earlier draft of this spec had wrong.

Justified by measurement, not by default: 6 of the 15 images referenced across
`apps/`, `platform/`, and `system/` `values.yaml` files come from Docker Hub (versus 7
`lscr.io` and 2 `ghcr.io`). Anonymous Docker Hub pulls are rate-limited by the cluster's
egress IP, which would present as intermittently missed updates rather than as a clean
failure.

**Why not `RENOVATE_HOST_RULES`.** Passing the array as a JSON env var does work — verified
against Renovate's source: `hostRules` declares no `env: false`, `getEnvName()` derives the
name by default, and the env parser has an explicit `type === 'array' && subType ===
'object'` branch that `JSON5.parse`s it. But that branch logs at `debug` and continues when
the value fails to parse. It does not throw. A malformed string therefore yields *no host
rules at all* — a green CronJob silently making anonymous, rate-limited calls, defeating
the entire point of the credentials, with nothing in the logs at the default `info` level
to say so. The `config.js` route fails loudly instead, so no special verification tooling
is needed to trust it.

## Resources

Static requests and limits. **No VPA** — a deliberate exception to the repo's
all-apps-get-VPA rule.

```yaml
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1
    memory: 2Gi
```

A job that runs for a few minutes once a day gives VPA almost no signal, and its
recommendation would lag roughly a week behind reality. If this proves wrong, the fix is a
`vpa.yaml` with `updateMode: Initial` — `Recreate` is meaningless for a CronJob, whose pods
are new on every run anyway.

## Failure handling and monitoring

**No new PrometheusRule.** The existing cluster-wide rules already cover this CronJob,
because none of them carry a label selector:

- `CronJobJobFailed` — `kube_job_failed{condition="true"} == 1`. Catches a bad token,
  a config parse error, or an OOM kill.
- `CronJobNotSucceeding` — 26h without success. Correct given the daily schedule above.
- `CronJobOverdue` — schedule missed by more than an hour.
- `CronJobSuspended` — catches a suspend left on after manual debugging.

Renovate's own failure modes are mostly non-fatal by design: a single unreachable
datasource degrades to a skipped update rather than a job failure. Those surface in the pod
logs, not in alerts, which is the accepted trade — the alternative is log-based alerting
for a tool whose entire output is already reviewed as pull requests.

## Verification

Two commits, deliberately.

1. **Dry run.** Ship with `dryRun: 'full'` added to the `config.js` object — it is a
   Renovate config option, not a chart value. Let one scheduled run complete
   (or trigger one with `kubectl create job --from=cronjob/renovate`). Read the pod logs
   and confirm:
   - it authenticates and resolves `n-gibs/homelab`
   - the `helm` custom manager finds the `app.yaml` chart versions
   - the image manager finds the `app-template` image tag added earlier today
   - the k3s `github-releases` manager resolves `ansible/group_vars/k3s_cluster.yml`
   - no config-validation error from running Renovate `44` against this `renovate.json`
   - the Docker Hub host rule took effect. With `config.js` this needs no special
     tooling: a config file that cannot be parsed makes Renovate error and exit, so a
     completed run is itself the evidence. (Under the rejected `RENOVATE_HOST_RULES`
     design this would have required temporarily raising the log level to `debug`, since
     the only signal was a debug-level `Could not parse object array` line.)
2. **Enable.** Remove `dryRun`, merge, and confirm the first real run opens PRs and creates
   the Dependency Dashboard issue.

The full values file was rendered against chart `46.251.0` with `helm template` before this
spec was finalised. It produces `image: "ghcr.io/renovatebot/renovate:44.14.3"`,
`schedule: "0 3 * * *"`, `timeZone: America/Los_Angeles`, `envFrom.secretRef.name:
renovate-env`, and the stated resource block.

Per the repo's GitOps rule, both changes reach the cluster by merging to `main` and letting
ArgoCD sync — no manual `kubectl apply`.

## Out of scope

- Self-hosted GitHub App identity for PRs.
- A dedicated PrometheusRule for Renovate.
- VPA for this workload.
- `GITHUB_COM_TOKEN` for changelog fetching. Add only if release notes come back empty in
  PR bodies; it is a second token with no scopes at all.
- Any change to `renovate.json`.
