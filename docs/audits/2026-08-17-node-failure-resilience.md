# Node-failure resilience audit — 2026-08-17

Audit was discovery-only. State captured from the live cluster via the direct LAN path
(`ssh -b 192.168.10.105 … 192.168.30.129`), cross-checked against the manifests in this repo.
Findings #1 and the NFS alerting gap were subsequently fixed on `fix/ingress-node-failover`;
everything else here is untouched, and each finding carries its own status.

Trigger: worker-02 was down ~4h on 2026-08-17 (M.2 reseat). The cluster survived because the
two nodes that stayed up happened to be the right two.

---

## Executive summary

The cluster tolerates losing **worker-00** or **worker-02** well. Losing **worker-01** is not a
degradation, it is an outage — and not because of NFS, which is the known and accepted risk.
Three separate things are pinned to worker-01 by the *same* label, and two of them have no
business being there:

1. **The Cilium L2 announcement policy for `192.168.30.200` selects `homelab.io/media=true`**
   (`system/envoy-gateway/cilium-l2-announce.yaml:6-8`). Only worker-01 carries that label, so
   only worker-01 ever ARPs for the gateway VIP. Lose it and *every* HTTPS hostname goes dark
   with no failover path — the VIP is unannounced, not merely unbacked.
2. **All four CNPG primaries are currently on worker-01** (immich-database-3,
   infisical-database-3, nextcloud-database-2, vaultwarden-database-3). Losing it means four
   simultaneous failovers.
3. **Every backup in the cluster writes to worker-01** — the five `*-db-backup` NFS PVCs *and*
   the Longhorn backup target (`nfs://192.168.30.194:/mnt/storage/longhorn-backups`). The node
   with the largest blast radius is also the only copy of the recovery data for everything else.

Everything else I found is either already correct or cheap to accept in writing.

---

## Per-node blast radius

Allocatable, and current load from running pods:

| Node | CPU | Memory | CPU req | Mem req | Mem **limits** | Disk free |
|---|---|---|---|---|---|---|
| worker-00 | 4 | 14.96 Gi | 1.71 | 6.89 Gi | 12.42 Gi | **26 G / 115 G (77 % used)** |
| worker-01 | 12 | 22.64 Gi | 3.53 | 14.47 Gi | **29.51 Gi (130 % of allocatable)** | 375 G / 466 G |
| worker-02 | 12 | 14.89 Gi | 1.58 | 6.15 Gi | 5.44 Gi | 120 G / 233 G |

### worker-01 (192.168.30.194) — the one that matters

| What dies | Recovery | Time |
|---|---|---|
| **All ingress.** L2 policy selects `homelab.io/media=true`; the `192.168.30.200` VIP stops being announced. `envoyproxy.yaml:36-37` also pins the single proxy replica here. | **Manual, and needs the trick:** label another node `homelab.io/media=true` (which also drags media apps onto it) or edit the L2 policy. Not automatic at all. | Until a human intervenes |
| **NFS server** — `immich-library`, `nextcloud-data`, `vaultwarden-data`, `storage-loki-0`, `qbittorrent`, `recyclarr`, all five `*-db-backup` PVCs, and the Longhorn backup target | Manual (node must come back) | = node downtime |
| Media stack pinned by `nodeSelector` — jellyfin, nextcloud, immich-server, immich-valkey, sonarr, radarr, lidarr, bazarr, prowlarr, qbittorrent, unpackerr, navidrome | Cannot reschedule; nodeSelector matches only this node | = node downtime |
| 4 CNPG primaries | **Automatic** failover to a surviving replica | ~30 s |
| 3 CNPG replica pods on `local-path` (infisical-3, jellyfin/nextcloud-2, immich-3, vaultwarden-3 PVs pinned here) | **Manual + trick:** delete the PVC *and* the replacement pod so the controller creates a join job | 10–30 min/instance |
| 10 of 12 Longhorn volumes drop to 1 replica | Automatic rebuild onto worker-02 | minutes |
| argocd-server, argocd-repo-server, argocd-redis, cert-manager, cert-manager-webhook, external-dns, cloudnative-pg operator, metrics-server, loki-0, alertmanager, kube-state-metrics, tailscale operator + subnet router, VPA admission+recommender, local-path-provisioner, longhorn-driver-deployer | Automatic reschedule (loki-0's PVC is NFS on this node, so it stays down) | 1–5 min |
| **Tailscale subnet router** — remote access to `192.168.30.0/24` | Automatic reschedule, but DNS/route reconvergence is flaky | 5–15 min |

### worker-00 (192.168.30.129) — smallest, holds the most Longhorn

| What dies | Recovery | Time |
|---|---|---|
| **10 of 12 Longhorn volumes drop to 1 replica** — worker-00 holds a replica of every volume except grafana and prometheus | Automatic rebuild onto worker-02 | minutes, bounded by 26 G free on the *target* |
| CNPG replicas immich-database-1, infisical-database-1, nextcloud-database-1, vaultwarden-database-1 (`local-path`, pinned here) | **Manual + trick** (delete PVC **and** pod) | 10–30 min each |
| argocd application-controller / applicationset / dex / notifications → GitOps stops reconciling | Automatic reschedule | 1–5 min |
| coredns (1 of 3 kube-dns endpoints), cilium-operator, sealed-secrets, nfs-provisioner (the CSI provisioner, not the server), blackbox-exporter, homepage, hubble-ui, alloy, infisical redis-master, vaultwarden app, flaresolverr, nextcloud-metrics, vpa-updater | Automatic reschedule | 1–5 min |
| Its 5 local etcd snapshots | Gone with the disk; other members keep their own | — |

### worker-02 (192.168.30.136) — cheapest to lose

| What dies | Recovery | Time |
|---|---|---|
| Prometheus + Grafana (both single-replica, both Longhorn-backed with a replica on worker-00) | Automatic reschedule; volume re-attaches | 1–5 min, blind for that window |
| CNPG replicas immich-database-2, infisical-database-2, nextcloud-database-3, vaultwarden-database-2 (`local-path`) | **Manual + trick** — this is exactly what bit tonight | 10–30 min each |
| grafana + prometheus Longhorn volumes drop to 1 replica | Automatic rebuild | minutes |
| One coredns-ha replica; a replacement goes **Pending** (`maxSkew: 1`, `DoNotSchedule`, only 2 nodes left) | Self-heals when the node returns | — |
| intel-gpu-plugin, one loki-canary, NFD worker, node-exporter | Automatic (DaemonSets) | — |

**etcd, all three nodes:** quorum survives one loss. Two losses = read-only API and no recovery
without a manual `--cluster-reset`, which has never been rehearsed here.

---

## Findings, ranked by expected pain

### 1. The gateway VIP is announced by exactly one node, chosen by the media label

`system/envoy-gateway/cilium-l2-announce.yaml:6-8` narrows the announcing set to
`homelab.io/media=true`, which is worker-01 alone. `envoyproxy.yaml:36-37` pins the single
Envoy replica to the same node.

**Cost when it bites:** every public hostname is unreachable for the entire duration of a
worker-01 outage — four hours tonight, if it had been the other node. Nothing recovers on its
own, because L2 announcement has no other candidate.

**Status: fixed in `fix/ingress-node-failover`.**

**The fix, and a correction to my own first draft.** The pin exists because client IP
preservation is a *placement* property: Cilium SNATs to the forwarding node's `cilium_host`
address only when it crosses nodes, and that address is still RFC1918, so Jellyfin reclassifies
every remote session as LAN. My first draft proposed keeping `externalTrafficPolicy: Cluster`
and holding the proxy on worker-01 with a *preferred* node affinity. That does not work: under
`Cluster`, Cilium's load balancer hashes across all backends and does not prefer the local one,
so as soon as there is a second proxy replica some fraction of connections cross a node and get
SNATed — the exact silent failure PR #112 fixed.

What shipped instead:

- `homelab.io/ingress=true` on worker-01 and worker-02, a **new label**, not a widening of
  `homelab.io/media`. The L2 announcement policy selects it, so either node can announce.
- `externalTrafficPolicy: Local`, which makes Cilium pick only node-local backends — the
  forward never crosses a node, so no SNAT, regardless of which node holds the lease.
- Two proxy replicas with a `DoNotSchedule` hostname spread over exactly those two nodes, so
  every candidate announcer has a local backend. That closes the blackhole `Local` would
  otherwise risk (announcing from a node with no proxy), which is why the original manifest
  avoided `Local` in the first place.
- `maxSurge: 0 / maxUnavailable: 1`, because a `DoNotSchedule` spread with as many replicas as
  nodes leaves a surge pod nowhere to land and would deadlock a rolling update.

**Cost forever:** one extra Envoy pod (100m CPU / 512Mi requested), one more label to remember,
and a single-replica window during proxy upgrades — which is what this ran on permanently until
now. Media placement is unchanged.

### 2. Every backup in the cluster lands on worker-01

The five `*-db-backup` PVCs are `nfs` class, and the Longhorn backup target is
`nfs://192.168.30.194:/mnt/storage/longhorn-backups`. There is no CNPG `backup:` stanza on any
of the four clusters — no WAL archiving, no Barman object store. The nightly `pg_dump` CronJobs
are the only Postgres recovery path, and they write to the node whose failure is the worst case.

**Cost when it bites:** a worker-01 disk failure (not just a reboot) takes the media library
*and* every database dump *and* every Longhorn backup in one event. The Longhorn volumes
themselves survive on the other two nodes, so this is not an immediate data-loss scenario — it
is the loss of the second copy at exactly the moment you need it.

**Status: open, deferred deliberately.** My first draft of this said to reuse the existing
rclone remote. That was wrong: `apps/rclone-seedbox/values.yaml` is an *inbound* SFTP copy from
a third-party torrent host (`nl137.seedit4.me`), not a backup destination — unclear quota, no
retention guarantee, and not somewhere Vaultwarden dumps belong. There is no other off-box
remote anywhere in the repo.

**Smallest fix:** one rclone CronJob syncing `/mnt/storage/*-db-backup/` plus
`/var/lib/rancher/k3s/server/db/snapshots` to a real destination. The destination is the open
decision — a B2 bucket is the cheap answer for a few GB, a second local disk on another node is
the free one that survives a worker-01 disk failure but not a site event.

**Cost forever:** egress for the dumps only (they're `pg_dump` output, not the media library),
plus the bucket. Nothing until a destination is chosen.

### 3. All four CNPG primaries are on worker-01

Confirmed live: `immich-database-3`, `infisical-database-3`, `nextcloud-database-2`,
`vaultwarden-database-3` are all `currentPrimary` and all scheduled to worker-01. The
`podAntiAffinity` is `required` per cluster, so instances spread — but nothing spreads
*primaries* across clusters.

**Cost when it bites:** four simultaneous failovers. Each is automatic and ~30 s, but they land
on the surviving nodes at the same moment, and the writeable instance for Vaultwarden and
Nextcloud moves under load.

**Smallest fix:** honestly, nothing. CNPG failover works, it is fast, and it was exercised
tonight. Pinning primaries would be a permanent constraint bought to smooth a 30-second event.
**Recommend: no change — record it as accepted.** The one thing worth doing is knowing it, which
this document now does.

### 4. worker-00 holds a Longhorn replica of everything and has 26 G free

10 of 12 volumes replicate to `worker-00 + worker-01`; only grafana and prometheus use
worker-02. worker-00 is at 77 % on a 115 G filesystem and also carries four CNPG `local-path`
PVs.

**Cost when it bites:** two coupled problems. Losing worker-00 *or* worker-01 degrades ten
volumes at once and triggers ten rebuilds. And worker-00 filling up makes it unschedulable for
Longhorn, at which point 2-replica volumes cannot be repaired at all — `LonghornNodeStorageFull`
exists and would tell you, but the window between "alert fires" and "no repair possible" is the
same 26 G.

**Smallest fix:** nothing structural — the skew is Longhorn's scheduler reacting to worker-02
having been absent when most of these volumes were created 3–4 days ago. Deleting the stale
`*-config-local` PVCs (finding #5) frees worker-00 space, and Longhorn will rebalance on its own
as volumes are rebuilt. Re-check the replica map after that. **No new component.**

**Cost forever:** zero.

### 5. Twelve `local-path` PVCs are stale rollback copies nothing mounts

Cross-referencing volumes on running pods: **no non-CNPG `local-path` PVC is in use.** These
twelve are bound, node-pinned, and mounted by nothing —
`bazarr-config-local`, `cleanuparr-config-local`, `jellyfin-config-local` (20 Gi),
`lidarr-config-local`, `navidrome-config-local`, `nextcloud-html`, `prowlarr-config-local`,
`radarr-config-local`, `sonarr-config-local`, `vaultwarden-data-local`, plus the two `nextcloud`
strays. Roughly 100 Gi held, most of it on worker-01 and worker-00.

This is the Longhorn migration's Task 16, already gated to **2026-08-27** — so this finding is
not "do something", it is "the gate is the reason worker-00 is at 77 %". Note the reclaim policy
is `Delete`, so the prune is irreversible; that is exactly why the gate exists.

**Smallest fix:** none before the 27th. Afterwards, deleting them is the single largest disk
reclaim available and directly relieves finding #4.

### 6. `*-database-primary` PDBs show 0 allowed disruptions — a drain cannot succeed

Live: `immich-database-primary`, `infisical-database-primary`, `nextcloud-database-primary`,
`vaultwarden-database-primary` each report **ALLOWED DISRUPTIONS 0**, as do the three
`instance-manager-*` PDBs. Tonight's drain was impossible and recovery needed
`node.kubernetes.io/out-of-service` instead.

**Cost when it bites:** you cannot cleanly drain a node for planned maintenance without either
switching over each Postgres primary first or deleting/ignoring PDBs.

**Smallest fix:** none to the PDBs themselves — they are CNPG-managed and correct. The gap is
procedural: the drain order is `cnpg promote` off the node, *then* drain. That belongs in the
runbook below, not in a manifest.

### 7. etcd snapshots never leave the cluster hardware

k3s defaults: 5–6 snapshots per member in `/var/lib/rancher/k3s/server/db/snapshots`, on each
node's own disk. No `etcd-s3` and no snapshot config anywhere in `ansible/`.
`EtcdSnapshotStale` alerts on freshness, so a broken snapshotter would be caught — the gap is
destination, not liveness. And the `--cluster-reset` restore path has never been rehearsed here.

**Cost when it bites:** only in a two-node or whole-rack loss, at which point you are rebuilding
from the repo anyway. Everything in this cluster is GitOps-declared; etcd holds little that
`main` plus the sealed/Infisical secrets cannot re-create.

**Smallest fix:** fold the snapshot directory into whatever off-box sync finding #2 adds. Free,
since the CronJob already has to exist.

---

## Accept these risks — deliberately, in writing

- **NFS on worker-01.** Out of scope by your framing, and correct for the hardware: the 12 TB
  HDD is physically attached to that node. Losing it takes the media library and every `nfs`
  PVC. Accepted. The part of it that is *not* accepted is finding #2 — backups having no second
  home is a separate decision from where the primary share lives.
- **Media apps pinned to worker-01.** They cannot reschedule and should not; they need the local
  data path. A worker-01 outage is a media outage. Accepted.
- **All four CNPG primaries co-located** (finding #3). Failover is automatic and proven.
  Accepted.
- **Longhorn at 2 replicas on 3 nodes.** One node's loss degrades but never destroys, and
  Longhorn rebuilds onto the third. Three replicas would buy a second simultaneous failure —
  a scenario where the NFS server is probably gone anyway. Accepted. Durability comes from the
  app-level backups, which is the correct layer; the arrs, Jellyfin, Nextcloud, Immich,
  Infisical and Vaultwarden all have their own backup path, and `cleanuparr` has the CronJob
  it needs because it has no built-in one.
- **coredns-ha loses a replica to `Pending` during a one-node outage.** `replicas: 2` with
  `maxSkew: 1 / DoNotSchedule` means the third kube-dns endpoint cannot be replaced while a node
  is down. DNS still serves from two pods on two nodes, and `CoreDNSRedundancyLost` covers the
  real breach. Accepted — this is the constraint working as designed, not a defect.
- **Single-replica platform Deployments** (argocd-server, cert-manager, external-dns,
  cloudnative-pg, metrics-server, sealed-secrets, envoy-gateway controller, vpa-*, alloy,
  homepage, and ~40 more). Every one of them reschedules automatically in 1–5 minutes and none
  serves live user traffic during that window except the gateway data plane, which is finding
  #1. Scaling these to 2 would add ~40 pods of RAM to a 3-node cluster to shave minutes off a
  once-a-year event. Accepted, explicitly.
- **Prometheus and Alertmanager are single-replica and in-cluster.** Losing their node blinds
  monitoring for the reschedule window — but the healthchecks.io dead-man's switch is outside
  the blast radius by design (`system/monitoring-system/values.yaml:287-292`), and ntfy is
  external. The monitor being inside the cluster is fine when the *absence* of its heartbeat is
  watched from outside. Accepted.

### Alerts that would have fired tonight

`KubeNodeNotReady` / `KubeNodeUnreachable` (bundled), `LonghornNodeNotReady`,
`LonghornVolumeDegraded`, `CNPGInstancesMissing`, `CNPGReplicationDegraded`,
`CoreDNSRedundancyLost`, `ScrapePoolEmpty`, plus the `*MetricsMissing` family for anything that
had been scraped on worker-02. Prometheus itself was on worker-01 at the time, so it survived —
had it been on worker-02, the dead-man's switch was the backstop. Coverage here is genuinely
good; I found no missing alert worth adding.

**One real gap:** nothing alerts on the *NFS server* being unreachable as such. You'd infer it
from a cascade of app alerts. **Fixed in `fix/ingress-node-failover`:** a `tcp_connect` module
and a Probe for `192.168.30.194:2049` in the already-deployed blackbox-exporter, plus an
`NFSServerUnreachable` rule that names the cause and lists what it takes down. No new
component. `EndpointDown` is now scoped to the `https://` targets so it does not double-fire
with HTTPRoute advice for a dead file server.

---

## Recovery runbook

The steps that bit tonight were procedural. Access first — the Mac's route to
`192.168.30.0/24` goes over Tailscale, which runs *inside* the cluster:

```bash
ssh -b 192.168.10.105 -i ~/.ssh/id_ed25519 homelab@192.168.30.129
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes
```

`kubectl` has no `-b` equivalent — run it on a node, not from the Mac.

### A. A node is gone and will be gone a while

```bash
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
```

Force-deleting pods alone leaves volumes attached to the dead node. The taint detaches them
too. **Remove the taint before the node rejoins**, or its pods will be evicted the moment it
comes back.

### B. A CNPG instance whose `local-path` PV died with the node

The controller will not re-seed on its own — the PVC still looks bound.

```bash
kubectl delete pvc  -n <ns> <cluster>-<n>
kubectl delete pod  -n <ns> <cluster>-<n>      # required: the orphan pod blocks the join job
kubectl get cluster -n <ns> <cluster> -w        # expect "Creating a new replica"
```

Both deletes. The PVC alone is not enough — the replacement pod has to go too before a bootstrap
join job is created.

### C. Draining a node on purpose

PDBs report 0 allowed disruptions for every CNPG primary, so a plain `drain` will hang.

```bash
# move any primary off the node first
kubectl cnpg promote -n <ns> <cluster> <instance-on-another-node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

### D. Ingress is down and both `homelab.io/ingress` nodes are gone

Normal single-node loss needs nothing here — worker-02 announces and already runs a proxy.
For the two-node case, make worker-00 a candidate:

```bash
kubectl label node worker-00 homelab.io/ingress=true    # announcer + a proxy replica follow
```

`homelab.io/ingress`, **not** `homelab.io/media` — the latter would also make worker-00 a
scheduling target for media apps whose data lives on worker-01's disk. Remove the label once an
ingress node is back.

### E. worker-02 will not POST

Reseat the M.2 before condemning the drive (2026-08-17: that was the whole fault). Its NVMe APST
is `0` deliberately — the WD SN740 drops off the bus otherwise. For a one-off boot with a
different value, edit the GRUB entry at the boot menu rather than changing Ansible.

---

## What I'd actually do

**Shipped in `fix/ingress-node-failover`:**

1. **Finding #1** — `homelab.io/ingress=true` on worker-01 and worker-02, driving both the L2
   announcement policy and the Envoy proxy, with `externalTrafficPolicy: Local` and one proxy
   replica per labelled node. `homelab.io/media` is untouched, so nothing changes about where
   media apps schedule. Removes the only failure mode where losing a node means an indefinite
   total outage.
2. **The NFS alerting gap** — `tcp_connect` probe of `192.168.30.194:2049` and an
   `NFSServerUnreachable` rule.

**Deferred:** finding #2 needs an off-box destination chosen first (see its Status note).

Findings #4 and #5 resolve themselves once the 2026-08-27 gate opens. Findings #3, #6 and #7
are runbook entries and accepted risks, not work.

### Follow-up that section D of the runbook no longer needs

Once #1 is live, "ingress is down because worker-01 is down" stops being a manual procedure —
worker-02 takes the announcement and already has a proxy replica. Section D below is retained
only for the case where *both* ingress nodes are down, where relabelling worker-00
`homelab.io/ingress=true` is the move (not `homelab.io/media`, which would drag media apps
onto a node with no local data).
