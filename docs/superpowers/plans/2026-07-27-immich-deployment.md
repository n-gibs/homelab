# Immich Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Immich (self-hosted photo backup) to the homelab k3s cluster via GitOps, backed by a new CloudNativePG Postgres platform with the VectorChord extension.

**Architecture:** Two ArgoCD Applications. `platform/cloudnative-pg` (wave 2) installs the CNPG operator as shared database infrastructure. `apps/immich` (wave 3) contains the official Immich OCI Helm chart plus a 3-instance CNPG `Cluster`, a static NFS PV for the photo library, a `pg_dump` backup CronJob, and a VPA. Two node-preparation steps in Ansible come first.

**Tech Stack:** k3s v1.36.2, ArgoCD, Helm (OCI), CloudNativePG 1.30.0, PostgreSQL 18 + VectorChord, Valkey, Envoy Gateway (Gateway API), NFS, Ansible.

**Spec:** `docs/superpowers/specs/2026-07-27-immich-deployment-design.md`

## Global Constraints

- Chart versions come from `app.yaml` and are Renovate-managed. Never pin to `latest`.
- All persistent storage uses the `nfs` StorageClass, **except** replicated CNPG clusters, which use `local-path` (this plan establishes that carve-out in `CLAUDE.md`).
- `local-path` has `ALLOWVOLUMEEXPANSION=false`. A CNPG volume cannot be grown in place — size it correctly the first time.
- Never use `Ingress`. Routing is Gateway API `HTTPRoute` only, parented to `homelab` in `envoy-gateway-system`.
- No `sleep` in scripts or manifests. Use `kubectl wait`, `--timeout`, or probes.
- Never add `Co-Authored-By` lines or any reference to Claude/Anthropic in commit messages.
- Apply changes via ArgoCD (push to `main`), never `kubectl apply` of managed manifests.
- `main` reflects applied state: merge each step only after the previous one is confirmed live.
- Cluster subnet is `192.168.30.0/24`. NFS server is `192.168.30.194`, export `/mnt/storage`.
- Ansible nodes: worker-00 `192.168.30.129`, worker-01 `192.168.30.194`, worker-02 `192.168.30.136`, user `homelab`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ansible/roles/common/tasks/main.yml` | Modify | Add idempotent root-LV expansion |
| `ansible/roles/nfs_server/defaults/main.yml` | Modify | Add `photos` to `nfs_subdirs` |
| `CLAUDE.md` | Modify | Amend the `local-path` rule with the replicated-database carve-out |
| `renovate.json` | Modify | Constrain the HTTPS chart manager; add an OCI chart manager |
| `platform/cloudnative-pg/app.yaml` | Create | CNPG operator chart source |
| `platform/cloudnative-pg/values.yaml` | Create | CNPG operator values |
| `apps/immich/app.yaml` | Create | Immich OCI chart source |
| `apps/immich/values.yaml` | Create | Immich Helm values: server, valkey, route, DB wiring |
| `apps/immich/postgres.yaml` | Create | CNPG `Cluster` + `Database` |
| `apps/immich/library-pv.yaml` | Create | Static NFS PV + PVC for the photo library |
| `apps/immich/pg-backup.yaml` | Create | Backup PVC + nightly `pg_dump` CronJob |
| `apps/immich/vpa.yaml` | Create | VPA for the Immich server deployment |

## Task Ordering and Why

Tasks 1–3 are preparation and can be verified independently. Task 4 must be live before Task 5, because Task 5 creates CNPG custom resources whose CRDs Task 4 installs. Task 6 depends on the deployment name that only exists after Task 5. Task 7 is verification of the whole.

---

### Task 1: Expand worker-00's root filesystem

worker-00 has 13GB free on a 57GB root LV, while its volume group has **58GB unallocated** — the Ubuntu installer only claimed half the 116GB NVMe. A 20Gi Postgres volume there would push the node past the kubelet's 10% disk-pressure eviction threshold and start evicting Grafana, Envoy, and Cilium.

This is also why the node looks fuller than expected: `common` configures containerd's **native snapshotter**, which stores a full copy of every layer instead of sharing them via overlayfs, so 23 images occupy 32GB. Expanding the LV is the correct fix; pruning images would be temporary.

`lvextend` and `resize2fs` on a mounted ext4 filesystem are online operations. No unmount, no reboot, no data movement.

**Files:**
- Modify: `ansible/roles/common/tasks/main.yml` (append at end)

**Interfaces:**
- Consumes: nothing
- Produces: worker-00 root filesystem ≥110GB, ≥70GB available. Task 5 relies on this headroom for the `local-path` Postgres volume.

- [ ] **Step 1: Record the current state so the change is provable**

```bash
ssh homelab@192.168.30.129 'df -h / | tail -1; sudo vgs --noheadings -o vg_free'
```

Expected: root shows roughly `57G` size / `13G` avail, and VG free shows about `58.09g`.

- [ ] **Step 2: Add the expansion tasks to the common role**

Append to the end of `ansible/roles/common/tasks/main.yml`:

```yaml
# The Ubuntu installer allocates only part of the volume group to the root LV.
# k3s uses containerd's native snapshotter (configured above), which stores a
# full copy of every image layer rather than sharing them via overlayfs, so
# nodes consume disk faster than image counts suggest. Claim the whole VG.
- name: Check for unallocated space in the root volume group
  ansible.builtin.command: vgs --noheadings --nosuffix --units b -o vg_free ubuntu-vg
  register: root_vg_free
  changed_when: false
  failed_when: false
  become: true

- name: Extend root logical volume to use all free volume group space
  community.general.lvol:
    vg: ubuntu-vg
    lv: ubuntu-lv
    size: +100%FREE
    resizefs: true
  become: true
  when:
    - root_vg_free.rc == 0
    - (root_vg_free.stdout | trim | int) > 1073741824
```

The guard makes this idempotent: once the VG has under 1GiB free, the task is skipped. It is safe on worker-01 and worker-02, which have no free extents. `resizefs: true` grows the ext4 filesystem in the same step.

- [ ] **Step 3: Confirm the collection providing `community.general.lvol` is installed**

```bash
grep -A5 collections ansible/requirements.yml
```

Expected: `community.general` is listed. It is already used for `community.general.ufw` in the `nfs_server` role, so it should be present. If it is not listed, add it:

```yaml
  - name: community.general
```

- [ ] **Step 4: Dry-run against the cluster**

```bash
cd ansible && ansible-playbook -i inventory.yml site.yml --tags common --check --diff 2>&1 | tail -30
```

Expected: the lvol task reports a change for worker-00 and is skipped for worker-01/worker-02. If `--tags common` matches nothing (the role has no tags), run the check without it and read the output for the two new task names.

- [ ] **Step 5: Apply**

```bash
just provision
```

- [ ] **Step 6: Verify the filesystem actually grew**

```bash
ssh homelab@192.168.30.129 'df -h / | tail -1'
```

Expected: size roughly `114G`, available roughly `71G`. If available is still ~13G, stop — `resizefs` did not run, and the rest of this plan's storage sizing is invalid.

- [ ] **Step 7: Verify the node is still healthy and not under disk pressure**

```bash
kubectl get nodes
kubectl describe node worker-00 | grep -A5 Conditions
```

Expected: all three nodes `Ready`; `DiskPressure` is `False`.

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/common/tasks/main.yml ansible/requirements.yml
git commit -m "feat(ansible): claim unallocated VG space for the root filesystem"
```

---

### Task 2: Create the NFS photo library directory

The Immich library needs `/mnt/storage/photos` to exist on worker-01 before the PV can bind. The `nfs_server` role already loops over an `nfs_subdirs` list, so this is a one-line data change rather than new logic.

The export is `no_root_squash` and the Immich container runs as root, so it can write into a `nobody:nogroup 0755` directory. No initContainer `chmod` is needed, unlike the media stack.

**Files:**
- Modify: `ansible/roles/nfs_server/defaults/main.yml`

**Interfaces:**
- Consumes: nothing
- Produces: `/mnt/storage/photos` on worker-01, exported at `192.168.30.194:/mnt/storage/photos`. Task 5's PV binds to exactly this path.

- [ ] **Step 1: Confirm the directory does not yet exist**

```bash
ssh homelab@192.168.30.194 'ls -la /mnt/storage/'
```

Expected: `downloads` and `media` are present; `photos` is not.

- [ ] **Step 2: Add `photos` to the subdirectory list**

In `ansible/roles/nfs_server/defaults/main.yml`, change:

```yaml
nfs_subdirs:
  - downloads
  - media
```

to:

```yaml
nfs_subdirs:
  - downloads
  - media
  - photos
```

- [ ] **Step 3: Apply**

```bash
just provision
```

- [ ] **Step 4: Verify the directory exists with the expected ownership**

```bash
ssh homelab@192.168.30.194 'ls -ld /mnt/storage/photos'
```

Expected: `drwxr-xr-x ... nobody nogroup ... /mnt/storage/photos`

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/nfs_server/defaults/main.yml
git commit -m "feat(ansible): add photos subdirectory for the Immich library"
```

---

### Task 3: Update repository conventions

Two repo-level changes that the rest of the plan depends on being correct. Grouped because neither is independently testable against the cluster and both are pure convention changes reviewed the same way.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `renovate.json`

**Interfaces:**
- Consumes: nothing
- Produces: a documented `local-path` carve-out that Task 5's CNPG `Cluster` relies on, and Renovate coverage for the OCI chart reference Task 5 introduces.

- [ ] **Step 1: Amend the storage rule in `CLAUDE.md`**

In the `## Rules` section, replace this line:

```markdown
- Never use `local-path` StorageClass for new PVCs.
```

with:

```markdown
- Never use `local-path` StorageClass for new PVCs, **except** for replicated databases (CloudNativePG clusters with 2+ instances), where streaming replication — not the volume — provides node-failure durability. NFS is not a supported CNPG configuration. Note `local-path` cannot be expanded in place, so size those volumes correctly up front.
```

- [ ] **Step 2: Also update the Storage section of `CLAUDE.md`**

The `## Storage` section opens with an absolute claim that is now wrong. Replace:

```markdown
All persistent storage uses the `nfs` StorageClass. Never use `local-path` in new apps — data won't survive node failure.
```

with:

```markdown
All persistent storage uses the `nfs` StorageClass. Never use `local-path` in new apps — data won't survive node failure. The one exception is a replicated CloudNativePG cluster, where replication provides that durability; see the Rules section.
```

- [ ] **Step 3: Constrain the existing Renovate manager to HTTPS repos**

The current custom manager matches any `chartRepo` and forces `datasource: helm`, which cannot resolve an OCI reference. Without this change it would also claim `apps/immich/app.yaml` and fail.

In `renovate.json`, in `customManagers`, change the first entry's `matchStrings` from:

```json
"chartName: (?<depName>[^\\n]+)\\nchartRepo: (?<registryUrl>[^\\n]+)\\nchartVersion: (?<currentValue>[^\\n]+)"
```

to:

```json
"chartName: (?<depName>[^\\n]+)\\nchartRepo: (?<registryUrl>https://[^\\n]+)\\nchartVersion: (?<currentValue>[^\\n]+)"
```

- [ ] **Step 4: Add an OCI chart manager**

Add this object to the `customManagers` array, after the existing chart manager:

```json
    {
      "customType": "regex",
      "fileMatch": ["(^|/)app\\.yaml$"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[^\\s]+)\\nchartName: [^\\n]+\\nchartRepo: [^\\n]+\\nchartVersion: (?<currentValue>[^\\n]+)"
      ]
    }
```

This uses Renovate's documented inline-comment convention rather than trying to concatenate `chartRepo` and `chartName` into an image reference through template fields. The comment carries the full OCI path explicitly, which is unambiguous and easy to read at the point of use. Task 5's `app.yaml` supplies that comment.

- [ ] **Step 5: Validate the Renovate config parses**

```bash
npx --yes --package renovate -- renovate-config-validator renovate.json
```

Expected: `INFO: Config validated successfully`. If npx is unavailable offline, validate the JSON at minimum:

```bash
python3 -c "import json; json.load(open('renovate.json')); print('valid json')"
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md renovate.json
git commit -m "docs: allow local-path for replicated databases; add OCI chart manager"
```

---

### Task 4: Deploy the CloudNativePG operator

Installs the operator only — no database yet. It lands in `platform/` (sync wave 2) so it reconciles before anything in `apps/` (wave 3), and because it is shared infrastructure the parked AFFiNE and n8n designs will also use.

Operator 1.30.0 is required for declarative extension images. This was verified directly against the CRDs in chart 0.29.0: `postgresql.extensions[].image`, `.extension_control_path`, and `.dynamic_library_path` all exist and are not feature-gated.

**Files:**
- Create: `platform/cloudnative-pg/app.yaml`
- Create: `platform/cloudnative-pg/values.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: the `postgresql.cnpg.io/v1` `Cluster` and `Database` CRDs, and a running operator in namespace `cloudnative-pg`. Task 5 creates resources of both kinds.

- [ ] **Step 1: Create the chart source**

`platform/cloudnative-pg/app.yaml`:

```yaml
chartName: cloudnative-pg
chartRepo: https://cloudnative-pg.github.io/charts
chartVersion: 0.29.0
```

- [ ] **Step 2: Create the values file**

`platform/cloudnative-pg/values.yaml`:

```yaml
crds:
  create: true

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

No VPA here: a single small operator pod with fixed limits does not need one, and adding it would be scaffolding for its own sake.

- [ ] **Step 3: Render the chart locally to catch value errors before ArgoCD does**

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg
helm template cloudnative-pg cnpg/cloudnative-pg --version 0.29.0 \
  -f platform/cloudnative-pg/values.yaml > /dev/null && echo "renders clean"
```

Expected: `renders clean`. Any values-schema error surfaces here rather than as a failed ArgoCD sync.

- [ ] **Step 4: Commit and merge to `main`**

ArgoCD deploys from `main`. Per the repo's working agreement, this merge is the deployment.

```bash
git add platform/cloudnative-pg/
git commit -m "feat(platform): add CloudNativePG operator"
git push -u origin feat/immich
```

Then open and merge the PR, or fast-forward `main` if working directly.

- [ ] **Step 5: Wait for ArgoCD to sync the new Application**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/cloudnative-pg --timeout=300s
```

Expected: `application.argoproj.io/cloudnative-pg condition met`. If the Application does not exist yet, the ApplicationSet has not regenerated — check `kubectl -n argocd get applicationset platform`.

- [ ] **Step 6: Verify the operator is running**

```bash
kubectl -n cloudnative-pg rollout status deployment/cnpg-cloudnative-pg --timeout=300s
```

Expected: `deployment "cnpg-cloudnative-pg" successfully rolled out`. If the deployment name differs, find it with `kubectl -n cloudnative-pg get deploy`.

- [ ] **Step 7: Verify the CRDs Task 5 depends on are established**

```bash
kubectl get crd clusters.postgresql.cnpg.io databases.postgresql.cnpg.io
kubectl explain cluster.spec.postgresql.extensions.extension_control_path 2>&1 | head -5
```

Expected: both CRDs listed, and `explain` describes the field rather than erroring. This is the gate for Task 5 — do not proceed if `explain` fails.

---

### Task 5: Deploy Immich and its database

The main deliverable. Everything in `apps/immich/` is one ArgoCD Application: the Helm chart comes from the OCI registry, and the extra manifests are applied by the ApplicationSet's third source, which includes every file in the directory except `app.yaml` and `values.yaml`.

Sync-wave annotations order the database and volumes ahead of the Helm-rendered workloads, so the Immich server is less likely to crashloop while Postgres bootstraps. Some crashlooping during the first sync is still expected and resolves itself via `selfHeal`.

**Files:**
- Create: `apps/immich/app.yaml`
- Create: `apps/immich/values.yaml`
- Create: `apps/immich/postgres.yaml`
- Create: `apps/immich/library-pv.yaml`

**Interfaces:**
- Consumes: CNPG CRDs from Task 4; `/mnt/storage/photos` from Task 2; worker-00 disk headroom from Task 1.
- Produces:
  - Service `immich-database-rw` (namespace `immich`) — the Postgres primary endpoint.
  - Secret `immich-database-app` with keys `username` and `password`, generated by CNPG.
  - PVC `immich-library` (RWX) — the photo library, consumed by the Helm chart.
  - A Deployment whose exact name Task 6's VPA targets.

- [ ] **Step 1: Create the chart source with the Renovate comment**

`apps/immich/app.yaml`:

```yaml
# renovate: datasource=docker depName=ghcr.io/immich-app/immich-charts/immich
chartName: immich
chartRepo: ghcr.io/immich-app/immich-charts
chartVersion: 0.13.1
```

ArgoCD consumes public OCI Helm charts through the ordinary `repoURL` + `chart` fields with the `oci://` scheme omitted, so `bootstrap/root/templates/stack.yaml` needs no changes. The comment is what Task 3's Renovate manager matches.

- [ ] **Step 2: Create the library volume manifests**

`apps/immich/library-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-library
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  capacity:
    storage: 4Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - nfsvers=4.1
  nfs:
    server: 192.168.30.194
    path: /mnt/storage/photos
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library
  namespace: immich
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: immich-library
  resources:
    requests:
      storage: 4Ti
```

`storageClassName: ""` on both sides disables dynamic provisioning so the PVC binds to this specific PV. `volumeName` makes the binding explicit rather than relying on the matching heuristics. The 4Ti capacity is nominal — NFS does not enforce it; it exists because the API requires a value.

- [ ] **Step 3: Create the Postgres manifests**

`apps/immich/postgres.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-database
  namespace: immich
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie

  storage:
    size: 20Gi
    storageClass: local-path

  postgresql:
    shared_preload_libraries:
      - "vchord.so"
    extensions:
      - name: vchord
        image:
          reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1
        dynamic_library_path:
          - /usr/lib/postgresql/18/lib
        extension_control_path:
          - /usr/share/postgresql/18/

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: "2"
      memory: 2Gi
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: immich-database
  namespace: immich
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  name: app
  owner: app
  cluster:
    name: immich-database
  extensions:
    - name: cube
      ensure: present
    - name: earthdistance
      ensure: present
    - name: vector
      ensure: present
    - name: vchord
      ensure: present
```

`cube` is listed before `earthdistance` because `earthdistance` depends on it.

CNPG generates the `app` user, the `app` database, and the secret `immich-database-app`. No sealed secret is involved — a credential only two in-cluster components ever see is generated in-cluster.

- [ ] **Step 4: Create the Immich values**

`apps/immich/values.yaml`:

```yaml
controllers:
  main:
    containers:
      main:
        env:
          DB_HOSTNAME: immich-database-rw
          DB_USERNAME: app
          DB_DATABASE_NAME: app
          DB_PASSWORD:
            valueFrom:
              secretKeyRef:
                name: immich-database-app
                key: password

immich:
  metrics:
    enabled: false
  persistence:
    library:
      existingClaim: immich-library

valkey:
  enabled: true

machine-learning:
  enabled: false

server:
  enabled: true
  route:
    main:
      annotations:
        gethomepage.dev/enabled: "true"
        gethomepage.dev/name: "Immich"
        gethomepage.dev/description: "Photo and video backup"
        gethomepage.dev/group: "Media"
        gethomepage.dev/icon: "immich.png"
        gethomepage.dev/href: "https://immich.nik-homelab.dev"
      enabled: true
      kind: HTTPRoute
      hostnames:
        - immich.nik-homelab.dev
      parentRefs:
        - name: homelab
          namespace: envoy-gateway-system
```

Notes on what is deliberately absent:

- **No `image.tag` override.** The chart's default tracks its own `appVersion` (`v3.0.0`). One version knob instead of two; pin explicitly only if the chart's release lag becomes a problem.
- **No `immich.configuration` block.** Populating it makes Immich write a config file, which turns the entire admin settings page read-only in the UI. Machine learning is therefore switched off in the admin UI post-deploy (Task 7) rather than via config, keeping every other setting editable.
- **Valkey persistence left at the chart default (`emptyDir`).** It holds a job queue; a restart re-queues on the next scan.
- The env map merges with the chart's defaults, so `REDIS_HOSTNAME` and `IMMICH_MACHINE_LEARNING_URL` are preserved.

- [ ] **Step 5: Render the chart locally before pushing**

```bash
helm template immich oci://ghcr.io/immich-app/immich-charts/immich \
  --version 0.13.1 --namespace immich \
  -f apps/immich/values.yaml > /tmp/immich-render.yaml && echo "renders clean"
```

Expected: `renders clean`.

- [ ] **Step 6: Capture the server deployment name — Task 6 needs it**

```bash
grep -A3 "^kind: Deployment" /tmp/immich-render.yaml | grep "name:"
```

Expected: a name such as `immich-server`. Write down the exact value; Task 6's VPA `targetRef` must match it. Do not assume the chart composes it as `{{ .Release.Name }}-server`.

- [ ] **Step 7: Confirm the HTTPRoute rendered and targets a real service**

```bash
grep -A25 "kind: HTTPRoute" /tmp/immich-render.yaml
kubectl apply --dry-run=client -f /tmp/immich-render.yaml 2>&1 | tail -5
```

Expected: an `HTTPRoute` with hostname `immich.nik-homelab.dev`, a `parentRefs` entry naming `homelab`/`envoy-gateway-system`, and a `backendRefs` service that also appears as a `Service` in the render. If `backendRefs` is missing, add an explicit rule under `server.route.main`:

```yaml
      rules:
        - backendRefs:
            - identifier: main
              port: 2283
```

- [ ] **Step 8: Verify the manifests are valid against the live API**

```bash
kubectl apply --dry-run=server -f apps/immich/postgres.yaml -f apps/immich/library-pv.yaml
```

Expected: each resource reports `(server dry run)`. A schema error here means the CNPG version or field names are wrong — fix before merging, because ArgoCD will otherwise sit in a failed sync.

- [ ] **Step 9: Commit and merge to `main`**

```bash
git add apps/immich/
git commit -m "feat(immich): deploy Immich with CloudNativePG backend"
git push
```

Merge to `main`.

- [ ] **Step 10: Watch the database come up first**

```bash
kubectl -n immich wait --for=condition=Ready cluster/immich-database --timeout=900s
```

Expected: condition met. The first start pulls the Postgres image and the extension image and initialises three instances, so several minutes is normal. If it stalls, check `kubectl -n immich describe cluster immich-database` and the operator logs.

- [ ] **Step 11: Confirm the three instances landed on three different nodes**

```bash
kubectl -n immich get pods -l cnpg.io/cluster=immich-database -o wide
```

Expected: three pods, `Running`, one per node. If one is `Pending`, check `kubectl -n immich describe pod <name>` for an unschedulable message — most likely insufficient disk on a node, which means Task 1 did not take effect.

- [ ] **Step 12: Confirm the extensions installed**

```bash
kubectl -n immich exec -it immich-database-1 -- psql -U postgres -d app -c '\dx'
```

Expected: `cube`, `earthdistance`, `vector`, and `vchord` all listed. This is the single most important check in the plan — Immich will not start without `vchord`.

- [ ] **Step 13: Confirm the library PVC bound**

```bash
kubectl -n immich get pvc immich-library
```

Expected: `STATUS: Bound`, `VOLUME: immich-library`. If it is `Pending`, the PV and PVC did not match — compare `accessModes`, `storageClassName`, and capacity.

- [ ] **Step 14: Confirm Immich itself is running**

```bash
kubectl -n immich get pods
kubectl -n immich logs deploy/immich-server --tail=30
```

Expected: server and valkey pods `Running`. Earlier restarts are expected and fine — the server crashloops until Postgres is ready. Logs should end with Immich listening and no database errors.

---

### Task 6: Add the VPA and database backups

Separated from Task 5 because the VPA needs the deployment name that only exists once the chart is deployed, and because a reviewer can reasonably accept the deployment while rejecting the backup approach.

**Files:**
- Create: `apps/immich/vpa.yaml`
- Create: `apps/immich/pg-backup.yaml`

**Interfaces:**
- Consumes: the deployment name captured in Task 5 Step 6; the `immich-database-app` secret and `immich-database-rw` service from Task 5.
- Produces: nightly dump files under `/backup` on an `nfs`-backed PVC.

- [ ] **Step 1: Create the VPA using the name captured in Task 5**

`apps/immich/vpa.yaml` — replace `immich-server` with the exact name from Task 5 Step 6 if it differs:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: immich
  namespace: immich
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: immich-server
  updatePolicy:
    updateMode: "Recreate"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: 10m
          memory: 256Mi
        maxAllowed:
          cpu: 2
          memory: 4Gi
```

`minAllowed.memory` is raised above the repo's usual `64Mi` because Immich's Node server idles well above that, and a VPA that recommends too little would cause eviction loops. No VPA targets the CNPG cluster: CNPG owns those pods and VPA evicting them to resize would fight the operator's rollout.

- [ ] **Step 2: Create the backup PVC and CronJob**

`apps/immich/pg-backup.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-db-backup
  namespace: immich
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs
  resources:
    requests:
      storage: 10Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: immich-db-backup
  namespace: immich
spec:
  schedule: "30 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: pg-dump
              image: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
              env:
                - name: PGHOST
                  value: immich-database-rw
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: immich-database-app
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: immich-database-app
                      key: password
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  out="/backup/immich-$(date +%Y%m%d-%H%M%S).dump"
                  pg_dump -d app -Fc -f "$out"
                  echo "wrote $out ($(stat -c %s "$out") bytes)"
                  find /backup -name 'immich-*.dump' -mtime +7 -delete
                  echo "retained: $(ls -1 /backup/immich-*.dump | wc -l) dumps"
              volumeMounts:
                - name: backup
                  mountPath: /backup
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: immich-db-backup
```

`set -euo pipefail` means a failed dump fails the job rather than silently deleting old backups and reporting success. Retention runs only after a successful dump, so a broken dump never destroys history. The image is the same Postgres image the cluster runs, so `pg_dump` versions always match the server.

This is crash-consistent dump-and-restore, not point-in-time recovery. PITR would need the barman-cloud plugin and S3-compatible object storage, which the cluster does not have — disproportionate for one metadata database whose irreplaceable data (the photo files) lives on NFS.

- [ ] **Step 3: Validate against the live API**

```bash
kubectl apply --dry-run=server -f apps/immich/vpa.yaml -f apps/immich/pg-backup.yaml
```

Expected: all three resources report `(server dry run)`.

- [ ] **Step 4: Commit and merge to `main`**

```bash
git add apps/immich/vpa.yaml apps/immich/pg-backup.yaml
git commit -m "feat(immich): add VPA and nightly database backups"
git push
```

- [ ] **Step 5: Verify the VPA attached to a real target**

```bash
kubectl -n immich get vpa immich -o jsonpath='{.status.conditions[*].type}{"\n"}'
```

Expected: includes `RecommendationProvided` within a few minutes. If the status stays empty, the `targetRef` name is wrong — correct it against `kubectl -n immich get deploy`.

- [ ] **Step 6: Prove the backup works without waiting for 03:30**

```bash
kubectl -n immich create job --from=cronjob/immich-db-backup immich-db-backup-test
kubectl -n immich wait --for=condition=complete job/immich-db-backup-test --timeout=300s
kubectl -n immich logs job/immich-db-backup-test
```

Expected: job completes, and the log shows a non-zero byte count and a retained-dumps count of at least 1. A dump of only a few bytes means `pg_dump` connected but found nothing — investigate before trusting it.

- [ ] **Step 7: Clean up the test job**

```bash
kubectl -n immich delete job immich-db-backup-test
```

---

### Task 7: Post-deploy verification and configuration

Everything that can only be checked against a running system, plus the one setting that must be changed in the UI rather than in Git.

**Files:** none — this task changes no code.

**Interfaces:**
- Consumes: the full deployment from Tasks 5 and 6.
- Produces: a verified deployment, and a record of whether large uploads need an Envoy timeout.

- [ ] **Step 1: Confirm DNS and TLS**

```bash
dig +short immich.nik-homelab.dev
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://immich.nik-homelab.dev
```

Expected: an address in `192.168.30.200/29`, HTTP `200`, and `ssl_verify_result` `0`. This is a private address by design — the public DNS record exists for the Let's Encrypt wildcard cert and clean hostnames, not for public access.

- [ ] **Step 2: Create the admin account**

Open `https://immich.nik-homelab.dev` and complete the first-run admin registration. Use a strong password.

- [ ] **Step 3: Disable machine learning in the admin UI**

Administration → Settings → Machine Learning → toggle off.

This is done here rather than in `values.yaml` because populating `immich.configuration` makes Immich write a config file, which turns the whole settings page read-only. Without this, Immich queues smart-search and face-detection jobs against a service that is not deployed, and they accumulate as failures.

- [ ] **Step 4: Disable public registration**

Administration → Settings → User Settings — confirm new-user registration is admin-only.

- [ ] **Step 5: Upload a photo and confirm it lands on NFS**

Upload one photo through the web UI, then:

```bash
ssh homelab@192.168.30.194 'find /mnt/storage/photos -type f | head -5; du -sh /mnt/storage/photos'
```

Expected: the uploaded file appears under a dated path and the directory is non-empty. Confirm the thumbnail renders in the UI.

- [ ] **Step 6: Test the mobile app on both paths**

Install the Immich app, point it at `https://immich.nik-homelab.dev`, and confirm login and a manual backup on home wifi. Then disconnect from wifi, connect Tailscale, and confirm it still reaches the server.

Expected: both work. Backup will not be continuous off-network — that gap is known and accepted, and a Cloudflare Tunnel follow-up spec is the remedy if it proves annoying in practice.

- [ ] **Step 7: Test a large video upload — the one genuinely open question**

Upload a video of at least 1GB through the web UI.

Expected: it completes. If it fails partway with a gateway error, the fix is a request timeout on the Immich route, added then rather than guessed at now:

```yaml
      rules:
        - timeouts:
            request: "0s"
            backendRequest: "0s"
```

under `server.route.main` in `apps/immich/values.yaml` (`0s` disables the timeout). Record the outcome either way — this is the last unresolved risk from the spec.

- [ ] **Step 8: Confirm Homepage picked up the new service**

Open `https://homepage.nik-homelab.dev` and check that Immich appears under the Media group with its icon.

- [ ] **Step 9: Confirm the whole namespace is healthy and ArgoCD is clean**

```bash
kubectl -n immich get pods,pvc,cluster
kubectl -n argocd get application immich -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

Expected: all pods `Running`, both PVCs `Bound`, the cluster reporting 3 healthy instances, and the Application `Synced Healthy`.

- [ ] **Step 10: Record the verification outcome**

Append a short "Deployed" note to the spec at `docs/superpowers/specs/2026-07-27-immich-deployment-design.md` capturing the deployment date, the large-upload result from Step 7, and any deviation from this plan. Commit it.

```bash
git add docs/superpowers/specs/2026-07-27-immich-deployment-design.md
git commit -m "docs: record Immich deployment outcome"
```

---

## Rollback

If Task 5 goes wrong, revert the merge commit and let ArgoCD prune:

```bash
git revert --no-edit <merge-commit>
git push
```

The library PV uses `persistentVolumeReclaimPolicy: Retain` and the `nfs` StorageClass is `Retain`, so photo data survives an Application deletion. The CNPG `local-path` volumes do **not** — deleting the Cluster destroys the database. Restore from the most recent dump on the `immich-db-backup` PVC:

```bash
kubectl -n immich exec -i immich-database-1 -- pg_restore -U postgres -d app --clean < <dump>
```

Task 1's Ansible change is independent of the deployment and should not be reverted — the filesystem expansion is beneficial regardless.
