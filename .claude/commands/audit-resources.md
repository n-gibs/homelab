# Audit Resources

Audit CPU/memory requests, limits, LimitRanges, VPA policy and actual usage across the
cluster. Produce a report. Do not change anything.

## Goal

Find workloads that are throttled, OOMKilled, starved by the scheduler, or wildly
over-provisioned — and say which of the four layers is responsible. The layers interact,
and the answer is usually not the one written in `values.yaml`.

## Read this before you start — the traps in this cluster

**1. The number in git is not the number on the pod.** VPA runs `updateMode: Recreate` on
most apps, so it rewrites requests at admission. Always compare three things: what
`values.yaml` says, what `helm template` renders, and what `kubectl get pod -o
jsonpath='{.spec.containers[*].resources}'` actually shows. A finding based only on the
first is not a finding.

**2. VPA preserves the request:limit ratio.** This is the single biggest source of
throttling here. If a container declares `requests.cpu: 250m` and `limits.cpu: 4`, VPA
keeps the 16:1 ratio — so when it recommends a *lower* request, the limit falls with it. A
100m recommendation yields a 1600m ceiling. The app is throttled by a limit nobody wrote.
The fix is removing the CPU limit, not raising it; raising it just scales the same ratio.
Confirmed on bazarr, flaresolverr, nextcloud and jellyfin. See
`apps/jellyfin/limitrange.yaml` for the write-up.

**3. LimitRanges inject what containers omit.** `default` supplies limits and
`defaultRequest` supplies requests for containers that declare none. Several namespaces
here deliberately set a memory default and **no** CPU default, for the reason above. Check
whether a container's limit came from its own spec or was injected — they look identical on
the pod.

**4. `minAllowed` is a floor that bursty workloads sit on.** VPA sizes on typical usage.
Something that idles for hours then wants several cores (transcoding, imports, backups)
gets a recommendation at the floor, so the scheduler reserves almost nothing for the burst.
Look for pods whose request equals their VPA `minAllowed` exactly — that is the tell.

**5. Requestless containers are invisible to the scheduler.** They contribute nothing to
node allocation and are first to be killed under pressure. This is what overloaded
worker-00 previously.

**6. Not everything has a VPA.** CronJobs, CNPG instances and Jobs are typically outside
VPA, so their manifest values are the live values. `apps/rclone-seedbox` had no VPA and no
LimitRange, so its 512Mi was real — and it OOMKilled on a large transfer.

**7. CPU limits and memory limits are not symmetric.** CPU is compressible: a limit causes
throttling, and removing it is usually right. Memory is not: removing a memory limit risks
an unbounded heap taking down a node. Do not recommend dropping memory limits by analogy.

**8. `local-path` volumes pin a pod to one node.** A resource recommendation that assumes
the pod can move is wrong for those. Check the PVC's StorageClass before suggesting a pod
be rescheduled.

**9. Acting on a recommendation costs a restart.** VPA `updateMode: Recreate` evicts the pod
to resize it, and most apps here are `replicas: 1` with `strategy: Recreate`. For a SQLite
app or a password manager that is a real interruption, not a free tuning knob. Say so when
recommending a change to `minAllowed`/`maxAllowed`.

**10. QoS class decides who dies first under node pressure.** BestEffort is evicted before
Burstable, and Guaranteed needs request == limit on both resources. A workload you are
"fixing" by removing its CPU limit moves from Guaranteed to Burstable. Report
`status.qosClass` where it matters.

**11. initContainers count differently.** Scheduling uses the max of any single
initContainer against the sum of the regular containers, so an oversized init request
reserves capacity for the pod's whole life. Multi-container pods (gluetun + qbittorrent)
need per-container attribution, not a pod total.

## Gathering data

Cluster facts you will need: kube-prometheus-stack, Prometheus at
`monitoring-system-kube-pro-prometheus:9090` in namespace `monitoring-system`, all
PodMonitor/ServiceMonitor/rule selectors are `{}` (everything is discovered).

Query Prometheus from a throwaway pod — there is no port-forward in a non-interactive
session and several app containers have no `curl`:

```bash
kubectl -n monitoring-system run q --rm -i --restart=Never --image=busybox:1.38.0 \
  --command -- sh -c 'wget -qO- --post-data="query=<PROMQL>" \
  http://monitoring-system-kube-pro-prometheus:9090/api/v1/query'
```

Useful queries:

```promql
# CPU throttling by namespace over 24h — anything above ~5% deserves a look
100 * sum by (namespace) (increase(container_cpu_cfs_throttled_periods_total[24h]))
    / sum by (namespace) (increase(container_cpu_cfs_periods_total[24h]))

# Peak CPU vs request — pinned at the limit means it wants more
max_over_time(sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))[24h:5m])
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})

# Peak memory vs limit. Use 1m resolution, not 5m -- see "Sampling understates peaks".
max_over_time(sum by (namespace) (container_memory_working_set_bytes{container!=""})[24h:1m])
sum by (namespace) (kube_pod_container_resource_limits{resource="memory"})

# OOMKills. container_oom_events_total is a real counter; do NOT use increase() on
# kube_pod_container_status_terminated_reason -- it is a gauge and Prometheus will warn.
# Both of these vanish when the pod is deleted, so check them BEFORE cleaning up failed
# pods, and cross-check with `kubectl get pods -A | grep OOMKilled`.
sum by (namespace, pod) (increase(container_oom_events_total[7d])) > 0
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0

# Containers with no CPU request at all. Expect this to be empty: most namespaces have a
# LimitRange with defaultRequest, so a request is injected even when the spec omits one.
# Empty here does NOT mean every container is sized deliberately — check whether the
# request came from the container spec or from the LimitRange default.
count by (namespace) (kube_pod_container_info)
  unless count by (namespace) (kube_pod_container_resource_requests{resource="cpu"})

# Node allocation headroom
sum by (node) (kube_pod_container_resource_requests{resource="cpu"})
sum by (node) (kube_pod_container_resource_limits{resource="memory"})
```

Also collect, per namespace: the VPA object's `minAllowed`/`maxAllowed` and current
`status.recommendation`, the LimitRange, the container spec in `values.yaml`, and the live
pod resources.

A recommendation sitting exactly on a bound is the signal to look for — on `minAllowed` it
means VPA wanted less and the floor is doing the sizing; on `maxAllowed` it means VPA wanted
more and is being capped. Five workloads were on their CPU floor when this was written:

```bash
kubectl get vpa -A -o json | python3 -c "
import json,sys
for v in json.load(sys.stdin)['items']:
    p=(v.get('spec',{}).get('resourcePolicy',{}).get('containerPolicies') or [{}])[0]
    mn,mx=p.get('minAllowed',{}),p.get('maxAllowed',{})
    for r in ((v.get('status',{}).get('recommendation') or {}).get('containerRecommendations') or []):
        t=r.get('target',{}); flags=[]
        for res in ('cpu','memory'):
            if mn.get(res) and str(t.get(res))==str(mn[res]): flags.append(res+'-at-MIN')
            if mx.get(res) and str(t.get(res))==str(mx[res]): flags.append(res+'-at-MAX')
        if flags: print(v['metadata']['namespace'], r.get('containerName'), t, flags)
"
```

## Sampling understates peaks

Do not lower a limit on the strength of a sampled peak. `container_memory_working_set_bytes`
is scraped periodically, so a short burst falls between samples. Measured on
`rclone-seedbox`, whose pods run about ten seconds every ten minutes:

| method | reported peak |
|---|---|
| `max_over_time(...[24h:5m])` | 31 MiB |
| `max_over_time(...[24h:1m])` | 239 MiB |
| ground truth (it OOMKilled at a 512Mi limit) | ≥ 512 MiB |

The 5m query was off by 16x and pointed the wrong way — it would have justified *cutting*
the limit on a container that was dying of OOM. Use 1m resolution, treat any sampled peak as
a floor rather than a maximum, and corroborate with OOM evidence before recommending a
reduction. Short-lived CronJob pods are the worst case; long-running services are sampled
well.

## Tooling notes

- **No `sleep`, ever** — not in poll loops. It is a no-op here and the loop spins hot enough
  to wedge the machine. Use `kubectl wait --timeout`, or a `kubectl logs -f | grep` that
  blocks on I/O.
- System `python3` has no PyYAML. Use `uvx --with pyyaml python3 -c '...'`.
- There is no shell in the Prometheus pod and no `promtool`. Validate PromQL by POSTing it
  to `/api/v1/query` and checking for `"status":"success"`.
- `kubectl run --rm -i` sometimes prints its output twice and warns about failing to
  attach. Harmless; read the actual output.

## What to report

Write the report to `docs/audits/<YYYY-MM-DD>-resource-audit.md` and commit it on a `docs/`
branch, so the next audit can diff against it. Include the date each measurement was taken —
a peak is only meaningful against a window.

A table of findings ordered by severity, each naming:

- the workload and namespace
- the symptom, with the measurement that shows it (throttle %, OOM count, usage vs request)
- **which layer causes it** — container spec, LimitRange, VPA policy, or genuine demand
- the specific fix, and whether it is one line or a design change
- whether it is safe to change while the app is serving

Separate the findings that are real problems from the ones that are merely untidy. An
over-provisioned memory limit on a node with headroom is not worth a PR; a CPU limit
feeding the VPA ratio trap is.

## Rules

- Read-only. Do not edit manifests, do not `kubectl apply`, do not scale anything. ArgoCD
  runs `selfHeal: true` and will fight you regardless.
- Propose fixes as separate branches for the human to approve, one logical change each.
- If a finding rests on a single data point, say so. Peak-over-24h can be an artifact of one
  event, and a recommendation built on it will be wrong.
