# Longhorn Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `local-path` with Longhorn for eight volumes, so a node failure stops meaning a
hand restore from the newest backup archive.

**Architecture:** Longhorn 1.11.3 from its official chart into `system/longhorn-system/`, picked up
by the existing `system` ApplicationSet at sync wave 1. All three nodes are storage nodes,
`numberOfReplicas: 2`, `best-effort` data locality. Migration is per-app and per-merge: new
right-sized Longhorn PVC, copy Job between the two PVCs while the app is scaled to zero, then an
`existingClaim` swap. Cleanuparr rehearses the procedure; Lidarr carries a measured go/no-go gate
before the remaining six.

**Tech Stack:** k3s v1.36.3, ArgoCD (ApplicationSet + Helm multi-source), Longhorn chart 1.11.3,
Envoy Gateway v1.8.3, Infisical operator, kube-prometheus-stack, Cilium 1.19.5 with
`kubeProxyReplacement: true`, Ansible for the host prerequisite.

**Spec:** [`docs/superpowers/specs/2026-08-13-longhorn-deployment-design.md`](../specs/2026-08-13-longhorn-deployment-design.md)

This file replaces the 2026-08-10 plan (`git log --follow` for it). That plan predates
`docs/longhorn-evaluation.md` and disagreed with it on chart version, scope, UI, VPA, backups and
pilot app. Its fsync benchmark gate survives, in Phase 4.

## Global Constraints

- Chart `longhorn` `1.11.3` from `https://charts.longhorn.io`. **Not 1.12.0** — 1.11.3 shipped a
  month *after* 1.12.0 and carries #13413 "PVC resize fails after `iscsid` restart" plus #13411/#13383
  volume-expansion fixes, which 1.12.0 predates. Task 1 enables `iscsid`, and in-place expansion is
  what makes right-sizing safe, so both matter here. Full comparison in the spec.
- **Known gap in 1.11.3: #13152** — `dataLocality=best-effort` with insufficient local storage leaks
  Replica CRs on every recurring-job firing. Fixed in 1.12.0, and this cluster runs exactly that
  combination. Task 5 Step 6 and Task 16 Step 2 count Replica CRs for this reason. Revisit 1.12.x
  once 1.12.1 is GA (rc4 as of 11 Aug 2026) — it is the first release with both fix sets.
- **Directory must be `system/longhorn-system/`.** `bootstrap/root/templates/stack.yaml` hardcodes
  `destination.namespace: {{path.basename}}`, and Longhorn hardcodes `longhorn-system` in its own
  components. Wrong directory name installs a half-broken Longhorn.
- `numberOfReplicas: 2`, all three nodes as storage nodes, `defaultDataLocality: best-effort`,
  `defaultDataPath: /var/lib/longhorn`.
- **New PVCs are right-sized: 2Gi each, 3Gi for `nextcloud-html`.** Recreating one at its old size
  is a correctness error — 67Gi of claims does not fit on worker-00 and brings back the
  node-exclusion problem. Longhorn expands in place, so under-sizing is recoverable.
- `persistence.defaultClass: false` — Longhorn must **never** become the cluster default
  StorageClass. `local-path` stays default; `nfs` stays in use.
- `persistence.reclaimPolicy: Retain`.
- `defaultSettings.deletingConfirmationFlag` stays `false`. With ArgoCD `prune: true`, that flag is
  what stops a directory deletion from taking the volumes with it.
- CNPG cluster volumes and `jellyfin-config-local` are **out of scope**. Do not touch them.
- **No VPA for Longhorn.** Deliberate exception — `instance-manager` pods have no VPA-targetable
  controller, and restarting one breaks every volume attached on that node.
- Never `kubectl apply` an ArgoCD-managed manifest. ArgoCD syncs from `main`; merging to `main` is
  how things deploy. One-off migration Jobs are *not* managed and are applied directly — that is the
  only exception in this plan.
- Chart version in `app.yaml` is Renovate-managed. Never pin to `latest`.
- No `sleep`, in scripts or steps. Use `kubectl wait`.
- No `Co-Authored-By` trailers in commits.
- Every Longhorn component gets explicit `resources.requests`. A requestless container is invisible
  to the scheduler — that is how worker-00 became a hotspot (fixed 2026-07-31).

## Scope

| Volume | Namespace | Old claim (`local-path`) | New claim (`longhorn`) | Node today | App-level backup |
|---|---|---|---|---|---|
| `cleanuparr-config-local` → `cleanuparr-config` | `cleanuparr` | 2Gi | 2Gi | worker-00 | `backup-cronjob.yaml` |
| `lidarr-config-local` → `lidarr-config` | `lidarr` | 10Gi | 2Gi | worker-01 | System → Backup |
| `bazarr-config-local` → `bazarr-config` | `bazarr` | 5Gi | 2Gi | worker-01 | System → Backup |
| `navidrome-config-local` → `navidrome-config` | `navidrome` | 10Gi | 2Gi | worker-01 | **none** |
| `nextcloud-html` → `nextcloud-html-longhorn` | `nextcloud` | 10Gi | 3Gi | worker-01 | **none** |
| `prowlarr-config-local` → `prowlarr-config` | `prowlarr` | 10Gi | 2Gi | worker-01 | System → Backup |
| `radarr-config-local` → `radarr-config` | `radarr` | 10Gi | 2Gi | worker-01 | System → Backup |
| `sonarr-config-local` → `sonarr-config` | `sonarr` | 10Gi | 2Gi | worker-01 | System → Backup |

Out: `jellyfin-config-local` (its pin is wanted — QuickSync), all 12 CNPG cluster PVCs, everything
on `nfs`, Longhorn RWX, the v2 SPDK data engine.

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/common/tasks/main.yml` | **Modify.** Enable `iscsid`, load `iscsi_tcp` persistently |
| `renovate.json` | **Modify.** Add the `longhorn` packageRule with `dependencyDashboardApproval` |
| `system/longhorn-system/app.yaml` | **Create.** Chart coordinates, `syncWave: "1"` |
| `system/longhorn-system/values.yaml` | **Create.** All chart config: replicas, locality, CPU reservation, backup target, resources |
| `system/longhorn-system/httproute.yaml` | **Create.** UI route + Homepage annotations |
| `system/longhorn-system/securitypolicy.yaml` | **Create.** basicAuth on the route |
| `system/longhorn-system/infisical-secret.yaml` | **Create.** htpasswd secret, templated to key `.htpasswd` |
| `system/longhorn-system/recurringjob.yaml` | **Create.** Daily backup, retain 7 |
| `system/monitoring-system/servicemonitor-longhorn.yaml` | **Create.** Scrape `longhorn-backend`; lives here per the `argocd-servicemonitor.yaml` precedent |
| `system/monitoring-system/prometheusrule-longhorn.yaml` | **Create.** Three alerts |
| `apps/<app>/config-pvc.yaml` | **Modify** ×8. New Longhorn PVC alongside the retained old one |
| `apps/<app>/values.yaml` | **Modify** ×8. `replicas: 0` then `existingClaim` swap |
| `CLAUDE.md` | **Modify.** Storage section rewrite (not an amendment — see Task 17) |
| `docs/longhorn-evaluation.md` | **Modify.** Four superseded passages |
| `docs/talos-migration-audit.md` | **Modify.** §3 recommendation, §5 system extensions |

**There is no test framework in this repo.** The equivalent of a failing test is `helm template`
rendering wrong output, a `--dry-run=client` rejection, a rendered `Setting` CR carrying the wrong
value, or the `fio` gate failing. Every task therefore *confirms the current broken/absent state
first*, then changes it, then re-runs the same check.

---

## The Migration Runbook

Tasks 7, 8 and 10–15 all follow this. Read it once; each task supplies only its parameters and its
app-specific verification. `$APP` is the app name, `$NS` its namespace, both identical for all eight.

### Merge A — new PVC + scale to zero

Create `apps/$APP/config-pvc.yaml`'s **second** PVC (keep the existing one in the same file,
unchanged — it is the rollback and `prune: true` deletes it the moment it leaves git):

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $APP-config
  namespace: $NS
  # No sync-wave annotation. Unlike local-path, the longhorn class binds Immediate rather
  # than WaitForFirstConsumer, so this does not sit Pending waiting for a consumer -- but
  # there is still no reason to give a PVC a wave of its own.
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
```

Rewrite the comment block wholesale. The `local-path` rationale is now the *old* rationale, and the
documented recovery path changes: recovery is a Longhorn replica rebuild or a backup restore, not
"delete the PVC and unpack the newest archive". Keep the app-level backup sentence — it is still the
application-consistent copy.

In `apps/$APP/values.yaml`, set the controller to zero:

```yaml
controllers:
  main:
    replicas: 0    # temporary: Longhorn migration, see docs/superpowers/plans/2026-08-13-longhorn-deployment.md
```

Merge to `main`. Then:

```bash
kubectl -n $NS wait --for=delete pod -l app.kubernetes.io/name=$APP --timeout=5m
kubectl -n $NS get pvc                     # both PVCs present; $APP-config Bound
```

`$APP-config` must reach `Bound`, not `Pending`. If it is Pending, stop — the StorageClass or node
scheduling is wrong, and no data has moved yet.

### Copy

Take a fresh app-level backup **first** where one exists (System → Backup → Backup Now, confirm the
archive lands in `/data/backups/$APP/`). This is the rollback, not the mechanism. For Navidrome and
`nextcloud-html` there is none — the retained `local-path` PVC is the only rollback, which is why it
stays in git for two weeks.

Apply the copy Job directly. It is a one-off, not ArgoCD-managed:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: $APP-longhorn-copy
  namespace: $NS
spec:
  backoffLimit: 0        # a partial copy must not be retried on top of itself
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: copy
          image: alpine:3.22
          # -a preserves ownership and mtimes; SQLite does not care but the arrs' own
          # backup directory listings do. Trailing /. copies contents, not the directory.
          command:
            - sh
            - -euc
            - |
              cp -a /old/. /new/
              echo "--- old:" && du -sh /old && ls -la /old
              echo "--- new:" && du -sh /new && ls -la /new
          volumeMounts:
            - { name: old, mountPath: /old }
            - { name: new, mountPath: /new }
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits: { memory: 256Mi }
      volumes:
        - name: old
          persistentVolumeClaim: { claimName: $APP-config-local }
        - name: new
          persistentVolumeClaim: { claimName: $APP-config }
```

No `nodeName`. The old PV's node affinity forces the Job onto the right node by itself, and the
Longhorn volume attaches wherever the pod lands — one fewer thing to get wrong than hardcoding it.

```bash
kubectl -n $NS wait --for=condition=complete job/$APP-longhorn-copy --timeout=15m
kubectl -n $NS logs job/$APP-longhorn-copy      # the two du figures must match
kubectl -n $NS get pod -l job-name=$APP-longhorn-copy -o wide   # confirm the expected node
```

Matching `du` output is the check. If the Job failed, delete it and investigate — do **not** re-run
it over a partial copy without emptying `/new`.

### Merge B — swap and scale up

In `apps/$APP/values.yaml`: `existingClaim: $APP-config-local` → `$APP-config`, remove the
`replicas: 0` line, and update the comment above `persistence.config` — it currently explains
`local-path`.

Merge. Then verify, per app, using its own section in the task below. Generic floor:

```bash
kubectl -n $NS wait --for=condition=Ready pod -l app.kubernetes.io/name=$APP --timeout=10m
kubectl -n $NS exec deploy/$APP -- ls -la /config
kubectl get volumes.longhorn.io -n longhorn-system      # robustness=healthy, 2 replicas
```

Finally, delete the copy Job (`kubectl -n $NS delete job $APP-longhorn-copy`) so it stops showing up
in the CronJob-adjacent dashboards, and commit nothing further — the Job was never in git.

### Rollback

Revert Merge B (`existingClaim` back to `$APP-config-local`) and merge. The old PVC is still bound
and unmodified, so this is a revert with no restore needed. The app-level archive is the second
layer if the old volume itself turns out to be damaged.

### Expect alert noise

Every Merge A detaches a volume, and Longhorn recurring jobs are real CronJobs in
`longhorn-system`. `CronJobNotSucceeding` and `CronJobOverdue` will fire for that volume's job
during the window. This is expected and documented in the spec — do not silence `longhorn-system`
pre-emptively.

---

## Phase 1 — Host prerequisite

### Task 1: Enable `iscsid` on all three nodes

**Files:**
- Modify: `ansible/roles/common/tasks/main.yml` (after the "Install base packages" task, line ~129)

**Interfaces:**
- Consumes: nothing.
- Produces: `iscsid` active on all three nodes. Task 2 cannot attach a volume without it.

`roles/common` installs `open-iscsi` (line 120) and never enables the service. Longhorn's v1 data
engine attaches volumes over iSCSI to localhost; without the daemon, every attach fails with a
timeout that reads like a Longhorn bug.

- [ ] **Step 1: Confirm the failure**

```bash
just ping
ansible -i ansible/inventory.yml all -m shell \
  -a 'systemctl is-enabled iscsid; systemctl is-active iscsid; lsmod | grep -c iscsi_tcp' \
  --vault-password-file .vault_pass
```

Expected: `disabled` and `inactive` on all three, `0` modules loaded.

- [ ] **Step 2: Add the three tasks**

```yaml
# Longhorn's v1 data engine attaches every volume over iSCSI to localhost, so iscsid is a
# hard runtime dependency -- open-iscsi above ships the daemon disabled. A missing iscsid
# surfaces as a volume stuck in Attaching, which reads like a Longhorn bug.
# Talos equivalent: the iscsi-tools and util-linux-tools system extensions. See
# docs/talos-migration-audit.md before deleting this role.
- name: Load iscsi_tcp on boot
  ansible.builtin.copy:
    content: "iscsi_tcp\n"
    dest: /etc/modules-load.d/iscsi_tcp.conf
    mode: "0644"
  become: true

- name: Load iscsi_tcp now
  community.general.modprobe:
    name: iscsi_tcp
    state: present
  become: true

- name: Enable and start iscsid
  ansible.builtin.systemd_service:
    name: iscsid
    enabled: true
    state: started
  become: true
```

- [ ] **Step 3: Dry-run**

```bash
just dry-run
```

Expected: exactly three changed tasks per host, all three the ones above.

- [ ] **Step 4: Apply**

```bash
just provision-common
```

- [ ] **Step 5: Re-run the Step 1 check**

Expected: `enabled`, `active`, `1` on all three.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/common/tasks/main.yml
git commit -m "feat(ansible): enable iscsid for Longhorn

open-iscsi was installed and the daemon left disabled on all three nodes.
Longhorn's v1 engine attaches over iSCSI to localhost, so this is a hard
dependency whose absence looks like a Longhorn bug rather than a missing
service. No-op for k3s today, safe to merge alone."
```

**Rollback:** `systemctl disable --now iscsid`. Nothing depends on it yet.

---

## Phase 2 — Install Longhorn, no real data

### Task 2: Deploy the chart

**Files:**
- Create: `system/longhorn-system/app.yaml`, `system/longhorn-system/values.yaml`
- Modify: `renovate.json` (`packageRules`, after the nextcloud rule at line 21-27)

**Interfaces:**
- Consumes: Task 1's `iscsid`.
- Produces: StorageClass `longhorn`; namespace `longhorn-system`; `Setting` CRs. Every later task
  depends on this.

- [ ] **Step 1: Confirm the absent state**

```bash
kubectl get sc                       # local-path (default), nfs. No longhorn.
kubectl get ns longhorn-system       # NotFound
```

- [ ] **Step 2: Create `system/longhorn-system/app.yaml`**

```yaml
chartName: longhorn
chartRepo: https://charts.longhorn.io
# 1.11.3, not 1.12.0. 1.11.3 shipped a month *after* 1.12.0 and fixes "PVC resize fails after
# iscsid restart" (#13413) plus two volume-expansion bugs that 1.12.0 predates -- both of which
# this cluster depends on, since roles/common now restarts iscsid and every claim here is
# deliberately under-sized on the assumption expansion works.
#
# The trade: 1.12.0 fixes #13152, a Replica CR leak on best-effort locality plus recurring
# jobs, which is exactly this configuration. 1.12.1 is the first release with both; it was at
# rc4 on 2026-08-11. Revisit then -- as a deliberate upgrade, which is what
# dependencyDashboardApproval in renovate.json exists to force.
chartVersion: 1.11.3
syncWave: "1"
```

- [ ] **Step 3: Create `system/longhorn-system/values.yaml`**

```yaml
# k3s does not use the CSI default kubelet root, and a wrong value fails the plugin
# install quietly rather than loudly.
csi:
  kubeletRootDir: /var/lib/kubelet

defaultSettings:
  defaultDataPath: /var/lib/longhorn
  defaultReplicaCount: 2
  # Keeps a replica on the pod's own node when possible, so reads stay local and only the
  # second replica crosses the wire. This is the mitigation for the SQLite fsync tax that
  # Task 9 measures -- do not remove it.
  defaultDataLocality: best-effort
  # 12% of allocatable CPU is the default, charged on every node where a volume attaches,
  # not only where replicas live. On worker-00 (4C/4T, no HT) that is ~480m of reserved
  # request on the node that already loses to density.
  guaranteedInstanceManagerCpu: 5
  # ArgoCD runs prune: true. This flag is what stops deleting this directory from taking
  # the volumes with it. Set it true only for a deliberate teardown.
  deletingConfirmationFlag: false
  backupTarget: nfs://192.168.30.194:/mnt/storage/longhorn-backups
  upgradeChecker: false

persistence:
  # Never the cluster default. local-path stays default and nfs stays in use; a silent
  # default change would re-point every PVC that omits storageClassName -- including the
  # CNPG clusters, which must not land here.
  defaultClass: false
  defaultClassReplicaCount: 2
  defaultFsType: ext4
  reclaimPolicy: Retain

longhornUI:
  replicas: 1

# Requestless containers are invisible to the scheduler and count as free capacity, which
# is how worker-00 accumulated seventeen of them. Same note as system/nfs-provisioner.
longhornManager:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
longhornDriver:
  resources:
    requests: { cpu: 20m, memory: 64Mi }
```

Verify each key against `helm show values longhorn/longhorn --version 1.11.3` before merging —
particularly `guaranteedInstanceManagerCpu` casing and the `longhornManager`/`longhornDriver`
resource paths. **A wrong key is silently ignored.**

- [ ] **Step 4: Add the Renovate rule**

```json
{
  "description": "Longhorn upgrades are an ordered procedure with version-specific notes per release, not a chart to bump on sight. dependencyDashboardApproval means no PR opens until it is ticked.",
  "matchManagers": ["custom.regex"],
  "matchFileNames": ["system/longhorn-system/app.yaml"],
  "groupName": "longhorn",
  "automerge": false,
  "dependencyDashboardApproval": true
}
```

- [ ] **Step 5: Render and dry-run before merging**

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update longhorn
helm template longhorn longhorn/longhorn --version 1.11.3 -n longhorn-system \
  -f system/longhorn-system/values.yaml > /tmp/lh.yaml
kubectl apply --dry-run=client -f /tmp/lh.yaml
grep -c "namespace: longhorn-system" /tmp/lh.yaml     # non-zero
grep -n "namespace: default\|namespace: longhorn$" /tmp/lh.yaml   # must be empty
grep -A3 "guaranteed-instance-manager-cpu" /tmp/lh.yaml           # value must be "5"
grep -B2 -A6 "kind: StorageClass" /tmp/lh.yaml                    # not default, Retain, ext4
```

The `guaranteed-instance-manager-cpu` grep is the one that catches a mis-cased values key: the
rendered `Setting` CR either carries `5` or the key never landed.

- [ ] **Step 6: Merge and sync**

```bash
git add system/longhorn-system/ renovate.json
git commit -m "feat(longhorn): install 1.11.3 with two replicas on all three nodes

All three nodes are storage nodes rather than the evaluation's two: right-sizing
the new PVCs takes total claims from 67Gi to 17Gi, which removes the capacity
argument for excluding worker-00 and gives degraded volumes somewhere to
rebuild.

guaranteed-instance-manager-cpu drops to 5% because the default 12% is charged
wherever a volume attaches, not only where replicas live -- worker-00 pays it
either way."
```

Merge to `main`, then **refresh the `system` ApplicationSet** — an Application refresh is a no-op
for a new `app.yaml` (see the `argocd_appset_refresh_for_chart_bumps` note).

- [ ] **Step 7: Verify the running state**

```bash
kubectl -n longhorn-system wait --for=condition=Ready pod --all --timeout=10m
kubectl -n longhorn-system get nodes.longhorn.io -o wide
kubectl get sc                                   # longhorn present; local-path still the only default
kubectl -n longhorn-system get settings.longhorn.io guaranteed-instance-manager-cpu -o jsonpath='{.value}'
kubectl -n longhorn-system get pods -o wide | grep instance-manager
```

All three `nodes.longhorn.io` schedulable with a disk on `/var/lib/longhorn`. The settings value must
read `5`. Note which nodes have an `instance-manager` pod with no volumes attached yet — that answers
the spec's open question #3, so record it in the spec.

**Rollback:** delete `system/longhorn-system/`, merge, let ArgoCD prune. No volumes exist, nothing is
lost. `deletingConfirmationFlag: false` blocks the uninstall job — that is correct; flip it only for
this deliberate teardown.

---

### Task 3: Prove Cilium and iSCSI-to-localhost work

**Files:** none committed. Throwaway manifests applied directly.

**Interfaces:**
- Consumes: Task 2's StorageClass.
- Produces: a go/no-go on the whole plan. Nothing else runs if attach hangs.

`bootstrap/values/cilium.yaml` runs `kubeProxyReplacement: true` with
`socketLB.hostNamespaceOnly: false`. There is no documented incompatibility with Longhorn's
iSCSI-to-localhost attach, and no documented confirmation either. This is the cheapest test in the
plan and it happens before any real data exists.

- [ ] **Step 1: Apply a scratch volume and writer**

```bash
kubectl create ns lh-scratch
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: scratch, namespace: lh-scratch }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: scratch, namespace: lh-scratch }
spec:
  containers:
    - name: w
      image: alpine:3.22
      command: [sh, -euc, "echo hello-longhorn > /d/f && sync && cat /d/f && sleep infinity"]
      volumeMounts: [{ name: d, mountPath: /d }]
      resources:
        requests: { cpu: 50m, memory: 32Mi }
        limits: { memory: 128Mi }
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: scratch }
EOF
```

(The `sleep infinity` here is a container keeping itself alive for inspection, not a wait in a
script — the no-`sleep` rule is about the latter.)

- [ ] **Step 2: Confirm attach, write, read**

```bash
kubectl -n lh-scratch wait --for=condition=Ready pod/scratch --timeout=5m
kubectl -n lh-scratch logs scratch                  # hello-longhorn
kubectl -n longhorn-system get volumes.longhorn.io  # attached, robustness=healthy, 2 replicas
```

- [ ] **Step 3: Confirm detach and delete**

```bash
kubectl -n lh-scratch delete pod scratch --wait=true
kubectl -n longhorn-system get volumes.longhorn.io    # detached, not stuck Detaching
kubectl delete ns lh-scratch
```

- [ ] **Step 4: Also confirm it attaches on worker-00**

Re-run Steps 1–3 with `nodeName: worker-00` on the pod. worker-00 is the node Cleanuparr lives on
and the one with the least headroom; if the CNI interaction breaks anywhere, it breaks there.

**If attach hangs:** the thing to try is `socketLB.hostNamespaceOnly: true` in
`bootstrap/values/cilium.yaml`. Rolling the Cilium agent DaemonSet is how two agents end up writing
the BPF LB maps at once (see the comment at the top of that file, and the dangling-BPF-backends
incident). Do it in a deliberate window with console access, never as a side effect of debugging.
If it cannot be made to work, stop the plan here and revert Task 2.

- [ ] **Step 5: Record the result in the spec**

Add one line under "Verify before writing manifests" marking the Cilium question resolved, with the
date. Commit that alone.

---

### Task 4: UI route with basicAuth

**Files:**
- Create: `system/longhorn-system/httproute.yaml`, `system/longhorn-system/securitypolicy.yaml`,
  `system/longhorn-system/infisical-secret.yaml`

**Interfaces:**
- Consumes: Task 2's `longhorn-frontend` Service; the `homelab` Gateway in `envoy-gateway-system`.
- Produces: `https://longhorn.nik-homelab.dev` behind basic auth.

`*.nik-homelab.dev` resolves publicly to `192.168.30.200`, a private address — so this is LAN and
tailnet reachable, not internet reachable. Longhorn's dashboard still has no authentication of its
own and can delete volumes, making it the only app here with no login.

- [ ] **Step 1: Generate the htpasswd content**

```bash
htpasswd -cbs /tmp/.htpasswd admin "$(openssl rand -base64 24)"   # -s: SHA. NOT bcrypt.
cat /tmp/.htpasswd
```

**Only the SHA algorithm is supported.** Modern `htpasswd` defaults to bcrypt, which Envoy rejects.
Store the generated password in Infisical alongside the hash line, then `rm /tmp/.htpasswd`.

- [ ] **Step 2: Put it in Infisical**

In the UI, project `homelab-ef-28`, environment `prod`, path `/longhorn-system/longhorn-ui-auth`:
key `HTPASSWD` with the full `admin:{SHA}...` line as its value. A leading-dot key name is not
valid in Infisical, which is why the template in the next step exists.

- [ ] **Step 3: Create `system/longhorn-system/infisical-secret.yaml`**

```yaml
apiVersion: secrets.infisical.com/v1beta1
kind: InfisicalStaticSecret
metadata:
  name: longhorn-ui-auth
  namespace: longhorn-system
spec:
  infisicalAuthRef:
    name: infisical-auth
    namespace: infisical
  syncOptions:
    refreshInterval: 60s
  sources:
    - projectSlug: homelab-ef-28
      environmentSlug: prod
      secretPath: /longhorn-system/longhorn-ui-auth
  targets:
    - name: longhorn-ui-auth
      namespace: longhorn-system
      kind: Secret
      creationPolicy: Owner
      # Envoy Gateway requires the htpasswd file under the literal key `.htpasswd`, and an
      # Infisical secret name cannot start with a dot. First use of `template` in this repo.
      template:
        engineVersion: v1
        data:
          .htpasswd: "{{ .HTPASSWD.Value }}"
```

- [ ] **Step 4: Create `system/longhorn-system/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Longhorn"
    gethomepage.dev/description: "Replicated block storage"
    gethomepage.dev/group: "Infrastructure"
    gethomepage.dev/icon: "longhorn.png"
    gethomepage.dev/href: "https://longhorn.nik-homelab.dev"
spec:
  parentRefs:
    - name: homelab
      namespace: envoy-gateway-system
  hostnames:
    - longhorn.nik-homelab.dev
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: longhorn-frontend
          port: 80
```

Confirm the Service name and port with
`kubectl -n longhorn-system get svc longhorn-frontend -o wide` before merging.

- [ ] **Step 5: Create `system/longhorn-system/securitypolicy.yaml`**

```yaml
# Longhorn's dashboard ships with no authentication and can delete volumes. The hostnames
# resolve to 192.168.30.200 (private), so this is LAN/tailnet exposure rather than
# internet -- but it is the only app here with no login of its own.
#
# One SecurityPolicy per targetRef, and it must live in the targetRef's namespace.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: longhorn-ui-auth
  namespace: longhorn-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: longhorn-ui
  basicAuth:
    users:
      name: longhorn-ui-auth
```

- [ ] **Step 6: Merge and verify the secret key landed**

```bash
kubectl -n longhorn-system get secret longhorn-ui-auth -o jsonpath='{.data}' | tr ',' '\n'
```

Must show `.htpasswd`. If the `template` block did not work, the fallback is a
`secrets/registry.tsv` row sealed with `kubeseal` — legitimate here, since "Infisical cannot express
this key" is exactly what that exception is for.

- [ ] **Step 7: Verify enforcement**

```bash
kubectl -n longhorn-system get securitypolicy longhorn-ui-auth -o jsonpath='{.status.conditions}'
curl -so /dev/null -w '%{http_code}\n' https://longhorn.nik-homelab.dev/        # 401
curl -so /dev/null -w '%{http_code}\n' -u admin:<password> https://longhorn.nik-homelab.dev/  # 200
```

A `401` before a `200` is the test. If it returns `200` unauthenticated, the policy is not attached —
check the status conditions and that both objects are in `longhorn-system`.

- [ ] **Step 8: Commit**

```bash
git add system/longhorn-system/
git commit -m "feat(longhorn): expose the UI behind basic auth

Longhorn is the only app here with no login of its own, and the dashboard can
delete volumes. Envoy Gateway's basicAuth needs the htpasswd file under the
literal key .htpasswd, which an Infisical secret name cannot be -- hence the
first use of the operator's target template in this repo. Only the SHA hash
algorithm is supported; htpasswd's bcrypt default is rejected."
```

---

### Task 5: Backup target and the daily job

**Files:**
- Create: `system/longhorn-system/recurringjob.yaml`
- (`backupTarget` already set in Task 2's values)

**Interfaces:**
- Consumes: Task 2's install; the NFS export at `192.168.30.194:/mnt/storage`.
- Produces: a daily backup of every volume in the `default` group.

- [ ] **Step 1: Create the target directory on the NFS server**

```bash
ssh worker-01 'sudo mkdir -p /mnt/storage/longhorn-backups && sudo chmod 777 /mnt/storage/longhorn-backups && ls -ld /mnt/storage/longhorn-backups'
```

- [ ] **Step 2: Confirm Longhorn accepts the target**

```bash
kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status}' | python3 -m json.tool
```

`available: true`. If false, the message names the cause — almost always export permissions or a
missing `nfs-common` (present on all three nodes as of 2026-08-13).

- [ ] **Step 3: Create `system/longhorn-system/recurringjob.yaml`**

```yaml
# Daily at 04:30 -- after the 03:30/03:45 database dumps and the apps' own backups, so each
# Longhorn backup captures fresh archives from inside the volumes.
#
# A `backup` job takes a snapshot on its way, so there is no separate snapshot schedule.
# That is deliberate: Longhorn snapshots live on the volume's own replicas, which makes a
# snapshot-only schedule the one form of protection a node failure takes with it.
#
# This does not replace the apps' own backups. Longhorn's are crash-consistent; the arrs'
# System -> Backup quiesces its own database and produces an archive its restore flow
# accepts. Both stay. For navidrome and nextcloud-html this is the *only* backup, which is
# why it is in scope now rather than deferred to the NAS.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "30 4 * * *"
  task: backup
  groups:
    - default
  retain: 7
  concurrency: 1
```

Confirm `spec` field names against
`kubectl explain recurringjob.spec --recursive` before merging.

- [ ] **Step 4: Merge, then confirm the CronJob materialised**

```bash
kubectl -n longhorn-system get recurringjob daily-backup
kubectl -n longhorn-system get cronjobs
```

Longhorn renders each recurring job as a Kubernetes CronJob, which is what makes the existing
generic `CronJobNotSucceeding` / `CronJobOverdue` / `CronJobJobFailed` rules cover backups for free.
It is also why every Merge A in Phase 3+ produces alert noise.

- [ ] **Step 5: Force one run and verify the backupstore**

Longhorn names these CronJobs after the volume, not after the RecurringJob, so read the name from
`kubectl -n longhorn-system get cronjobs` rather than constructing it:

```bash
kubectl -n longhorn-system create job --from=cronjob/$(kubectl -n longhorn-system get cronjobs -o name | head -1 | cut -d/ -f2) lh-backup-manual
kubectl -n longhorn-system wait --for=condition=complete job/lh-backup-manual --timeout=15m
kubectl -n longhorn-system get backups.longhorn.io
ssh worker-01 'ls -R /mnt/storage/longhorn-backups | head -30'
```

- [ ] **Step 6: Record the Replica CR count — the #13152 watch**

1.11.3 does not have 1.12.0's fix for `dataLocality: best-effort` leaking N Replica CRs per
recurring-job firing when a node has insufficient local storage. This cluster runs exactly that
combination, and worker-00 is the plausible insufficient-storage node. The leak is invisible until
`kubectl get replicas.longhorn.io` is absurd, so establish the baseline now:

```bash
kubectl -n longhorn-system get replicas.longhorn.io --no-headers | wc -l
kubectl -n longhorn-system get volumes.longhorn.io --no-headers | wc -l
```

Expected: replicas ≈ 2 × volumes. Write both numbers into this step. Re-run it after the first two
or three nightly firings — a count that climbs with no new volumes is the leak, and the fix is to
upgrade to 1.12.1 rather than to abandon `best-effort` (which is the fsync-tax mitigation).

- [ ] **Step 7: Commit**

```bash
git add system/longhorn-system/recurringjob.yaml
git commit -m "feat(longhorn): daily backup to the NFS share, retain 7

Reverses the 2026-08-10 plan's decision to leave Longhorn backups out of scope.
That argument holds for the arrs, which back themselves up in a format their own
restore flow accepts -- it does not hold for navidrome and nextcloud-html, which
have no app-level backup at all. Pre-NAS the target is the USB disk on
worker-01, so this is a second disk rather than a second host; the NAS makes it
a real backup with one setting change."
```

**Note for the NAS phase:** repointing means changing `defaultSettings.backupTarget` and nothing
else. The existing backups stay readable from the old path only if the data is copied across.

---

### Task 6: ServiceMonitor and alerts

**Files:**
- Create: `system/monitoring-system/servicemonitor-longhorn.yaml`,
  `system/monitoring-system/prometheusrule-longhorn.yaml`

**Interfaces:**
- Consumes: Task 2's `longhorn-backend` Service.
- Produces: `longhorn_*` series in Prometheus and three alert rules.

Monitors live in `system/monitoring-system/` with a `namespaceSelector`, per
`argocd-servicemonitor.yaml` and `podmonitor-cnpg.yaml` — not in the app's namespace, and not via
the chart's own flag. `serviceMonitorSelectorNilUsesHelmValues: false` means the `release` label is
not strictly required, but every existing monitor carries it, so keep it.

- [ ] **Step 1: Find the real port name and metric names**

```bash
kubectl -n longhorn-system get svc longhorn-backend -o yaml | grep -A4 ports
kubectl -n longhorn-system port-forward svc/longhorn-backend 9500:9500 &
curl -s localhost:9500/metrics | grep -E "^longhorn_(volume_robustness|node_storage)" | head
```

Write the exact names down before Step 3. Do not guess them.

- [ ] **Step 2: Create the ServiceMonitor**

```yaml
---
# Longhorn's manager exposes metrics on the longhorn-backend Service. Lives here rather than
# in longhorn-system for the same reason as argocd-servicemonitor.yaml: monitors are kept
# with the monitoring stack, selected by namespace.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn
  namespace: monitoring-system
  labels:
    release: monitoring-system
spec:
  namespaceSelector:
    matchNames:
      - longhorn-system
  selector:
    matchLabels:
      app: longhorn-manager
  endpoints:
    - port: manager
      path: /metrics
```

Correct `selector.matchLabels` and `endpoints.port` from Step 1's output.

- [ ] **Step 3: Create the PrometheusRule**

Match the house style of `prometheusrule-backups.yaml`: a header comment explaining what is watched
and what is deliberately not, and each rule carrying the diagnostic next step in its description.

```yaml
---
# Three rules, not more. Node-down is already covered by kube-state-metrics, and per-volume
# IOPS is a dashboard question rather than an alert.
#
# Backup coverage comes for free and is deliberately not duplicated here: Longhorn renders
# each RecurringJob as a Kubernetes CronJob in longhorn-system, so CronJobNotSucceeding,
# CronJobOverdue and CronJobJobFailed in prometheusrule-backups.yaml already watch them.
# BackupCronJobMissing's `.+-db-backup` regex does not match them on purpose -- a per-volume
# expected count would need editing on every migration, and VolumeDegraded covers the same
# ground from the other direction.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: longhorn
  namespace: monitoring-system
  labels:
    release: monitoring-system
spec:
  groups:
    - name: longhorn
      rules:
        # With two replicas this is the only warning before faulted, which is the whole
        # reason the ServiceMonitor exists. 30m rather than 5m: a node reboot degrades every
        # volume on it briefly and rebuilds without help.
        - alert: LonghornVolumeDegraded
          expr: longhorn_volume_robustness == 2
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: Longhorn volume {{ $labels.volume }} has been degraded for 30m
            description: >-
              One replica is missing or rebuilding. Three nodes are storage nodes, so a
              healthy cluster re-places the replica on its own; 30m without that points at a
              node being down or out of space. Check
              `kubectl -n longhorn-system get nodes.longhorn.io` for schedulability and
              `kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume={{ $labels.volume }}`
              for which replica is missing.
        - alert: LonghornVolumeFaulted
          expr: longhorn_volume_robustness == 3
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: Longhorn volume {{ $labels.volume }} is faulted
            description: >-
              No usable replica -- the volume is down and its app is already broken. The
              recovery path is a restore from the backupstore
              (`kubectl -n longhorn-system get backups.longhorn.io`), or the app's own
              archive in /data/backups/ if it has one. Check whether autoSalvage has left a
              replica marked failed but intact before restoring.
        - alert: LonghornNodeStorageFull
          expr: >-
            longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes > 0.8
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: Longhorn storage on {{ $labels.node }} is {{ $value | humanizePercentage }} full
            description: >-
              /var/lib/longhorn shares the root LV, so Longhorn filling this disk takes k3s
              with it. worker-00 is the node to watch (69G free at install). Longhorn stops
              scheduling replicas below storageMinimalAvailablePercentage before it fills the
              disk, so this firing means either real growth or a claim sized far above its
              real usage -- check `kubectl get pvc -A | grep longhorn`.
```

Adjust metric names to Step 1's actual output, including the `robustness` value encoding —
confirm `2` is degraded and `3` is faulted against the live series rather than trusting this file.

- [ ] **Step 4: Validate before merge**

```bash
kubectl apply --dry-run=client -f system/monitoring-system/prometheusrule-longhorn.yaml
kubectl apply --dry-run=client -f system/monitoring-system/servicemonitor-longhorn.yaml
```

- [ ] **Step 5: Merge, then confirm scrape and rules**

```bash
kubectl -n monitoring-system exec sts/prometheus-monitoring-system-kube-prometheus -c prometheus -- \
  wget -qO- 'localhost:9090/api/v1/query?query=longhorn_volume_robustness'
```

There is no shell in the Prometheus pod for anything fancier — `wget` is what exists. Expect a
non-empty result once Task 3's scratch volume or a real volume exists.

- [ ] **Step 6: Trip-test one rule**

Temporarily change `LonghornVolumeDegraded`'s expr to something always-true with an invented
severity that routes nowhere, confirm it appears in Alertmanager (`amtool` lives in the
Alertmanager pod, not Prometheus's), then revert. This is the documented way to validate alert
changes here without paging anyone.

- [ ] **Step 7: Commit**

```bash
git add system/monitoring-system/servicemonitor-longhorn.yaml system/monitoring-system/prometheusrule-longhorn.yaml
git commit -m "feat(monitoring): watch Longhorn volumes and node storage

Three rules. Degraded is the important one: with two replicas it is the only
warning before faulted.

Backups are deliberately not alerted here -- Longhorn renders each RecurringJob
as a real CronJob, so the generic rules in prometheusrule-backups.yaml already
cover them, and a per-volume expected count would need editing on every
migration."
```

---

## Phase 3 — Rehearsal

### Task 7: Migrate Cleanuparr

**Files:**
- Modify: `apps/cleanuparr/config-pvc.yaml` (add the second PVC; keep the existing one)
- Modify: `apps/cleanuparr/values.yaml` (`replicas: 0`, then `existingClaim` at line 62)

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces: a proven procedure, and the answer to Longhorn's volume-ownership behaviour that
  Tasks 8–15 depend on.

Cleanuparr is the rehearsal: 1.5 MB of settings, deployed 2026-08-07 with almost no runtime
configuration, so it is the least costly thing in the cluster to get wrong. It is also the only one
of the eight on **worker-00**, which makes it the first real test of attach on the tightest node.

It cannot be the measurement pilot — near-zero write traffic and the wrong node. That is Task 8.

**The specific thing this rehearsal is for:** `apps/cleanuparr/values.yaml` sets `fsGroup: 1000`
(line 10) with a comment saying `local-path` creates the volume directory root-owned. Longhorn's
ownership behaviour is different and unverified. If `/config` comes up unwritable, that is a finding
that changes Tasks 8–15, not a Cleanuparr-specific bug.

- [ ] **Step 1: Confirm the starting state**

```bash
kubectl -n cleanuparr get pvc
kubectl -n cleanuparr get pod -o wide                  # on worker-00
kubectl -n cleanuparr exec deploy/cleanuparr -- sh -c 'ls -la /config && du -sh /config'
```

Record the `du` figure and the ownership of `/config` — both are the comparison for Step 6.

- [ ] **Step 2: Merge A — add the Longhorn PVC and scale to zero**

Append to `apps/cleanuparr/config-pvc.yaml`, keeping the existing `cleanuparr-config-local` PVC
exactly as it is:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cleanuparr-config
  namespace: cleanuparr
  # No sync-wave annotation. The longhorn class binds Immediate rather than
  # WaitForFirstConsumer, so unlike the local-path PVC above this does not sit Pending
  # waiting for a consumer -- but a PVC still has no reason to own a wave.
spec:
  accessModes:
    - ReadWriteOnce
  # longhorn, not local-path: /config is SQLite, and SQLite needs a real block device with a
  # real filesystem -- which Longhorn provides and NFS does not. Two replicas across
  # worker-01 and worker-02 (best-effort locality keeps one on whichever node the pod runs),
  # so losing a node degrades this volume instead of taking it offline.
  #
  # Durability still does not come from the volume. backup-cronjob.yaml is the
  # application-consistent copy -- Cleanuparr has no built-in backup, and Longhorn's own
  # backups are crash-consistent, so that CronJob has to keep existing.
  #
  # Recovery if a node dies: nothing to do, the replica rebuilds. If the volume is faulted,
  # restore from the Longhorn backupstore (retained 7 days) or extract the newest archive
  # from /data/backups/cleanuparr/ into /config.
  #
  # 2Gi against 1.5 MB of settings, and longhorn expands in place, so this is not sized once.
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
```

In `apps/cleanuparr/values.yaml`, under `controllers.main`:

```yaml
    replicas: 0    # temporary: Longhorn migration, docs/superpowers/plans/2026-08-13-longhorn-deployment.md
```

```bash
git add apps/cleanuparr/
git commit -m "feat(cleanuparr): add the Longhorn config PVC, scale to zero

Merge A of the migration. The local-path PVC stays in git as the rollback -- ArgoCD
prunes it the moment the manifest leaves, and it is the only rollback Cleanuparr
has that does not depend on the backup CronJob's archive being good."
```

Merge, then:

```bash
kubectl -n cleanuparr wait --for=delete pod -l app.kubernetes.io/name=cleanuparr --timeout=5m
kubectl -n cleanuparr get pvc                          # cleanuparr-config Bound, not Pending
```

- [ ] **Step 3: Take the pre-migration backup**

```bash
kubectl -n cleanuparr create job --from=cronjob/cleanuparr-db-backup cleanuparr-premigration
kubectl -n cleanuparr wait --for=condition=complete job/cleanuparr-premigration --timeout=10m
ssh worker-01 'ls -lt /mnt/storage/cleanuparr/backups 2>/dev/null || ls -lt /mnt/storage/*/backups/cleanuparr* 2>/dev/null | head'
```

Find the real archive path from the CronJob's own spec if that guess is wrong
(`kubectl -n cleanuparr get cronjob cleanuparr-db-backup -o yaml`). Do not proceed without a
timestamped archive from today.

- [ ] **Step 4: Run the copy Job**

Apply the Job from the Migration Runbook with `$APP=cleanuparr`, `$NS=cleanuparr`. Then:

```bash
kubectl -n cleanuparr wait --for=condition=complete job/cleanuparr-longhorn-copy --timeout=15m
kubectl -n cleanuparr logs job/cleanuparr-longhorn-copy
kubectl -n cleanuparr get pod -l job-name=cleanuparr-longhorn-copy -o wide    # worker-00
```

The two `du` figures in the log must match. **Also record the ownership shown in the `new:`
listing** — that is the `fsGroup` answer.

- [ ] **Step 5: Merge B — swap and scale up**

In `apps/cleanuparr/values.yaml`: `existingClaim: cleanuparr-config-local` → `cleanuparr-config`,
remove the `replicas: 0` line, and rewrite the comment above `persistence.config` (it currently
explains `local-path`).

```bash
git add apps/cleanuparr/values.yaml
git commit -m "feat(cleanuparr): switch /config to the Longhorn volume

Merge B. Rehearses the procedure the other seven follow, on the only one of the
eight that lives on worker-00 -- so this is also the first attach test on the
tightest node."
```

- [ ] **Step 6: Verify**

```bash
kubectl -n cleanuparr wait --for=condition=Ready pod -l app.kubernetes.io/name=cleanuparr --timeout=10m
kubectl -n cleanuparr exec deploy/cleanuparr -- sh -c 'ls -la /config && du -sh /config'
kubectl -n cleanuparr logs deploy/cleanuparr --tail=50
kubectl -n longhorn-system get volumes.longhorn.io      # healthy, 2 replicas
```

`du` matches Step 1. Ownership permits writes — if the app logs a permissions error on `/config`,
stop and resolve it here, because it applies to all seven remaining apps.

Then in the UI: the arr URLs, API keys and job settings are still present, and a job runs.

- [ ] **Step 7: Clean up the Job and record the findings**

```bash
kubectl -n cleanuparr delete job cleanuparr-longhorn-copy cleanuparr-premigration
```

Add to the spec's verification list: Longhorn's `/config` ownership behaviour versus `fsGroup`, and
whether `instance-manager` on worker-00 behaved. Commit that alone.

**Rollback:** revert Merge B, merge. The old PVC is bound and untouched.

**Do not delete `cleanuparr-config-local` yet.** Two weeks, Task 16.

---

## Phase 4 — Measure and decide

### Task 8: Migrate Lidarr

**Files:**
- Modify: `apps/lidarr/config-pvc.yaml`, `apps/lidarr/values.yaml` (`existingClaim` at line 70)

**Interfaces:**
- Consumes: Task 7's proven procedure and ownership finding.
- Produces: a real SQLite writer on Longhorn, on worker-01, for Task 9 to measure.

Lidarr is the measurement pilot: same shape as the other three arrs, on worker-01 with the other
six, a representative write workload, and the least costly library to lose. Note the size
discrepancy to resolve — `apps/lidarr/config-pvc.yaml` says "~240M config", the evaluation says
35 MB. Both fit in 2Gi; record which is right.

- [ ] **Step 1: Confirm the starting state and get the real size**

```bash
kubectl -n lidarr exec deploy/lidarr -- sh -c 'du -sh /config && du -sh /config/* | sort -h | tail -5'
kubectl -n lidarr get pod -o wide
```

- [ ] **Step 2: Take a fresh backup from the UI**

Lidarr → System → Backup → Backup Now. Confirm the archive:

```bash
ssh worker-01 'ls -lt /mnt/storage/lidarr/backups/manual/ | head -3'
```

**Do not proceed without this.** It is the rollback layer that survives the old volume being wrong.
Copy it somewhere off worker-01 as well — pre-NAS, the source and the backup share a node.

- [ ] **Step 3: Merge A**

Add the `lidarr-config` PVC to `apps/lidarr/config-pvc.yaml` (2Gi, `storageClassName: longhorn`,
comment rewritten as in Task 7 Step 2 — Lidarr's recovery path becomes "replica rebuilds; if
faulted, restore the newest zip from `/data/backups/lidarr/scheduled/` via System → Backup →
Restore"), keep `lidarr-config-local`, and set `replicas: 0` in `apps/lidarr/values.yaml`.

Merge, then:

```bash
kubectl -n lidarr wait --for=delete pod -l app.kubernetes.io/name=lidarr --timeout=5m
kubectl -n lidarr get pvc
```

- [ ] **Step 4: Copy**

Runbook Job with `$APP=lidarr`, `$NS=lidarr`. Verify matching `du` and that the pod landed on
worker-01.

- [ ] **Step 5: Merge B**

`existingClaim: lidarr-config-local` → `lidarr-config`, drop `replicas: 0`, rewrite the
`persistence.config` comment.

- [ ] **Step 6: Verify Lidarr specifically**

```bash
kubectl -n lidarr wait --for=condition=Ready pod -l app.kubernetes.io/name=lidarr --timeout=10m
```

In the UI, confirm all of: indexers present, download client present, root folders present, artist
list intact, and **System → Logs clean of `database is locked`**. The metadata profiles matter here —
the `dj` profile and Adventure Club's `monitorNewItems=none` are UI-only state that lives nowhere
in git, so their absence would mean the copy did not take.

```bash
kubectl -n lidarr logs deploy/lidarr --tail=100 | grep -ci "database is locked"    # 0
```

- [ ] **Step 7: Commit and clean up the Job**

```bash
kubectl -n lidarr delete job lidarr-longhorn-copy
```

**Rollback:** revert Merge B. Failing that, recreate `local-path` and restore the Step 2 archive.

---

### Task 9: Benchmark the fsync tax and decide

**Files:** none. Findings are written into this plan file and the spec.

**Interfaces:**
- Consumes: Task 8's live Lidarr on Longhorn.
- Produces: the go/no-go for Phase 5. **Nothing in Phase 5 starts before this passes.**

This is the gate. The whole open question is whether two-replica synchronous writes over 1GbE — a
link that also carries VXLAN and all NFS traffic — make SQLite unacceptably slow. Measure it; do not
argue about it.

- [ ] **Step 1: Create two scratch PVCs, one per class**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: lh-bench }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: bench-longhorn, namespace: lh-bench }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 2Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: bench-localpath, namespace: lh-bench }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 2Gi } }
EOF
```

- [ ] **Step 2: Run fio against each, pinned to worker-01**

Same node, same size, same flags. `--fdatasync=1` is the point — it is what SQLite does on every
commit, and it is the only number that matters here:

```bash
for class in longhorn localpath; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: fio-$class, namespace: lh-bench }
spec:
  nodeName: worker-01
  restartPolicy: Never
  containers:
    - name: fio
      image: alpine:3.22
      command:
        - sh
        - -euc
        - |
          apk add --no-cache fio >/dev/null
          fio --name=sqlite-ish --directory=/d --rw=randwrite --bs=4k \
              --fdatasync=1 --size=256M --runtime=60 --time_based \
              --direct=0 --numjobs=1 --group_reporting
      volumeMounts: [{ name: d, mountPath: /d }]
      resources:
        requests: { cpu: 500m, memory: 256Mi }
        limits: { memory: 1Gi }
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: bench-$class }
EOF
done
```

```bash
kubectl -n lh-bench wait --for=jsonpath='{.status.phase}'=Succeeded pod/fio-longhorn --timeout=10m
kubectl -n lh-bench wait --for=jsonpath='{.status.phase}'=Succeeded pod/fio-localpath --timeout=10m
kubectl -n lh-bench logs fio-longhorn   | grep -E "write:|fsync/fdatasync|99.00th"
kubectl -n lh-bench logs fio-localpath  | grep -E "write:|fsync/fdatasync|99.00th"
```

- [ ] **Step 3: Write both numbers into this file**

Fill this in — the next person deciding this deserves the data, not the conclusion:

```
| Class      | write IOPS | fdatasync p99 |
|------------|-----------:|--------------:|
| local-path |            |               |
| longhorn   |            |               |
```

- [ ] **Step 4: Watch Lidarr through a full cycle**

A library refresh, an RSS sync, and an import. Then:

```bash
kubectl -n lidarr logs deploy/lidarr --since=24h | grep -ci "database is locked"
```

Expect **zero**. Also confirm the task queue does not back up — the Sonarr-on-NFS failure mode was a
35-minute stalled refresh jamming the queue until `/api/v3/queue` stopped answering.

- [ ] **Step 5: Clean up**

```bash
kubectl delete ns lh-bench
```

- [ ] **Step 6: Decide, and record the decision**

**Go** — zero lock errors, no queue stall, fdatasync p99 within roughly an order of magnitude of
`local-path`. Proceed to Phase 5.

**No-go** — any lock errors, any queue stall, or latency bad enough that Lidarr feels slow. Then:

- [ ] Roll Lidarr back (Task 8 rollback) and Cleanuparr too (Task 7 rollback).
- [ ] Write the measured numbers into `docs/talos-migration-audit.md` §3 and change its
      recommendation to "keep `local-path` on Talos, measured".
- [ ] Update `docs/longhorn-evaluation.md`'s "Do nothing" section: it is now the chosen option, with
      data behind it.
- [ ] Decide separately whether to leave Longhorn installed. Either is fine; if removing it, Task 2's
      rollback applies plus `deletingConfirmationFlag: true` for the teardown.
- [ ] **Stop.** This plan is complete with a negative result. That is a real result, and it cost two
      small volumes and a day.

Commit the numbers either way:

```bash
git add docs/superpowers/plans/2026-08-13-longhorn-deployment.md
git commit -m "docs(longhorn): record the measured fsync numbers"
```

---

## Phase 5 — Roll out (only after a Go on Task 9)

Six apps, one task each, **one per merge pair** so a problem is attributable. Ordered by rising
stakes. Each follows the Migration Runbook; only the parameters and the app-specific verification
differ, and those are spelled out per task below.

### Task 10: Migrate Bazarr

**Files:** Modify `apps/bazarr/config-pvc.yaml`, `apps/bazarr/values.yaml` (`existingClaim` line 61)

**Parameters:** `$APP=bazarr`, `$NS=bazarr`, old claim `bazarr-config-local` (5Gi), new claim
`bazarr-config` at **2Gi**, node worker-01.

- [ ] **Step 1:** Record the starting state — `kubectl -n bazarr exec deploy/bazarr -- sh -c 'ls -la /config && du -sh /config'`
- [ ] **Step 2:** Bazarr → Settings → Backups → Backup Now. Confirm the archive on NFS.
- [ ] **Step 3:** Merge A per the runbook (new PVC 2Gi + `replicas: 0`), then confirm the pod is gone
      and `bazarr-config` is `Bound`.
- [ ] **Step 4:** Copy Job per the runbook. Matching `du`, pod on worker-01.
- [ ] **Step 5:** Merge B — `existingClaim` swap, drop `replicas: 0`, rewrite the comment.
- [ ] **Step 6:** Verify: providers present, languages profiles present, and its Sonarr/Radarr
      connections still authenticate (Settings → Sonarr/Radarr → Test). Bazarr's own database is the
      one with known Postgres reconnection bugs — irrelevant here, it stays SQLite, but its log is
      worth reading: `kubectl -n bazarr logs deploy/bazarr --tail=100`.
- [ ] **Step 7:** `kubectl -n bazarr delete job bazarr-longhorn-copy`

---

### Task 11: Migrate Navidrome

**Files:** Modify `apps/navidrome/config-pvc.yaml`, `apps/navidrome/values.yaml` (`existingClaim` line 72)

**Parameters:** `$APP=navidrome`, `$NS=navidrome`, old claim `navidrome-config-local` (10Gi), new
claim `navidrome-config` at **2Gi**, node worker-01.

**Navidrome has no app-level backup.** The retained `local-path` PVC is the only rollback until the
Longhorn daily backup has run once against the new volume. Do not delete it early, and do not run
this task on the same day as Task 16.

- [ ] **Step 1:** Record the starting state — `kubectl -n navidrome exec deploy/navidrome -- sh -c 'ls -la /config && du -sh /config'`. Note the `.db` files: play counts, ratings and playlists live there and are not reconstructible from the music files.
- [ ] **Step 2:** No backup step exists. Instead, verify the old PV is `Retain` before proceeding:
      `kubectl get pv -o custom-columns=N:.metadata.name,C:.spec.claimRef.name,P:.spec.persistentVolumeReclaimPolicy | grep navidrome`
- [ ] **Step 3:** Merge A per the runbook (new PVC 2Gi + `replicas: 0`).
- [ ] **Step 4:** Copy Job per the runbook. Matching `du`, pod on worker-01.
- [ ] **Step 5:** Merge B.
- [ ] **Step 6:** Verify: library scanned (not re-scanning from scratch), playlists present, play
      counts present, and a track streams. A fresh empty database looks like a working Navidrome, so
      **check the play counts specifically** — that is the signal the copy took.
- [ ] **Step 7:** Force one Longhorn backup so this volume has an off-volume copy before Task 16
      deletes anything. Find the CronJob by matching the volume name — Longhorn names them after the
      PV, so resolve it first:

```bash
PV=$(kubectl -n navidrome get pvc navidrome-config -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get cronjobs | grep "$PV"
kubectl -n longhorn-system create job --from=cronjob/<the name that printed> navidrome-first-backup
kubectl -n longhorn-system wait --for=condition=complete job/navidrome-first-backup --timeout=15m
kubectl -n longhorn-system get backups.longhorn.io | grep "$PV"
```
- [ ] **Step 8:** `kubectl -n navidrome delete job navidrome-longhorn-copy`

---

### Task 12: Migrate `nextcloud-html`

**Files:** Modify `apps/nextcloud/html-pvc.yaml`, `apps/nextcloud/values.yaml` (`existingClaim` line 151)

**Parameters:** `$APP=nextcloud`, `$NS=nextcloud`, old claim `nextcloud-html` (10Gi), new claim
`nextcloud-html-longhorn` at **3Gi**, node worker-01.

Different from the other seven in three ways, all of which matter:

- **The claim name cannot be reused.** The old PVC is literally `nextcloud-html`, so the new one
  needs a distinct name — hence `nextcloud-html-longhorn`.
- **885 MB across ~15k small files**, the least favourable shape for replicated block storage and by
  far the longest copy. Give the Job a 30m timeout rather than 15m.
- **`nextcloud-cron` also mounts it.** Scaling the deployment to zero is not enough; the CronJob must
  be suspended for the copy or it writes to the old volume mid-copy.

- [ ] **Step 1:** Record the starting state:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- sh -c 'du -sh /var/www/html && find /var/www/html -type f | wc -l'
```

Expect ~885M and ~15k files. Both figures are the Step 6 comparison.

- [ ] **Step 2:** Put Nextcloud in maintenance mode and suspend the cron:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:mode --on
kubectl -n nextcloud patch cronjob nextcloud-cron -p '{"spec":{"suspend":true}}'
```

The `CronJobSuspended` alert will fire after an hour. That is the alert working correctly — resume it
in Step 5, not by silencing.

- [ ] **Step 3:** Merge A. Add to `apps/nextcloud/html-pvc.yaml`, keeping the existing PVC:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-html-longhorn
  namespace: nextcloud
spec:
  accessModes:
    - ReadWriteOnce
  # longhorn rather than local-path. This volume is the PHP app tree -- ~15k small files,
  # reconstructible from the container image, so its loss costs a rebuild rather than data.
  # It was on local-path because the alternative was a sync-exported USB spinning disk over
  # NFS; Longhorn beats both, and unlike local-path it can be expanded in place.
  #
  # 885M measured 2026-08-13 against 3Gi. Nextcloud's own upgrades rewrite this tree, so
  # headroom matters more here than for the config volumes.
  storageClassName: longhorn
  resources:
    requests:
      storage: 3Gi
```

Set `replicas: 0` in `apps/nextcloud/values.yaml`, merge, and confirm the pod is gone.

- [ ] **Step 4:** Copy Job with `claimName: nextcloud-html` for `old` and
      `claimName: nextcloud-html-longhorn` for `new`, and `--timeout=30m` on the wait. Verify both
      the `du` figure **and** the file count match:

```bash
kubectl -n nextcloud logs job/nextcloud-longhorn-copy
kubectl -n nextcloud wait --for=condition=complete job/nextcloud-longhorn-copy --timeout=30m
```

- [ ] **Step 5:** Merge B — `existingClaim: nextcloud-html` → `nextcloud-html-longhorn`, drop
      `replicas: 0`. Then:

```bash
kubectl -n nextcloud wait --for=condition=Ready pod -l app.kubernetes.io/name=nextcloud --timeout=15m
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:mode --off
kubectl -n nextcloud patch cronjob nextcloud-cron -p '{"spec":{"suspend":false}}'
```

- [ ] **Step 6:** Verify:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- sh -c 'du -sh /var/www/html && find /var/www/html -type f | wc -l'
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ status
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ app:list | head -20
```

Then in the browser: log in, open a file, confirm installed apps are present. `occ status` reporting
`installed: true` with the right version is the real check — an empty html volume would have Nextcloud
attempting a fresh install against the existing database, which is the one failure mode here worth
catching immediately.

- [ ] **Step 7:** `kubectl -n nextcloud delete job nextcloud-longhorn-copy`

**Rollback:** revert Merge B, re-enable maintenance mode first. The old volume is untouched and the
database was never modified — this is the safest of the eight to roll back, and the reason it sits
before the arrs rather than last.

---

### Task 13: Migrate Prowlarr

**Files:** Modify `apps/prowlarr/config-pvc.yaml`, `apps/prowlarr/values.yaml` (`existingClaim` line 77)

**Parameters:** `$APP=prowlarr`, `$NS=prowlarr`, old claim `prowlarr-config-local` (10Gi), new claim
`prowlarr-config` at **2Gi**, node worker-01.

Prowlarr syncs indexers *to* the other three arrs, so a bad migration here shows up as breakage in
apps that were not touched.

- [ ] **Step 1:** Record the starting state and the indexer count from the UI.
- [ ] **Step 2:** Prowlarr → System → Backup → Backup Now. Confirm the archive.
- [ ] **Step 3:** Merge A per the runbook.
- [ ] **Step 4:** Copy Job per the runbook.
- [ ] **Step 5:** Merge B.
- [ ] **Step 6:** Verify: indexer count matches Step 1, and **the hash-rejection setting is still
      enabled** (Settings → Apps, the Cleanuparr prerequisite enabled 2026-08-06 — UI-only state,
      invisible to git). Then Settings → Apps → Test All to confirm the four arr connections, and
      check Sonarr/Radarr/Lidarr each still list their indexers.
- [ ] **Step 7:** `kubectl -n prowlarr delete job prowlarr-longhorn-copy`

---

### Task 14: Migrate Radarr

**Files:** Modify `apps/radarr/config-pvc.yaml`, `apps/radarr/values.yaml` (`existingClaim` line 70)

**Parameters:** `$APP=radarr`, `$NS=radarr`, old claim `radarr-config-local` (10Gi), new claim
`radarr-config` at **2Gi**, node worker-01.

- [ ] **Step 1:** Record the starting state and the movie count.
- [ ] **Step 2:** Radarr → System → Backup → Backup Now. Confirm the archive.
- [ ] **Step 3:** Merge A per the runbook.
- [ ] **Step 4:** Copy Job per the runbook.
- [ ] **Step 5:** Merge B.
- [ ] **Step 6:** Verify: movie count matches, root folder `/data/media/movies` present and writable,
      download client connects, quality profiles intact, and its qBittorrent category is still
      `radarr` (the per-arr categories fixed the arrs claiming each other's torrents — UI state).
      `kubectl -n radarr logs deploy/radarr --tail=100 | grep -ci "database is locked"` → 0.
- [ ] **Step 7:** `kubectl -n radarr delete job radarr-longhorn-copy`

---

### Task 15: Migrate Sonarr

**Files:** Modify `apps/sonarr/config-pvc.yaml`, `apps/sonarr/values.yaml` (`existingClaim` line 70)

**Parameters:** `$APP=sonarr`, `$NS=sonarr`, old claim `sonarr-config-local` (10Gi), new claim
`sonarr-config` at **2Gi**, node worker-01.

Last, and deliberately so: Sonarr is the busiest writer of the eight and the one with the documented
996-lock-errors history that produced the whole SQLite-storage rule. If Task 9's benchmark missed a
latency problem, this is what finds it.

- [ ] **Step 1:** Record the starting state and the series count.
- [ ] **Step 2:** Sonarr → System → Backup → Backup Now. Confirm the archive.
- [ ] **Step 3:** Merge A per the runbook.
- [ ] **Step 4:** Copy Job per the runbook.
- [ ] **Step 5:** Merge B.
- [ ] **Step 6:** Verify: series count matches, root folder `/data/media/tv`, download client and
      qBittorrent category `sonarr`, quality profiles, and Prowlarr's indexers present.
- [ ] **Step 7: Watch it for a full day before Task 16.** This is the step, not a formality:

```bash
kubectl -n sonarr logs deploy/sonarr --since=24h | grep -ci "database is locked"        # 0
kubectl -n sonarr exec deploy/sonarr -- sh -c 'wget -qO- localhost:8989/api/v3/queue?apikey=$(grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2) | head -c 200'
```

Zero lock errors, and `/api/v3/queue` answers. A stalled nightly refresh jamming the queue until
that endpoint stops answering is the exact failure mode from the NFS incident — if it reappears,
roll Sonarr back and reopen Task 9's gate rather than pressing on.

- [ ] **Step 8:** `kubectl -n sonarr delete job sonarr-longhorn-copy`

---

## Phase 6 — Clean up and document

### Task 16: Retire the retained `local-path` PVCs

**Files:** Modify all eight `apps/*/config-pvc.yaml` (delete the old PVC block); `apps/nextcloud/html-pvc.yaml`

**Interfaces:**
- Consumes: Tasks 7–15 all verified.
- Produces: reclaimed node disk, and one storage class per volume instead of two.

**Gated on two conditions, both required:** two weeks since each app's Merge B (matching the
`apps/vaultwarden/data-pvc.yaml` precedent, not the old plan's 24 hours), and Sonarr clean for a full
day per Task 15 Step 7.

- [ ] **Step 1: Confirm the gate**

```bash
git log --format='%ad %s' --date=short -- apps/*/config-pvc.yaml apps/nextcloud/html-pvc.yaml | head -20
```

Every Merge B must be at least 14 days old. If any is not, wait — this task is not urgent and the
retained volumes cost nothing but disk.

- [ ] **Step 2: Confirm every Longhorn volume is healthy and backed up**

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=N:.metadata.name,R:.status.robustness,S:.status.state
kubectl -n longhorn-system get backups.longhorn.io
```

All eight `healthy`. Each must have at least one backup in the backupstore — for Navidrome and
`nextcloud-html` that backup *is* the durability story once the old PVC goes.

Also re-check the #13152 Replica CR count against Task 5 Step 6's baseline, now that eight volumes
have been firing recurring jobs for weeks:

```bash
kubectl -n longhorn-system get replicas.longhorn.io --no-headers | wc -l   # expect ~16
```

Materially above 2 × volumes means the leak is real on 1.11.3 and 1.12.1 is due.

- [ ] **Step 3: Remove the old PVC blocks from git, one commit per app**

Delete the `*-config-local` PVC block (and `nextcloud-html`'s original) from each file, leaving only
the Longhorn PVC. ArgoCD's `prune: true` deletes the PVC on sync; the PV survives as `Released`
because it is `Retain`.

- [ ] **Step 4: Reclaim the released PVs**

```bash
kubectl get pv | grep Released
kubectl delete pv <name>        # per PV, after confirming its claimRef is the old PVC
```

This is the step that actually frees the disk. Check each `claimRef` before deleting — a
`Released` PV whose claimRef names a *Longhorn* volume would mean something went wrong.

- [ ] **Step 5: Confirm the disk came back**

```bash
ansible -i ansible/inventory.yml all -m shell -a 'df -h / && du -sh /var/lib/rancher/k3s/storage 2>/dev/null' --vault-password-file .vault_pass
```

- [ ] **Step 6: Commit**

One commit per app, or one commit with all eight — the PVCs are independent and the sync is the same
either way.

```bash
git commit -m "chore(storage): retire the retained local-path config PVCs

Two weeks past each migration, every Longhorn volume healthy with a backup in
the store. The Retain policy leaves the PVs Released rather than deleted, so
reclaiming the disk is a separate manual step -- done."
```

---

### Task 17: Rewrite the documentation

**Files:**
- Modify: `CLAUDE.md` (Storage section and the `local-path` rule under Rules)
- Modify: `docs/longhorn-evaluation.md` (four passages)
- Modify: `docs/talos-migration-audit.md` (§3, §5)
- Modify: all eight `apps/*/config-pvc.yaml` comments if Task 7–15 left any stale

**Interfaces:**
- Consumes: everything. This is the last task.
- Produces: documentation that matches the cluster.

**This is a rewrite, not an amendment.** `CLAUDE.md`'s storage rule has three `local-path` cases.
Case (1) SQLite becomes `longhorn`. Case (3) reconstructible volumes has exactly one example —
`nextcloud-html` — which just moved, leaving the case empty. What remains is "CNPG clusters stay
`local-path`, everything else `longhorn`", which is a different rule with a different shape. Budget
for that.

- [ ] **Step 1: Rewrite `CLAUDE.md`'s Storage section**

The new rule, in the repo's voice — stating what to use, why, and what the exception is:

- `longhorn` for anything holding state: SQLite databases and app trees alike. Two replicas, so a
  node failure degrades rather than breaks. It expands in place, so size it for what it holds rather
  than for what it might.
- `nfs` for bulk data shared between pods — media, backups, Loki and Prometheus.
- `local-path` for **CNPG cluster volumes only**, because streaming replication across instances
  already provides node-failure durability and replicating again at the block layer doubles write
  amplification. It remains the cluster default class, which is why every other PVC must name its
  class explicitly.
- Keep the "app-level backups are the application-consistent copy" rule verbatim — Longhorn changes
  nothing about it, and it is the reason `apps/cleanuparr/backup-cronjob.yaml` still exists.
- Drop the `WaitForFirstConsumer`/no-sync-wave warning from the general rule and keep it only where
  `local-path` is still used. The `longhorn` class binds `Immediate`.

- [ ] **Step 2: Amend `docs/longhorn-evaluation.md`**

Four passages, all currently wrong in-repo:

- **Sizing** (lines ~51-72): replace with the right-sizing argument. 67Gi of claims became 17Gi, so
  all three nodes are storage nodes and worker-00 is not excluded.
- **Talos replica-count warning** (lines ~133-140): delete it. With three storage nodes and two
  replicas, rebuilding one node leaves two and replicas re-place without intervention.
- **Risk #2**: correct the claim that excluding worker-00 reduces per-node overhead. It does not —
  the engine runs wherever a volume attaches, so worker-00 runs an instance-manager either way.
  `guaranteedInstanceManagerCpu: 5` is the actual mitigation.
- **Plan step 2**: remove "and a VPA per repo convention". There is no VPA, deliberately.

Add a line at the top pointing at the spec and this plan as the implementation of record.

- [ ] **Step 3: Amend `docs/talos-migration-audit.md`**

- **§3**: replace the `local-path`-on-Talos recommendation with Longhorn, and include Task 9's
  measured fsync numbers so the next reader sees the data.
- **§5**: fold in the `iscsi-tools` and `util-linux-tools` system extension requirement from Task 1,
  plus the machine-config mount for `/var/lib/longhorn`. This is the note that stops Task 1's Ansible
  work being silently lost when `roles/common` is deleted.
- Note that the audit's own hard blocker — `nfs-kernel-server` on worker-01 — is unchanged by this
  work and still waits on the NAS.

- [ ] **Step 4: Sweep the PVC comments**

```bash
grep -rn "local-path" apps/*/config-pvc.yaml apps/nextcloud/html-pvc.yaml apps/*/values.yaml
```

Every remaining hit should be either a deliberate historical reference or a CNPG volume. Anything
describing a migrated volume's storage as `local-path` is stale.

- [ ] **Step 5: Confirm Renovate is tracking the chart**

Check the dependency dashboard after the next weekend run: Longhorn should appear as an item
*awaiting approval* rather than as an open PR. If a PR opened on its own, the packageRule from Task 2
did not match — check `matchFileNames`.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/
git commit -m "docs: Longhorn is the storage class for stateful volumes

CLAUDE.md's three local-path cases collapse to one. Case (1) SQLite moves to
longhorn; case (3) reconstructible volumes had exactly one example and it moved
too, so what is left is 'CNPG stays local-path because replication already
covers it, everything else is longhorn'.

The evaluation's sizing section and Talos replica warning are superseded by
right-sizing, and its risk #2 was wrong about what excluding worker-00 saves."
```

---

## Out of scope, recorded so it is not re-asked

- **Jellyfin's config volume.** Its pin is wanted — 12th-gen QuickSync is on worker-01 and the PV's
  node affinity is what enforces it. Last, or never.
- **CNPG cluster volumes.** Streaming replication already provides node-failure durability, NFS and
  Longhorn are not supported CNPG configurations, and replicating at the block layer underneath
  doubles write amplification to solve a solved problem.
- **Longhorn RWX.** Implemented by fronting an RWO volume with an NFS-Ganesha pod — a single point of
  failure, and ironic given the direction of travel. RWX comes from the NFS share, then the NAS.
- **The v2 (SPDK) data engine.** Needs hugepages and considerably more RAM. Wrong fit for 16G nodes.
- **A separate snapshot schedule.** A backup takes a snapshot on its way, and Longhorn snapshots live
  on the volume's own replicas — a snapshot-only schedule is the one form of protection a node
  failure takes with it.
- **Retiring any app-level backup.** Longhorn's backups are crash-consistent; the apps' own are
  application-consistent. Both stay.
- **Postgres migrations for the arrs or Cleanuparr.** Settled in `docs/longhorn-evaluation.md` and
  `docs/superpowers/plans/2026-08-13-cleanuparr-postgres.md` (filed as researched, not scheduled).
  Longhorn unpins those volumes for free.
- **Repointing the backup target at the NAS.** That is the NAS project's step, one setting, and it
  needs the existing backup data copied across if history matters.
