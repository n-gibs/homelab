# Longhorn Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `local-path` with Longhorn for the four arr config volumes and Cleanuparr, so a
worker-01 NVMe failure no longer means restoring four SQLite databases by hand — and so the
Talos migration inherits a CSI that already works instead of two unfamiliar things at once.

**Architecture:** Longhorn installed from its official chart into `system/longhorn-system/`,
picked up by the existing `system` ApplicationSet at sync wave 1. Two replicas per volume with
`best-effort` data locality, so the pod's node always holds a local copy and only the second
replica crosses the wire. Migration is per-app: new Longhorn PVC, restore from the app's own
backup, delete the `local-path` PVC. One pilot app first with a measured go/no-go gate before
the other four.

**Tech Stack:** k3s v1.36.3, ArgoCD, Longhorn chart `1.12.0`, Cilium 1.19.5 (kube-proxy
replacement), open-iscsi on the hosts via Ansible.

**Prerequisite for:** `docs/talos-migration-audit.md` — Talos needs a non-`local-path` CSI story
or an explicit decision to keep `local-path`. This plan resolves that either way.

## Why now, honestly

The NAS is months out, so this does **not** fix the big thing. Stating the value plainly so the
gate in Phase 4 is an honest one:

**What it buys today**
- worker-01's internal NVMe holds four arr configs on `local-path`. If that disk fails, all four
  are gone and restored by hand from backups on the USB drive (a separate device, so it survives).
  Longhorn makes that automatic.
- You learn Longhorn on a system you can SSH into, before Talos removes the shell. This is the
  main reason to sequence it first.
- It measures the 1GbE fsync tax with real numbers, which is the only genuinely open question.

**What it does not buy**
- It does **not** unpin the arrs. All four carry `nodeSelector: homelab.io/media: "true"` and
  worker-01 is the only labelled node — they are pinned by the selector, not by `local-path`.
  Longhorn changes where the *data* lives, not where the pod runs.
- If worker-01 dies outright, the media and the backups go with it (pre-NAS). Config mobility
  helps much more once the NAS lands.

If Phase 4 measures a bad fsync penalty, the correct answer is to abandon this and keep
`local-path` through the Talos migration. That is a legitimate outcome, not a failure.

## Scope

**In:** `sonarr`, `radarr`, `lidarr`, `prowlarr` config volumes (10Gi each) and `cleanuparr`
(2Gi). 42Gi total.

**Out, deliberately:**
- **CNPG** (`immich-database-{1,2,3}`, `nextcloud-database-{1,2,3}`, 90Gi). Postgres already
  replicates across three instances; adding 2× Longhorn replication underneath means six copies
  of every write over 1GbE, and CNPG's own guidance prefers local storage. Stays `local-path`.
- **`nextcloud-html`** (10Gi). ~15k small files reconstructible from the container image — losing
  it costs a rebuild, not data. Replicating it costs more than it's worth. Stays `local-path`.
- **Anything on `nfs`.** Media, backups, Loki, Prometheus. Untouched by this plan.

## Global Constraints

- Chart: `longhorn` `1.12.0` from `https://charts.longhorn.io`.
- **Directory must be `system/longhorn-system/`, not `system/longhorn/`.** The `system`
  ApplicationSet in `bootstrap/root/templates/stack.yaml` hardcodes
  `destination.namespace: {{path.basename}}`, and Longhorn requires the `longhorn-system`
  namespace — it is hardcoded in several of its own components. Getting this wrong installs a
  half-broken Longhorn into a namespace it cannot operate from.
- `csi.kubeletRootDir: /var/lib/kubelet` is **required** on k3s — Longhorn cannot autodetect it
  and the CSI plugin fails silently without it. Verified present on all three nodes 2026-08-10.
- `iscsid` is **installed but disabled and inactive on all three nodes**, and `iscsi_tcp` is not
  loaded. `roles/common` installs the `open-iscsi` package and never enables the service. Task 1
  fixes this; Longhorn's v1 engine cannot attach a volume without it.
- Replicas: **2**, not the default 3. Three nodes, 42Gi, and every extra replica is another
  synchronous network write on the link that also carries VXLAN and all NFS traffic.
- `defaultDataLocality: best-effort` — guarantees a replica on the pod's own node, so reads stay
  local and only one replica crosses the wire on write. This is what makes the fsync tax
  survivable; do not omit it.
- `defaultDataPath: /var/lib/longhorn` lands on the root LV. Free space 2026-08-10: worker-00
  78G, worker-01 410G, worker-02 198G. Longhorn refuses to schedule on a node below
  `storageMinimalAvailablePercentage` (default 25%); worker-00 is at 68% free, so there is room,
  but **worker-00 is the one to watch** — it is a 119G disk with 20G of containerd images.
- **Do not route the Longhorn UI publicly.** It ships with no authentication. Grafana gets an
  HTTPRoute because it has its own login; Longhorn does not. Use `kubectl port-forward`, or a
  Tailscale-only path if you want it persistent. No `httproute.yaml` in this plan.
- `deletingConfirmationFlag` stays at its default (`false`). ArgoCD runs `prune: true` +
  `selfHeal: true`; that flag is what stops an accidental Application deletion from taking the
  volumes with it. Do not set it true "to make cleanup easier".
- Every `system/` component here gets a `vpa.yaml` — matches `system/loki`, `system/alloy`,
  `system/cert-manager`, etc.
- Never `kubectl apply` managed manifests. ArgoCD syncs from `main`; merging to `main` is how
  things deploy. Pre-merge validation is `helm template` plus client-side dry-run only.
- Chart version in `app.yaml` is Renovate-managed. Do not pin to `latest`.
- No `sleep`. Use `kubectl wait`.
- No `Co-Authored-By` trailers in commits.

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/common/tasks/main.yml` | **Modify.** Enable `iscsid`, load `iscsi_tcp` persistently |
| `system/longhorn-system/app.yaml` | **Create.** Chart coordinates, `syncWave: "1"`, Renovate-parsed |
| `system/longhorn-system/values.yaml` | **Create.** kubeletRootDir, replica count, data locality, resources |
| `system/longhorn-system/vpa.yaml` | **Create.** VPA for the manager DaemonSet |
| `apps/<app>/config-pvc.yaml` | **Modify** ×5, one per phase-5 task. `local-path` → `longhorn` |
| `CLAUDE.md` | **Modify.** Amend the three `local-path` exceptions once the outcome is known |
| `docs/talos-migration-audit.md` | **Modify.** Record the outcome so §3 stops recommending `local-path` |

There is no test framework in this repo. The equivalent of a failing test is `helm template`
rendering the wrong output, a dry-run rejecting a manifest, or the `fio` benchmark in Task 5
returning numbers that fail the gate — so each task validates *before* the change is correct,
confirms the failure, then fixes it.

---

## Phase 1 — Host prerequisites

### Task 1: Enable iscsid on all three nodes

`roles/common` installs `open-iscsi` but never enables the service. Verified 2026-08-10: all
three nodes report `iscsid: inactive`, `iscsid enabled: disabled`, `iscsi_tcp loaded: 0`.
Longhorn's v1 data engine attaches volumes over iSCSI to localhost; without this every volume
attach fails with a timeout that reads like a Longhorn bug.

- [ ] Confirm the failure first: `just ping` then
      `ansible -i ansible/inventory.yml all -m shell -a 'systemctl is-enabled iscsid' --vault-password-file .vault_pass`
      — expect `disabled` ×3.
- [ ] Add to `ansible/roles/common/tasks/main.yml`, near the existing `open-iscsi` install, with
      a comment explaining it exists for Longhorn:
  - `iscsi_tcp` in `/etc/modules-load.d/` so it survives reboot
  - `community.general.modprobe` for the running kernel
  - `systemd_service` enabling and starting `iscsid`
- [ ] `just dry-run` — confirm the three new tasks are the only changes.
- [ ] `just provision-common`.
- [ ] Re-run the confirm command — expect `enabled` ×3, `iscsid: active` ×3, `iscsi_tcp loaded: 1` ×3.
- [ ] Commit. This is a no-op for k3s today and is safe to merge on its own.

**Talos note:** this task is Ubuntu-only. On Talos the same requirement is met by the
`iscsi-tools` and `util-linux-tools` system extensions in the Image Factory schematic. Record
that in the audit doc so the Ansible task's replacement is not lost when `roles/common` is deleted.

**Rollback:** `systemctl disable --now iscsid`. Nothing depends on it yet.

---

## Phase 2 — Install Longhorn, no volumes

### Task 2: Deploy the Longhorn chart

- [ ] Create `system/longhorn-system/app.yaml`:
  ```yaml
  chartName: longhorn
  chartRepo: https://charts.longhorn.io
  chartVersion: 1.12.0
  syncWave: "1"
  ```
- [ ] Create `system/longhorn-system/values.yaml` with, at minimum:
  - `csi.kubeletRootDir: /var/lib/kubelet` (required, see constraints)
  - `defaultSettings.defaultReplicaCount: 2`
  - `defaultSettings.defaultDataLocality: best-effort`
  - `defaultSettings.defaultDataPath: /var/lib/longhorn`
  - `persistence.defaultClass: false` — **do not** let Longhorn become the cluster default
    StorageClass. `local-path` and `nfs` both stay in use; a silent default change would
    re-point any PVC that omits `storageClassName`.
  - `persistence.reclaimPolicy: Retain` — matches the `nfs` class, and means a mis-sync cannot
    delete a config database.
  - Explicit `resources.requests` on every component. Requestless containers are invisible to
    the scheduler; that is exactly how worker-00 became a hotspot (fixed 2026-07-31), and
    `system/nfs-provisioner/values.yaml` carries the same note.
  - `longhornUI.replicas: 1` — no HA needed for a UI you reach by port-forward.
- [ ] Create `system/longhorn-system/vpa.yaml` targeting the `longhorn-manager` DaemonSet.
- [ ] Validate before merge:
  `helm template longhorn longhorn/longhorn --version 1.12.0 -n longhorn-system -f system/longhorn-system/values.yaml | kubectl apply --dry-run=client -f -`
- [ ] Confirm the rendered namespace is `longhorn-system` everywhere. If anything renders
      `default` or `longhorn`, the directory name is wrong — stop and fix it.
- [ ] Merge to `main`. Refresh the `system` ApplicationSet (per
      `argocd_appset_refresh_for_chart_bumps` — an Application refresh is a no-op for a new
      `app.yaml`).
- [ ] `kubectl -n longhorn-system wait --for=condition=Ready pod --all --timeout=10m`
- [ ] `kubectl get nodes.longhorn.io -n longhorn-system` — all three schedulable, all three
      showing the disk on `/var/lib/longhorn`.
- [ ] `kubectl get sc` — `longhorn` present, and `local-path` still the only... confirm **no**
      class is marked default that was not before.

**Verify the Cilium interaction here, before any real data.** Longhorn's v1 engine attaches over
iSCSI to localhost, and `bootstrap/values/cilium.yaml` runs `kubeProxyReplacement: true` with
`socketLB.hostNamespaceOnly: false`. I found no documented incompatibility, but I could not
confirm compatibility either — so prove it with a throwaway volume:

- [ ] Create a scratch 1Gi `longhorn` PVC and a pod that writes and reads a file. Confirm attach,
      write, read, detach, delete.
- [ ] If attach hangs, test `socketLB.hostNamespaceOnly: true` on Cilium **in a deliberate
      window** — rolling the Cilium agent DaemonSet is how you get two agents writing the BPF LB
      maps at once (see the comment at the top of `bootstrap/values/cilium.yaml`). Do not do this
      as a side effect.

**Rollback:** delete `system/longhorn-system/`, merge, let ArgoCD prune. No volumes exist yet, so
nothing is lost. `deletingConfirmationFlag: false` will block the uninstall job — that is
correct and expected; set it true only for this deliberate teardown.

---

## Phase 3 — Pilot

### Task 3: Migrate Lidarr to Longhorn

Lidarr is the pilot: same shape as the other three arrs (SQLite `/config`, media nodeSelector,
pinned to worker-01), representative write workload, and the least costly library to lose. Its
config is ~240M against a 10Gi claim.

- [ ] Take a fresh backup from Lidarr's UI: System → Backup → Backup Now. Confirm the archive
      lands in `/data/backups/lidarr/` on NFS. **Do not proceed without this** — it is the entire
      rollback.
- [ ] Copy the archive somewhere off worker-01 as well. Pre-NAS, the backup and the source share
      a node.
- [ ] Edit `apps/lidarr/config-pvc.yaml`: `storageClassName: local-path` → `longhorn`, claim name
      `lidarr-config-local` → `lidarr-config`. Rewrite the comment block — the "no sync-wave
      annotation" warning still applies (`WaitForFirstConsumer`), but the `local-path` rationale
      is now the *old* rationale and the recovery path has changed.
- [ ] Edit `apps/lidarr/values.yaml`: `existingClaim` to match, and update its comment.
- [ ] Merge. ArgoCD creates the new PVC and rolls the pod, which comes up with an empty `/config`.
- [ ] Restore: Lidarr will start as a fresh install. Use System → Backup → Restore against the
      archive, or copy it in via `kubectl cp` and restore from disk.
- [ ] Confirm: indexers present, root folders present, library intact, no errors in
      System → Logs.
- [ ] Leave the old `lidarr-config-local` PVC in place. It is `Retain` and holds the pre-migration
      state; delete it only after Task 5 passes.

**Rollback:** revert the two files, merge, restore from the archive onto the recreated
`local-path` PVC. The old PVC is still there, so worst case is a revert with no restore needed.

---

## Phase 4 — Measure and decide

### Task 4: Benchmark the fsync tax

This is the gate. The whole question is whether 2-replica synchronous writes over 1GbE make
SQLite unacceptably slow. Measure it; do not argue about it.

- [ ] Run `fio` from a pod on worker-01 against a scratch PVC on **each** class, same node, same
      size. `--fdatasync=1` is the point — it is what SQLite does on every commit:
  ```
  fio --name=sqlite-ish --rw=randwrite --bs=4k --fdatasync=1 \
      --size=256M --runtime=60 --time_based --direct=0 --numjobs=1
  ```
- [ ] Record write IOPS and p99 latency for `local-path` and for `longhorn`. Write both numbers
      into this file — the next person deciding this deserves the data, not the conclusion.
- [ ] Watch Lidarr for one full cycle: a library refresh, an RSS sync, an import. Check
      System → Logs for `database is locked` — expect **zero**; if any appear, that is a hard fail,
      not a tuning problem.
- [ ] Check the task queue does not back up (the Sonarr-on-NFS failure mode was a 35-minute
      stalled refresh jamming the queue).

### Task 5: Go / no-go

**Go** if: zero `database is locked`, no queue stalls, and p99 fsync latency is within roughly
an order of magnitude of `local-path`. Proceed to Phase 5.

**No-go** if: any lock errors, any queue stall, or latency bad enough that Lidarr feels slow.
Then:
- [ ] Revert Lidarr to `local-path` (Task 3 rollback).
- [ ] Leave Longhorn installed or remove it — your call, but **record the numbers** in
      `docs/talos-migration-audit.md` and change §3's recommendation to "keep `local-path` on
      Talos, measured".
- [ ] Stop. This plan is complete with a negative result, which is a real result.

---

## Phase 5 — Roll out (only after a Go)

### Tasks 6–9: Migrate the remaining four

One task each, in this order — lowest stakes first, and **one per merge** so a problem is
attributable:

- [ ] **Task 6: Cleanuparr.** Cheapest — deployed 2026-08-07 with no runtime config, so there is
      nearly nothing to lose. Note it is on worker-00, not worker-01, so this is also the first
      test of the migration on the smallest-disk node. It has no built-in backup; its
      `backup-cronjob.yaml` is the restore path, and `apps/cleanuparr/values.yaml` sets `fsGroup`
      because `local-path` creates the volume root-owned — **verify Longhorn's ownership
      behaviour matches** or the container will not be able to write `/config`.
- [ ] **Task 7: Prowlarr.** Back up first. It syncs indexers to the other three, so verify those
      syncs still work afterwards.
- [ ] **Task 8: Radarr.** Back up first.
- [ ] **Task 9: Sonarr.** Last, because it is the busiest writer and the one with the documented
      996-lock-errors history. If anything is going to surface a latency problem the benchmark
      missed, it is this one. Watch it for a full day before Task 10.

### Task 10: Clean up and document

- [ ] Delete the five retained `*-config-local` PVCs and their `Retain`ed PVs, only after Sonarr
      has run clean for 24h.
- [ ] `CLAUDE.md`: amend the Storage section. Exception (1) becomes "SQLite databases go on
      `longhorn`" with the measured rationale; exceptions (2) CNPG and (3) reconstructible volumes
      stay `local-path` and should say explicitly *why they were not migrated*, so this is not
      relitigated.
- [ ] `docs/talos-migration-audit.md` §3: replace the `local-path`-on-Talos recommendation with
      Longhorn, and fold Task 1's Talos note (the two system extensions) into §5.
- [ ] Confirm Renovate is tracking the Longhorn chart — check the dependency dashboard after the
      next run.

---

## Out of scope, recorded so it is not re-asked

- Longhorn RWX. It works by running an NFS-Ganesha pod in front of an RWO volume — a single
  point of failure, and ironic given the direction of travel. RWX comes from the NFS share, and
  later the NAS.
- Longhorn backups to S3/NFS. The apps already back themselves up to `/data/backups/` and those
  archives are what the arrs' own restore flow accepts. A second backup system that produces
  volume snapshots the app cannot restore from is not an improvement.
- The v2 (SPDK) data engine. Needs hugepages and a lot more RAM; wrong fit for 15G nodes.
- CNPG, `nextcloud-html`, and anything on `nfs`. See Scope.
