# Root-cause prompt: dangling Cilium BPF LB backends

Investigation handoff written 2026-07-30. Paste the section below into a new session.

---

Root-cause why Cilium agents on this 3-node k3s cluster can permanently stop programming
new backends into their BPF load-balancer map. Do NOT build a detection/restart script as
the fix — deleting the agent pod is the existing workaround and is what needs replacing.
Find the actual defect (Cilium config, version bug, or an upstream trigger) and fix it in
the repo. Rigorous systematic debugging: root cause before any fix, one hypothesis at a
time, verify with a real test before declaring done.

## The symptom

After a node's Cilium agent restarts, it can permanently stop programming **new** backends
into its BPF LB map. Every service whose backend pod is created *after* that agent start
gets a dangling entry, breaking those services for every pod on that node.

**Why it hides:** `cilium-dbg service list` renders the agent's *userspace* view and still
shows `10.43.0.10:53 => 10.42.0.46 (active)`. Node Ready, agent ready, `cilium-dbg status
--brief` = OK, all endpoints `ready`, zero not-ready pods. Only the BPF map disagrees.

**Detect** (0 is healthy; compare across nodes):
```bash
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- \
  cilium-dbg bpf lb list | grep -c 'not found'      # "backend 235 not found"
```

Signature from inside an affected pod: one ClusterIP fails while others work —
`10.43.0.10:53` gives `no route to host` but `10.43.0.1:443` and the CoreDNS *pod* IP both
succeed. (bash `/dev/tcp/<ip>/<port>` works in most pods.)

**Known occurrence:** worker-00, 2026-07-28, 23 dangling frontends. Blast radius when it
hit `kube-dns`: all ~43 pods on the node lost cluster DNS → all 27 ArgoCD apps stuck
`Unknown` with `ComparisonError` (looks like a git/repo problem, isn't) and cert-manager
`Degraded`. Also dangled the Envoy Gateway VIP, two Postgres services, Loki, Alertmanager,
and four admission webhooks.

**Current workaround:** delete that node's cilium agent pod; it rebuilds the LB maps from
k8s state. Verified 23 → 0, DNS restored, no side effects.

## Already ruled out — do not re-derive

Gathered 2026-07-30 with evidence. All three nodes read **0 dangling** at that time,
including across two worker-02 reboots and a full 3-node agent rollout.

- **bpffs persistence is NOT the cause.** `/sys/fs/bpf` is a real host mount with `shared`
  propagation and 127 pinned maps. It survives agent restart (which is the point) and is
  wiped on reboot (correct — BPF map state is kernel state). No fstab entry and no
  `sys-fs-bpf.mount` unit is needed or expected; the agent's `mount-bpf-fs` init container
  does it.
- **Map exhaustion is NOT the cause.** On worker-00: `cilium_lb4_services_v2` 197,
  `cilium_lb4_backends_v3` 71, `cilium_lb4_maglev` 65, `cilium_lb4_reverse_sk` 2475 — against
  `bpf-lb-map-max: 65536`. `cilium-dbg map list` reports **0 errors** on every map.
- **The operator's CiliumEndpoint GC is fine.** `cilium-endpoint-gc-interval = 5m`,
  `identity-gc-interval = 15m`, and only 2 stale CEP CRs existed out of 57. CEP GC collects
  *CRs*, not the agent's local endpoint state — it is not the relevant lever.
- **`--register-with-taints` is irrelevant here** (and to the sibling reboot symptom):
  kubelet applies it only at first Node registration, never on reboot or kubelet restart.

Still open, not yet investigated in depth: whether `loadBalancer.algorithm: maglev` or
`bpf.lbExternalClusterIP: true` interact with restore-on-restart in any documented way, and
whether Cilium 1.19.x has a known LB-map sync regression. Start with
[cilium#43358](https://github.com/cilium/cilium/issues/43358) — "k8s objects update but
Cilium's internal LB cache does not, so no BPF map update event fires; a DaemonSet restart
immediately fixes the maps." That is the closest match found so far.

## Leading hypothesis — a shared upstream cause with the CNI-ADD timeouts

**Established fact (not hypothesis):** `cilium-cni` waits for the agent socket with a hard
30s ceiling. When it expires, the agent has often already created the endpoint, but the
plugin gave up; the follow-up CNI DEL cannot clean it (`Unable to open network namespace`),
so a **local endpoint leaks**. On worker-00, **11 of 12 orphaned local endpoints were
exactly the pods that failed CNI ADD at 2026-07-29 01:59** (the 12th was identity 4,
`reserved:health` — not a leak). Leaked endpoints live in `/var/run/cilium/state/<id>/`
(tmpfs), are **restored on every agent restart**, and are cleared only by a reboot — so the
"restart the agent" workaround never removed them.

**The unproven step:** those leaked IPs belonged to pods that *were* service backends
(metrics-server, external-secrets-webhook, grafana, cloudnative-pg, alertmanager). That is
the right shape for `backend N not found`, and it is the same node and same stale-state
family. But no path from "leaked local endpoint" to "dangling LB backend" has been
demonstrated. **Do not assume it — prove or kill it.**

**What would confirm it:** catch a node with BOTH a nonzero orphaned-endpoint count AND a
nonzero `bpf lb list | grep -c 'not found'` at the same time, and show the dangling backend
IDs correspond to leaked endpoints.

Count orphaned endpoints (endpoints whose IP matches no live pod; expect exactly one
`reserved:health` endpoint per node as a false positive):
```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep -v '^$' | sort -u > /tmp/podips
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium-dbg endpoint list -o json
# compare .status.networking.addressing[0].ipv4 against /tmp/podips;
# .status.external-identifiers gives k8s-pod-name and container-id
```

## Important caveat before you start

Commit `f2c5654` (2026-07-30) added a k3s `ExecStartPre` gate that removes the stale CNI
conflist when `cilium.sock` is absent, so the node stays honestly `NotReady` until the agent
is serving. That eliminated the CNI ADD timeouts on a validated reboot (12–13 failures per
boot → 0). **If the timeouts were the upstream trigger, symptom 2 may no longer be
reproducible at all.** First establish whether it still occurs — if you cannot reproduce it
and the mechanism only ever fired via CNI-ADD timeouts, the correct outcome is to document
that it is already fixed upstream, not to invent a new fix.

## Cluster facts (already gathered, don't re-derive)

- 3 nodes, all k3s server+worker, HA etcd: worker-00 (192.168.30.129), worker-01
  (192.168.30.194, also the NFS server), worker-02 (192.168.30.136). k3s v1.36.2+k3s1,
  containerd 2.3.2-k3s2, Ubuntu 26.04, kernel 7.0.0. SSH as `homelab` with
  `~/.ssh/id_ed25519` (hostnames do not resolve — use IPs). kubectl works from this machine.
- Cilium 1.19.5, Helm-bootstrapped from `bootstrap/values/cilium.yaml` via
  `just bootstrap-cilium` (NOT ArgoCD — Cilium cannot manage its own CNI through a
  controller that needs the CNI). Live config confirmed: `routing-mode: tunnel`,
  `tunnel-protocol: vxlan`, `bpf-lb-algorithm: maglev`, `bpf-lb-external-clusterip: true`,
  `bpf-lb-sock: true`, `bpf-lb-map-max: 65536`, `cni-exclusive: true`,
  `write-cni-conf-when-ready: /host/etc/cni/net.d/05-cilium.conflist`, kubeProxyReplacement,
  `ipam.mode: kubernetes`, L2 announcements enabled.
- `k8sServiceHost` is now `127.0.0.1` (commit `f973407`) — each agent talks to its own
  node's apiserver. Both DaemonSets are pinned to `maxUnavailable: 1`.
- containerd has no `cni.conf_dir` override, so it watches the `/etc/cni/net.d` default.
- Node-level OS/systemd config is Ansible (`just provision-common`, tagged `common`), not
  GitOps.

## Constraints

- Follow `CLAUDE.md`: GitOps via ArgoCD for anything under `system/`/`platform/`/`apps/`
  (never manual `kubectl apply` of managed manifests), Ansible for node-level config, no
  `local-path`, no `Ingress`, no `Co-Authored-By` in commits, no `sleep` in scripts.
- Ask before rebooting a node — this is a live homelab. Prefer worker-02 (no NFS server, no
  media workloads); rebooting one of three keeps etcd quorum.
- Restarting a Cilium agent is safe and routine; restarting one during a containerd wedge is
  NOT (it makes that node worse — see `node_containerd_wedge_restart_k3s` memory).
- If 3+ fix attempts fail for the same symptom, stop and surface that the approach may be
  wrong rather than trying a 4th patch.

## Deliverable

Root cause (or "investigated, here is why it is genuinely environmental/already fixed, with
evidence"), the fix committed to the repo, and how you validated it actually prevents
recurrence.
