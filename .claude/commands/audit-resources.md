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

# Peak memory vs limit — the OOM risk, and the over-provisioning signal
max_over_time(sum by (namespace) (container_memory_working_set_bytes{container!=""})[24h:5m])
sum by (namespace) (kube_pod_container_resource_limits{resource="memory"})

# Recent OOMKills
sum by (namespace, pod) (increase(kube_pod_container_status_terminated_reason{reason="OOMKilled"}[7d]))

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
