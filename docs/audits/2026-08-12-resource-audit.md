# Resource audit — 2026-08-12

Read-only audit of requests, limits, LimitRanges, VPA policy and measured usage.
All measurements taken 2026-08-12 ~08:40 PDT. Windows are stated per measurement.
Nothing was changed.

## Method notes

- Throttling is reported over **3h** for live pods and **24h** for context. The 24h
  numbers include pods that no longer exist (VPA `Recreate` churns them), so a high 24h
  figure against a dead pod is history, not a current symptom.
- Peak memory and peak CPU use **1m** resolution. Treat any sampled peak as a floor.
- Peak CPU is `rate(...[2m])`, which smooths sub-minute bursts — a container can throttle
  hard at a ceiling well above its reported peak. Both infisical and renovate do.
- No LimitRange in this cluster sets a default **CPU limit** (commit `45c55ad` removed the
  last seven). Every CPU limit seen on a live pod therefore comes from the container spec
  or a Helm chart default, not from injection.

## Cluster state

| | worker-00 | worker-01 | worker-02 |
|---|---|---|---|
| allocatable CPU | 4 | 12 | 12 |
| CPU requested | 1.58 | 2.92 | 1.66 |
| allocatable memory | 14.96 GiB | 22.64 GiB | 14.89 GiB |
| memory requested | 6.64 GiB | 12.64 GiB | 7.99 GiB |

Headroom is not a constraint anywhere. **Zero OOM events cluster-wide over 7 days**
(`container_oom_events_total`, corroborated by an empty
`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` and no OOMKilled
`lastState` on any running pod). The rclone-seedbox 1Gi raise from `e3988c8` is holding;
its sampled peak is 239 MiB, which — per the sampling caveat — is a floor, so do not cut
it back.

---

## Real problems

| # | Workload | Symptom (measured) | Layer | Fix | Safe live? |
|---|---|---|---|---|---|
| 1 | `infisical/infisical-standalone` | **18.7% CFS throttle over 3h** on the live pod. Live `requests.cpu=93m`, `limits.cpu=930m`. 2m-averaged peak 0.56 cores. | **VPA ratio trap.** `system/infisical/values.yaml` declares `requests.cpu: 100m` / `limits.cpu: "1"` — 10:1. VPA target 93m drags the ceiling to 930m. | Delete `limits.cpu` from `system/infisical/values.yaml` (keep `limits.memory: 1Gi`). One line. | Yes — `replicaCount: 2`, so the VPA eviction is one pod at a time. It is the secrets source of truth, so schedule it rather than doing it blind. |
| 2 | `renovate/renovate` (CronJob) | **72.4% and 63.8% throttle** on the two runs in the last 24h. | **Genuine demand against a real limit.** CronJobs have no VPA, so `limits.cpu: 1` in `platform/renovate/values.yaml` is the literal ceiling. | Raise to `2`, or drop the CPU limit and keep `requests.cpu: 200m`. One line. | Yes — batch job, no live traffic. Impact today is only run duration, which is why this sits below #1 despite the bigger number. |
| 3 | `sealed-secrets/sealed-secrets-controller` | 2.4% throttle over 3h. Live `requests.cpu=15m`, `limits.cpu=22m`. | **VPA ratio trap via a chart default.** `platform/sealed-secrets/values.yaml` sets no `resources`, so the chart's own ~1.5:1 request:limit pair is what VPA is dividing. A 22m ceiling stalls any decrypt burst. | Add an explicit requests-only `resources` block to the values file (`limits.cpu: null` if the chart needs it explicit). One line. | Yes — single controller, brief unavailability only affects SealedSecret decryption, which is not on any request path. |
| 4 | `alloy/alloy` | 3.3% throttle over 3h. Live `23m`/`230m`; 1m peak 0.224 cores — i.e. it runs *at* its ceiling. | **VPA ratio trap.** `system/alloy/values.yaml` `limits.cpu: "1"`. | Delete `limits.cpu`. One line. | Yes — log shipping, a gap of seconds. |

## Latent — no symptom yet, but wrong by construction

| # | Workload | Observation | Layer | Fix |
|---|---|---|---|---|
| 5 | `immich/immich-valkey`, `infisical/redis-master-0`, `loki/loki-canary` ×3 | **BestEffort QoS — zero requests, zero limits.** Invisible to the scheduler and first evicted under node pressure. valkey and redis hold immich's and infisical's cache/queue state. | Container spec (chart default) plus **no LimitRange** in the `immich`, `infisical` or `loki` namespaces — nothing injects a `defaultRequest` there. | Either add a small `resources.requests` to each chart's values, or add a LimitRange per namespace matching the arrs' (`cpu: 50m`, `memory: 128Mi`). The LimitRange is the smaller diff and covers future requestless containers. |
| 6 | `apps/jellyfin/limitrange.yaml` | `defaultRequest.cpu: 1.5`. Every requestless container in the namespace reserves 1.5 cores for its lifetime. Nothing hits it today — jellyfin declares its own request and `jellyfin-db-backup` declares `10m`. | LimitRange. | Lower to `50m` to match every other namespace. worker-00 has 4 allocatable cores, so one requestless pod landing there takes 37% of the node. Latent, not urgent. |
| 7 | `navidrome/navidrome` | 13.2% throttle over 24h on the *previous* pod, 0.52% on the live one. Live `15m`/`300m` from `requests.cpu: 50m` / `limits.cpu: "1"` (20:1). 1m peak 0.109 cores. | VPA ratio trap. | Drop `limits.cpu`. **This finding rests on a single event** — almost certainly one library scan — and the live pod is not throttling. Fold it into a batch with #4/#8 rather than PRing alone. |
| 8 | `unpackerr/unpackerr` | Live `15m`/`300m` (`limits.cpu: 500m`, 20:1). No throttling measured in 24h. | VPA ratio trap. | Drop `limits.cpu`. Untidy only. |
| 9 | `loki/loki` | 1.9% throttle over 3h. Live `63m`/`630m`, 1m peak 0.239 cores. | VPA ratio trap (`system/loki/values.yaml` `limits.cpu: "1"`). | Drop `limits.cpu`. Low headroom pressure; batch it. |
| 10 | `qbittorrent/qbittorrent` (`app`) | VPA CPU target sits **exactly on `minAllowed: 50m`**; ceiling 500m; 1.8% throttle. 1m peak 0.064 cores on `app`, 0.134 on `gluetun`. | VPA policy floor (trap 4) plus the ratio. | No action. The floor is doing the sizing because the container genuinely idles; measured demand is well under the ceiling. |

## Recommendations sitting on a VPA bound

These are the sizing signal, not findings in themselves:

| Namespace | Container | Target | Bound hit |
|---|---|---|---|
| `flaresolverr` | app | 100m | cpu-at-MIN |
| `homepage` | homepage | 200m | cpu-at-MIN |
| `jellyfin` | app | 1 | cpu-at-MIN (raised deliberately in `0881bf0`) |
| `nextcloud` | nextcloud | 100m / 512Mi | cpu-at-MIN **and** memory-at-MIN |
| `qbittorrent` | app | 50m | cpu-at-MIN |
| `alloy` | config-reloader | 64Mi | memory-at-MIN |

Nothing is at `maxAllowed`. `nextcloud` at both floors means VPA would size it smaller than
the policy allows — the floor is over-reserving, not starving it. Not worth changing:
lowering a floor buys back headroom the cluster does not need, and costs a restart.

## Explicitly not worth a PR

- Over-provisioned memory limits (`infisical` 4.6Gi ×2, `qbittorrent` 8.5Gi, `jellyfin`
  6.1Gi). All are VPA-derived ratios against peaks of 1.7 / 1.3 / 1.3 GiB. Every node has
  headroom, and **memory limits are not symmetric with CPU limits** — a generous memory
  ceiling costs nothing until it is hit, whereas removing one risks a node.
- CNPG clusters (`immich`, `infisical`, `nextcloud`, `vaultwarden`): `100m`/`1–2` cores,
  outside VPA, so these are the literal values. Max throttle observed 0.9%. Correct as-is.
- Backup CronJobs (`*-db-backup`, `nextcloud-cron`): `50m`/`500m`, no throttling of
  consequence. Correct as-is.

## Proposed branches

One logical change each, for human approval:

1. `fix/infisical-cpu-limit` — #1. Highest value; the only finding with a real live symptom.
2. `fix/renovate-cpu-limit` — #2.
3. `fix/sealed-secrets-cpu-limit` — #3.
4. `fix/drop-remaining-vpa-cpu-limits` — #4, #7, #8, #9 together. Same one-line change to
   four values files, same rationale, all low risk.
5. `fix/besteffort-requests` — #5, as LimitRanges for `immich`, `infisical`, `loki`.
6. `fix/jellyfin-limitrange-defaultrequest` — #6.

Every one of these triggers a VPA `Recreate` eviction on a `replicas: 1` workload. That is
a real interruption, not a free tuning knob — merge them one at a time and confirm each
before the next.
