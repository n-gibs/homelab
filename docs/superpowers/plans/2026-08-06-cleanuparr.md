# Cleanuparr Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Cleanuparr to the media stack so malicious downloads (the 2026-08-06 `.scr` incident) are blocked automatically instead of by hand.

**Architecture:** Standard bjw-s `app-template` app in `apps/cleanuparr/`, auto-discovered by the `apps` ApplicationSet (sync wave 3). SQLite config on a `local-path` PVC declared as its own manifest, with durability supplied by a nightly CronJob that snapshots the databases to `/data/backups/cleanuparr` on NFS. Runtime configuration is entered in the web UI and is deliberately not in git — see the spec.

**Tech Stack:** k3s, ArgoCD, bjw-s app-template 5.0.1, Gateway API HTTPRoute, `ghcr.io/cleanuparr/cleanuparr:2.10.3`, `python:3.13-alpine` (stdlib `sqlite3` online-backup API), Prometheus/kube-state-metrics.

**Spec:** `docs/superpowers/specs/2026-08-06-cleanuparr-design.md`

## Global Constraints

- Container image: `ghcr.io/cleanuparr/cleanuparr`, tag `2.10.3`. **No `v` prefix** — registry-verified: `2.10.3` returns a manifest, `v2.10.3` 404s.
- Chart: `app-template` `5.0.1` from `https://bjw-s-labs.github.io/helm-charts`.
- Namespace: `cleanuparr`. Created by ArgoCD, so it does **not** exist during pre-merge validation.
- Web UI port: `11011`. Hostname: `cleanuparr.nik-homelab.dev`.
- Config volume: `local-path`, `ReadWriteOnce`, 2Gi, claim name `cleanuparr-config-local`, consumed via `existingClaim`. **No `sync-wave` annotation on the PVC** — `local-path` is `WaitForFirstConsumer`, so it stays `Pending`, which an earlier wave reads as unhealthy and deadlocks the sync forever.
- Backup destination: `/data/backups/cleanuparr` on NFS `192.168.30.194:/mnt/storage`. `/data/backups` is `1000:1000 rwxrwxr-x`, so a pod running as uid 1000 can create the subdirectory itself.
- CronJob name **must** be `cleanuparr-db-backup` — `system/monitoring-system/prometheusrule-backups.yaml` matches `.+-db-backup`.
- Never `kubectl apply` managed manifests. ArgoCD syncs from `main`; merging to `main` is how things deploy. Pre-merge validation is `helm template` plus client-side dry-run only.
- No `sleep`. Use `kubectl wait`.
- No `Co-Authored-By` trailers in commits.
- Every app gets a `vpa.yaml`.

## File Structure

| File | Responsibility |
|---|---|
| `renovate.json` | **Modify.** Add a matchString so `repository:`-then-`tag:` image blocks are tracked |
| `apps/cleanuparr/app.yaml` | **Create.** Chart coordinates, Renovate-parsed |
| `apps/cleanuparr/config-pvc.yaml` | **Create.** `local-path` PVC + rationale and recovery path |
| `apps/cleanuparr/values.yaml` | **Create.** Container, service, HTTPRoute, persistence |
| `apps/cleanuparr/backup-cronjob.yaml` | **Create.** Nightly SQLite snapshot to NFS |
| `apps/cleanuparr/vpa.yaml` | **Create.** Standard VPA |
| `system/monitoring-system/prometheusrule-backups.yaml` | **Modify.** `BackupCronJobMissing` threshold 2 → 3 |

There is no test framework in this repo. The equivalent of a failing test is `helm template` rendering the wrong output, or a dry-run rejecting a manifest — so each task renders/validates *before* the file is correct, confirms the failure, then fixes it.

---

### Task 1: Make Renovate track app-template image tags

Renovate's `values.yaml` custom manager requires `image:` to be followed *immediately* by `tag:`. app-template puts `repository:` in between, so a pinned app-template tag is invisible to Renovate today (`apps/unpackerr/values.yaml` has been pinned at `0.15.2` untracked for this reason). Fixing the manager is what makes "Renovate handles bumps" true for Task 3.

**Files:**
- Modify: `renovate.json` (the `customManagers` entry with `fileMatch: ["(^|/)values\\.yaml$"]`)

**Interfaces:**
- Produces: a Renovate matchString that Task 3's `values.yaml` comment relies on. The comment form is `# renovate: datasource=docker depName=<image>` on the line directly above `image:`.

- [ ] **Step 1: Confirm the current manager does not match app-template's shape**

Read the existing manager:

```bash
rtk grep -n -A6 'values\\\\.yaml' renovate.json
```

Expected: one `matchStrings` entry containing `image:\\n\\s*tag:` — no alternative allowing `repository:` between them. That is the gap.

- [ ] **Step 2: Add the second matchString**

In `renovate.json`, find this manager:

```json
    {
      "customType": "regex",
      "fileMatch": ["(^|/)values\\.yaml$"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[^\\s]+)\\n\\s*image:\\n\\s*tag: (?<currentValue>[^\\n]+)"
      ]
    },
```

Replace its `matchStrings` array with both forms:

```json
    {
      "customType": "regex",
      "fileMatch": ["(^|/)values\\.yaml$"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[^\\s]+)\\n\\s*image:\\n\\s*tag: (?<currentValue>[^\\n]+)",
        "# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[^\\s]+)\\n\\s*image:\\n\\s*repository: [^\\n]+\\n\\s*tag: (?<currentValue>[^\\n]+)"
      ]
    },
```

The second entry is the bjw-s `app-template` shape: `repository:` then `tag:`.

- [ ] **Step 3: Validate the JSON parses**

Run: `python3 -m json.tool renovate.json > /dev/null && echo VALID`
Expected: `VALID`

- [ ] **Step 4: Commit**

```bash
git add renovate.json
git commit -m "chore(renovate): track image tags in app-template values.yaml

The values.yaml custom manager required image: to be followed directly by
tag:, but app-template puts repository: in between, so any app-template
image pin was silently untracked. apps/unpackerr has sat at 0.15.2 for
this reason."
```

Note for the reviewer: this may open a Renovate PR for `apps/unpackerr/values.yaml` once a `# renovate:` comment is added there. That is out of scope here — this task only makes tracking *possible*.

---

### Task 2: Create the config PVC manifest

**Files:**
- Create: `apps/cleanuparr/config-pvc.yaml`

**Interfaces:**
- Produces: PVC `cleanuparr-config-local` in namespace `cleanuparr`. Consumed by Task 3 (`existingClaim`) and Task 4 (backup CronJob volume).

- [ ] **Step 1: Create the file**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cleanuparr-config-local
  namespace: cleanuparr
  # NO sync-wave annotation -- do not add one. local-path is WaitForFirstConsumer,
  # so this stays Pending (= unhealthy to ArgoCD) until its consumer is scheduled.
  # An earlier wave deadlocks the sync forever. Same reasoning as
  # apps/sonarr/config-pvc.yaml and apps/nextcloud/html-pvc.yaml.
spec:
  accessModes:
    - ReadWriteOnce
  # local-path because /config holds SQLite databases, and SQLite over NFS does not
  # work reliably -- Sonarr logged 996 "database is locked" errors in a week, one of
  # which stalled the nightly refresh for 35 minutes and jammed the task queue until
  # /api/v3/queue stopped answering. All four arrs were migrated off NFS on
  # 2026-08-06; this app starts here rather than repeating the migration.
  #
  # Durability comes from backup-cronjob.yaml, not from the volume. Cleanuparr has no
  # built-in backup feature (unlike the arrs' System -> Backup), so that CronJob
  # snapshots the databases nightly to /data/backups/cleanuparr on the USB-attached
  # NFS disk -- a different failure domain from worker-01's internal NVMe, which is
  # what local-path uses.
  #
  # Recovery if that NVMe dies: delete this PVC, let it recreate empty, extract the
  # newest archive from /data/backups/cleanuparr/ into /config, restart the pod. If no
  # archive is usable, the fallback is manual: re-enter the arr URLs, API keys and job
  # settings in the UI (~15 min). The API keys are all recoverable from
  # secrets/.secrets because they are generate:-derived.
  #
  # 2Gi against a settings database plus logs is headroom -- local-path cannot be
  # expanded in place, so this is sized once.
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
```

- [ ] **Step 2: Validate the manifest**

Run:

```bash
kubectl apply --dry-run=client -f apps/cleanuparr/config-pvc.yaml
```

Expected: `persistentvolumeclaim/cleanuparr-config-local created (dry run)`

Client-side, not server-side: namespace `cleanuparr` does not exist yet, and server-side dry-run would fail on that rather than on anything real.

- [ ] **Step 3: Confirm no sync-wave annotation slipped in**

Run: `rtk grep -c "sync-wave" apps/cleanuparr/config-pvc.yaml || echo "0 (correct)"`
Expected: `0 (correct)`

- [ ] **Step 4: Commit**

```bash
git add apps/cleanuparr/config-pvc.yaml
git commit -m "feat(cleanuparr): add local-path config PVC"
```

---

### Task 3: Create the app manifests

**Files:**
- Create: `apps/cleanuparr/app.yaml`
- Create: `apps/cleanuparr/values.yaml`
- Create: `apps/cleanuparr/vpa.yaml`

**Interfaces:**
- Consumes: PVC `cleanuparr-config-local` from Task 2; the Renovate matchString from Task 1.
- Produces: Deployment `cleanuparr` and Service `cleanuparr` on port `11011` in namespace `cleanuparr`. Task 4's CronJob shares the same node as this Deployment by way of the PVC's node affinity. Task 5 verifies both.

- [ ] **Step 1: Create `apps/cleanuparr/app.yaml`**

```yaml
chartName: app-template
chartRepo: https://bjw-s-labs.github.io/helm-charts
chartVersion: 5.0.1
```

- [ ] **Step 2: Create `apps/cleanuparr/values.yaml`**

```yaml
controllers:
  main:
    pod:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        # local-path creates the volume directory root-owned. fsGroup makes /config
        # group-writable by 1000 so the app can write regardless of whether its
        # entrypoint chowns for PUID/PGID itself.
        fsGroup: 1000
    containers:
      app:
        # renovate: datasource=docker depName=ghcr.io/cleanuparr/cleanuparr
        image:
          repository: ghcr.io/cleanuparr/cleanuparr
          tag: 2.10.3
        env:
          PORT: "11011"
          PUID: "1000"
          PGID: "1000"
          UMASK: "022"
          TZ: America/Los_Angeles
        resources:
          requests:
            cpu: 50m
            memory: 256Mi
          # no cpu limit: VPA preserves the request:limit ratio, so a shrinking
          # request drags the limit down with it and throttles the container.
          limits:
            memory: 1Gi

service:
  main:
    controller: main
    ports:
      http:
        port: 11011

route:
  main:
    annotations:
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: "Cleanuparr"
      gethomepage.dev/description: "Download cleanup & malware blocking"
      gethomepage.dev/group: "Media"
      gethomepage.dev/icon: "cleanuparr.png"
      gethomepage.dev/href: "https://cleanuparr.nik-homelab.dev"
    enabled: true
    kind: HTTPRoute
    hostnames:
      - cleanuparr.nik-homelab.dev
    parentRefs:
      - name: homelab
        namespace: envoy-gateway-system

persistence:
  # local-path, not nfs -- /config is SQLite and SQLite over NFS deadlocks. See
  # config-pvc.yaml for the rationale, the backup that supplies durability instead,
  # and the recovery path. Declared as its own manifest so that comment lives with
  # the volume; the chart just consumes it.
  config:
    existingClaim: cleanuparr-config-local
    globalMounts:
      - path: /config
# No data volume on purpose. Orphan/no-hardlink cleanup is out of scope (it would
# need /data mounted at qBittorrent's exact paths, and a mismatch deletes library
# files), and Blacklist Sync reads its list from an HTTPS URL rather than a file.
# The backup CronJob mounts NFS separately -- this pod never sees the media share.
```

No `nodeSelector`: Cleanuparr mounts no NFS and touches no media files, so it does not need `homelab.io/media`. The `local-path` PV pins it to whichever node it first schedules on, and app-template's default `Recreate` strategy keeps it there.

- [ ] **Step 3: Create `apps/cleanuparr/vpa.yaml`**

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: cleanuparr
  namespace: cleanuparr
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cleanuparr
  updatePolicy:
    updateMode: "Recreate"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: 10m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

- [ ] **Step 4: Add the chart repo (once per machine)**

```bash
helm repo add bjw-s-labs https://bjw-s-labs.github.io/helm-charts
helm repo update bjw-s-labs
```

Expected: `...Successfully got an update from the "bjw-s-labs" chart repository`

- [ ] **Step 5: Render the chart**

```bash
helm template cleanuparr bjw-s-labs/app-template --version 5.0.1 \
  -n cleanuparr -f apps/cleanuparr/values.yaml > /tmp/cleanuparr-render.yaml
echo "exit=$?"
```

Expected: `exit=0` and no error output.

- [ ] **Step 6: Assert the four things most likely to be wrong**

```bash
rtk grep -c "kind: Deployment" /tmp/cleanuparr-render.yaml
rtk grep -n "image: ghcr.io/cleanuparr/cleanuparr:2.10.3" /tmp/cleanuparr-render.yaml
rtk grep -n "claimName: cleanuparr-config-local" /tmp/cleanuparr-render.yaml
rtk grep -n "kind: HTTPRoute" /tmp/cleanuparr-render.yaml
rtk grep -c "strategy" /tmp/cleanuparr-render.yaml
```

Expected: `1` Deployment; the image line present with the exact `2.10.3` tag (no `v`); `claimName` pointing at Task 2's PVC and **not** an inline `cleanuparr-config` PVC; one HTTPRoute; and a `strategy` stanza present. If `strategy: Recreate` is absent from the render, add it explicitly under `controllers.main` as `strategy: Recreate` — the RWO volume cannot be mounted by a rolling second pod on another node.

- [ ] **Step 7: Confirm no PVC is rendered by the chart**

```bash
rtk grep -c "kind: PersistentVolumeClaim" /tmp/cleanuparr-render.yaml || echo "0 (correct)"
```

Expected: `0 (correct)`. A rendered PVC means `existingClaim` was mistyped and the chart is creating its own volume — which would come up with the wrong storage class and silently orphan Task 2's PVC.

- [ ] **Step 8: Validate the VPA**

Run: `kubectl apply --dry-run=client -f apps/cleanuparr/vpa.yaml`
Expected: `verticalpodautoscaler.autoscaling.k8s.io/cleanuparr created (dry run)`

- [ ] **Step 9: Commit**

```bash
git add apps/cleanuparr/app.yaml apps/cleanuparr/values.yaml apps/cleanuparr/vpa.yaml
git commit -m "feat(cleanuparr): add app-template manifests

Cleanuparr blocks and re-searches malicious downloads. Added after two
.scr payloads reached the Sonarr queue on 2026-08-06 and needed manual
blocklisting."
```

---

### Task 4: Create the backup CronJob

Cleanuparr has no built-in backup feature, so this is the fallback case from the `local-path` rule in `CLAUDE.md`.

**Files:**
- Create: `apps/cleanuparr/backup-cronjob.yaml`

**Interfaces:**
- Consumes: PVC `cleanuparr-config-local` (Task 2).
- Produces: CronJob `cleanuparr-db-backup` in namespace `cleanuparr`. The name is load-bearing — Task 5 raises a Prometheus threshold that counts CronJobs matching `.+-db-backup`.

- [ ] **Step 1: Create the file**

```yaml
# Cleanuparr, unlike the arrs, has no built-in scheduled backup -- there is no
# System -> Backup in its UI -- so this job is what makes the local-path config
# volume acceptable. It writes to the NFS share, a different disk from the NVMe
# that local-path uses.
#
# Not a `cp`: SQLite in WAL mode spreads committed state across .db, .db-wal and
# .db-shm, so copying a live database can produce a torn, unrestorable file. This
# uses SQLite's online backup API via Python's stdlib sqlite3 module, which is why
# the image is python:3.13-alpine -- no sqlite3 CLI needed, no apk add at runtime,
# and an official image Renovate already knows how to track. (The linuxserver arr
# images do not ship the sqlite3 binary, so there was nothing to reuse.)
apiVersion: batch/v1
kind: CronJob
metadata:
  # Name must keep the -db-backup suffix: BackupCronJobMissing in
  # system/monitoring-system/prometheusrule-backups.yaml counts CronJobs matching
  # ".+-db-backup" and alerts if one stops reporting.
  name: cleanuparr-db-backup
  namespace: cleanuparr
spec:
  schedule: "15 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            # Alloy derives the Loki `app` stream label from this; without it these
            # pods fall back to the namespace and land in cleanuparr's main stream.
            app.kubernetes.io/name: cleanuparr-db-backup
        spec:
          restartPolicy: OnFailure
          securityContext:
            # /data/backups is 1000:1000 rwxrwxr-x, so uid 1000 can create the
            # cleanuparr/ subdirectory itself. /config is written by the app as 1000.
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
          containers:
            - name: sqlite-backup
              image: python:3.13-alpine
              command:
                - python
                - -c
                - |
                  import glob, os, shutil, sqlite3, sys, tarfile, time

                  CONFIG = "/config"
                  DEST = "/data/backups/cleanuparr"
                  RETAIN_DAYS = 14
                  staging = "/tmp/cleanuparr-backup"
                  stamp = time.strftime("%Y%m%d-%H%M%S")

                  # Everything except logs and the live database files. The
                  # DataProtection keys and cleanuparr.json live under /config with
                  # names that are not documented, so copy by exclusion rather than
                  # guessing filenames -- the .db files are replaced below by
                  # consistent snapshots.
                  shutil.rmtree(staging, ignore_errors=True)
                  shutil.copytree(
                      CONFIG,
                      staging,
                      ignore=shutil.ignore_patterns(
                          "logs", "*.db", "*.db-wal", "*.db-shm"
                      ),
                  )

                  # Cleanuparr creates one database per internal context (data,
                  # events, users), so glob rather than naming them.
                  dbs = sorted(glob.glob(os.path.join(CONFIG, "*.db")))
                  if not dbs:
                      sys.exit(
                          "no .db files in /config -- refusing to write a backup "
                          "with no database in it"
                      )
                  for db in dbs:
                      target = os.path.join(staging, os.path.basename(db))
                      # Read-only source: a backup job must never mutate what it is
                      # backing up. If WAL recovery were needed this open fails and
                      # the job fails loudly, which is the safe direction.
                      src = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
                      dst = sqlite3.connect(target)
                      with dst:
                          src.backup(dst)
                      dst.close()
                      src.close()
                      print(
                          f"snapshot {os.path.basename(db)} "
                          f"{os.path.getsize(target)} bytes"
                      )

                  os.makedirs(DEST, exist_ok=True)
                  archive = os.path.join(DEST, f"cleanuparr-{stamp}.tar.gz")
                  with tarfile.open(archive, "w:gz") as tar:
                      tar.add(staging, arcname="config")
                  print(f"wrote {archive} ({os.path.getsize(archive)} bytes)")

                  cutoff = time.time() - RETAIN_DAYS * 86400
                  kept = 0
                  for old in sorted(
                      glob.glob(os.path.join(DEST, "cleanuparr-*.tar.gz"))
                  ):
                      if os.path.getmtime(old) < cutoff:
                          os.remove(old)
                          print(f"pruned {os.path.basename(old)}")
                      else:
                          kept += 1
                  print(f"retained: {kept} archives")
              volumeMounts:
                - name: config
                  mountPath: /config
                  readOnly: true
                - name: data
                  mountPath: /data
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
          volumes:
            # ReadWriteOnce is a per-NODE constraint, not per-pod, so this pod may
            # mount the volume while Cleanuparr has it. The local-path PV carries
            # node affinity, which forces the scheduler to put this pod on the same
            # node -- so that is guaranteed rather than lucky. (ReadWriteOncePod
            # would forbid it; that is not the access mode in use.)
            - name: config
              persistentVolumeClaim:
                claimName: cleanuparr-config-local
                readOnly: true
            - name: data
              nfs:
                server: 192.168.30.194
                path: /mnt/storage
```

- [ ] **Step 2: Validate the manifest and check for duplicate keys**

```bash
kubectl apply --dry-run=client -f apps/cleanuparr/backup-cronjob.yaml
rtk grep -c "^          volumes:" apps/cleanuparr/backup-cronjob.yaml
```

Expected: `cronjob.batch/cleanuparr-db-backup created (dry run)` and a count of exactly `1`.

The duplicate-key check is not paranoia: YAML is last-one-wins, so a second `volumes:` at the same indent silently discards the first and the job runs with nothing mounted — no error, no warning. This repo has been bitten by exactly that (a duplicate top-level key ate an HTTPRoute, and only a diff caught it).

- [ ] **Step 3: Verify the backup script logic runs standalone**

This is the one piece of real logic in the whole deployment, so exercise it against a throwaway WAL-mode database before trusting it in-cluster:

```bash
kubectl run sqlite-backup-check --rm -i --restart=Never --image=python:3.13-alpine \
  --command -- python -c '
import os, sqlite3, tempfile
d = tempfile.mkdtemp()
src_path = os.path.join(d, "data.db")
c = sqlite3.connect(src_path)
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE t (x TEXT)")
c.execute("INSERT INTO t VALUES (?)", ("committed-but-still-in-wal",))
c.commit()
# Deliberately leave the connection open, so the WAL is not checkpointed --
# this is the state a live Cleanuparr leaves its databases in.
target = os.path.join(d, "copy.db")
s = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
t = sqlite3.connect(target)
with t:
    s.backup(t)
rows = t.execute("SELECT x FROM t").fetchall()
assert rows == [("committed-but-still-in-wal",)], rows
print("PASS: online backup captured uncheckpointed WAL data")
'
```

Expected: `PASS: online backup captured uncheckpointed WAL data`

This is the assertion that matters: it proves the backup captures committed data still sitting in the WAL, which a plain `cp` of the `.db` file would miss.

- [ ] **Step 4: Commit**

```bash
git add apps/cleanuparr/backup-cronjob.yaml
git commit -m "feat(cleanuparr): nightly SQLite backup to NFS

Cleanuparr has no built-in backup, so the local-path config volume needs
one here. Uses SQLite's online backup API rather than cp -- WAL mode
spreads committed state across .db/-wal/-shm and a plain copy can tear."
```

---

### Task 5: Extend backup monitoring to cover the new job

`prometheusrule-backups.yaml` is deliberately generic — `CronJobNotSucceeding`, `CronJobOverdue`, `CronJobSuspended` and `CronJobJobFailed` all match every CronJob and need no edit. `BackupCronJobMissing` is the documented exception: you cannot detect the absence of something generically, so it names the expected count. Left at `< 2`, it would tolerate one of the three backups vanishing entirely.

**Files:**
- Modify: `system/monitoring-system/prometheusrule-backups.yaml`

**Interfaces:**
- Consumes: CronJob name `cleanuparr-db-backup` from Task 4.

- [ ] **Step 1: Confirm the current threshold**

Run: `rtk grep -n -A4 "BackupCronJobMissing" system/monitoring-system/prometheusrule-backups.yaml`
Expected: an expr counting `cronjob=~".+-db-backup"` compared `< 2`.

- [ ] **Step 2: Raise the threshold and update the wording**

Replace:

```yaml
        - alert: BackupCronJobMissing
          expr: count(kube_cronjob_status_last_successful_time{cronjob=~".+-db-backup"}) < 2
```

with:

```yaml
        - alert: BackupCronJobMissing
          expr: count(kube_cronjob_status_last_successful_time{cronjob=~".+-db-backup"}) < 3
```

Then update that alert's `summary` to say three rather than two:

```yaml
            summary: Expected 3 database backup CronJobs reporting a successful run, found {{ $value }}
```

And in its `description`, replace `immich-db-backup and nextcloud-db-backup should both be reporting a last successful run. One is missing,` with:

```
              immich-db-backup, nextcloud-db-backup and cleanuparr-db-backup should all be
              reporting a last successful run. One is missing,
```

- [ ] **Step 3: Update the file's header comment**

The comment at the top of the file says it guards "the five CronJobs". Change `five CronJobs` to `six CronJobs` and add Cleanuparr's SQLite backup to the parenthesised list, so the next person editing this file knows what is expected to exist.

- [ ] **Step 4: Validate**

```bash
kubectl apply --dry-run=client -f system/monitoring-system/prometheusrule-backups.yaml
rtk grep -c "db-backup\"}) < 3" system/monitoring-system/prometheusrule-backups.yaml
```

Expected: `prometheusrule.monitoring.coreos.com/backups configured (dry run)` and a count of `1`.

- [ ] **Step 5: Commit**

```bash
git add system/monitoring-system/prometheusrule-backups.yaml
git commit -m "feat(monitoring): expect three db-backup CronJobs

cleanuparr-db-backup joins immich and nextcloud. Left at 2, the rule would
tolerate one backup disappearing outright."
```

---

### Task 6: Prowlarr prerequisite

Without this, Cleanuparr blocks a release and the next search grabs it straight back. Doing it before deploying means the blocker is effective from its first run.

**Files:** none — this is Prowlarr UI configuration.

- [ ] **Step 1: Enable hash rejection for every Prowlarr app**

In Prowlarr → Settings → Apps, click **Show Advanced**, then for each app entry (Sonarr, Radarr, Lidarr): edit it, enable **Sync Reject Blocklisted Torrent Hashes While Grabbing**, save.

- [ ] **Step 2: Verify all apps have it set**

Re-open each app entry and confirm the toggle stuck. Doing it in Prowlarr covers all three arrs; there is no need to touch per-indexer settings inside each arr.

- [ ] **Step 3: Record completion**

No commit — this is cluster-external state. Note in the PR/session that Step 1 is done, because nothing in git records it.

---

### Task 7: Deploy and verify (Phase 1 — everything off)

**Files:** none — merge and verification only.

**Interfaces:**
- Consumes: Tasks 1–5.

- [ ] **Step 1: Merge to main**

ArgoCD auto-syncs `main`; this is the deploy. Push the branch and merge it (or push directly to `main` if working there).

```bash
git push
```

- [ ] **Step 2: Wait for the app to appear and sync**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/cleanuparr --timeout=300s
kubectl -n argocd get application cleanuparr -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

Expected: `Synced Healthy`

If the Application does not exist yet, the ApplicationSet has not re-scanned. Refresh it:

```bash
kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite
```

- [ ] **Step 3: Verify pod and volume**

```bash
kubectl -n cleanuparr wait --for=condition=Ready pod -l app.kubernetes.io/name=cleanuparr --timeout=300s
kubectl -n cleanuparr get pvc cleanuparr-config-local
kubectl -n cleanuparr get pod -o wide
```

Expected: pod `Ready`, PVC `Bound`. Record which node the pod landed on — the backup CronJob must run there too.

- [ ] **Step 4: Verify the UI is reachable**

```bash
kubectl -n cleanuparr port-forward svc/cleanuparr 11011:11011 &
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:11011/health
```

Expected: `200`. Then kill the port-forward and load `https://cleanuparr.nik-homelab.dev` in a browser to confirm the HTTPRoute and TLS work.

- [ ] **Step 5: Set Dry Run ON before configuring anything**

In the UI: General → **Dry Run: enabled**. Do this before any arr or download client is configured, so nothing can act while being set up.

While in General, also set:
- **Internet Connectivity Check: enabled** — on failure the Queue Cleaner skips its run instead of striking every download during an outage.
- **Trust Forwarded Headers: OFF**. With it on, `X-Forwarded-For` becomes spoofable, and combined with the local-address auth bypass that would let anything able to reach Envoy in without logging in.

Note: "Disable Auth for Local Addresses" trusting `10.0.0.0/8` means requests via Envoy (a pod IP) appear local and skip login. That is accepted — the Gateway VIP is a LAN address announced by Cilium L2 and is not internet-routable — but it is why the previous toggle must stay off.

- [ ] **Step 6: Prove the backup works now, not during a restore**

```bash
kubectl -n cleanuparr create job --from=cronjob/cleanuparr-db-backup backup-manual-1
kubectl -n cleanuparr wait --for=condition=complete job/backup-manual-1 --timeout=300s
kubectl -n cleanuparr logs job/backup-manual-1
```

Expected output: one `snapshot <name>.db N bytes` line per database, then `wrote /data/backups/cleanuparr/cleanuparr-<stamp>.tar.gz (N bytes)` with a non-zero size, then `retained: 1 archives`.

This is the step that proves the RWO volume can be mounted alongside the running pod. If the pod stays `Pending` with a volume-node-affinity conflict, the scheduler could not co-locate it — check that the Cleanuparr pod and the job landed on the same node.

- [ ] **Step 7: Confirm the archive is real**

```bash
kubectl -n cleanuparr exec deploy/cleanuparr -- ls -la /config
kubectl -n sonarr exec deploy/sonarr -c app -- ls -la /data/backups/cleanuparr/
```

Expected: the archive present on the NFS share with a plausible size. Sonarr is used to look because it already mounts `/data` and Cleanuparr deliberately does not.

- [ ] **Step 8: Confirm monitoring sees the new job**

```bash
kubectl -n cleanuparr get cronjob cleanuparr-db-backup
kubectl get cronjob -A | rtk grep db-backup
```

Expected: three `*-db-backup` CronJobs. `BackupCronJobMissing` needs a successful *scheduled* run before it stops considering the series absent, so it may take until after 04:15 to fully settle — the manual job in Step 6 does not populate `kube_cronjob_status_last_successful_time`.

- [ ] **Step 9: Confirm config survives a pod restart**

```bash
kubectl -n cleanuparr delete pod -l app.kubernetes.io/name=cleanuparr
kubectl -n cleanuparr wait --for=condition=Ready pod -l app.kubernetes.io/name=cleanuparr --timeout=300s
```

Then reload the UI and confirm the Dry Run and General settings from Step 5 are still set. This proves the PVC is actually mounted and written to, rather than the app writing into the container's ephemeral filesystem — which would look identical until the first restart.

---

### Task 8: Phase 2 — Malware Blocker and Blacklist Sync

The direct answer to the `.scr` incident, and the low-risk half: a filename match is unambiguous and needs no threshold tuning.

**Files:** none — Cleanuparr UI configuration, stored in its SQLite database.

- [ ] **Step 1: Add the arr connections**

| Arr | URL |
|---|---|
| Sonarr | `http://sonarr.sonarr.svc.cluster.local:8989` |
| Radarr | `http://radarr.radarr.svc.cluster.local:7878` |
| Lidarr | `http://lidarr.lidarr.svc.cluster.local:8686` |

API keys come from `secrets/.secrets` (`SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`). Test each connection in the UI before saving.

- [ ] **Step 2: Add the download client**

qBittorrent: `http://qbittorrent.qbittorrent.svc.cluster.local:8080`, with its WebUI credentials. Test the connection.

- [ ] **Step 3: Configure Malware Blocker**

| Setting | Value |
|---|---|
| Enable Malware Blocker | on |
| Schedule | every 5 minutes |
| Blocklist Path (Sonarr, Radarr) | `https://cleanuparr.pages.dev/static/blacklist` |
| Blocklist Type | Blacklist |
| **Delete if any file is blocked** | **ON** |
| Ignore Private | on |
| Delete Private | off |
| Process downloads with no content ID | off |

**"Delete if any file is blocked" is the setting that matters.** Its default is OFF, which removes a download only when *every* file matches. The 2026-08-06 payload was a `.scr` packaged next to a decoy video — under the default it would have been kept, with the `.scr` merely marked skipped in qBittorrent. Getting this wrong makes the whole deployment decorative.

**Leave Lidarr without a blocklist.** The official lists are documented for Sonarr and Radarr only; music container and extension names differ enough to risk false positives on legitimate audio.

- [ ] **Step 4: Configure Blacklist Sync**

Enable it, Blacklist Path `https://cleanuparr.pages.dev/static/blacklist`. This pushes the list into qBittorrent's **Excluded file names** so the file is never written to disk — prevention rather than cleanup.

- [ ] **Step 5: Enable the qBittorrent side of it**

Cleanuparr populates the "Excluded file names" field but does **not** enable it. In qBittorrent → Options → Downloads, enable the excluded-file-names setting. Without this the sync is inert.

Verify by checking that qBittorrent's field is populated after the next hourly sync (or restart the Cleanuparr pod to trigger one).

- [ ] **Step 6: Observe in Dry Run**

Leave Dry Run ON for several days. Read the logs:

```bash
kubectl -n cleanuparr logs deploy/cleanuparr --tail=200
```

Two things to confirm, in order of importance:
1. It flags nothing legitimate. A false positive here deletes a good download and re-searches for it.
2. It correctly identifies bad patterns when they appear.

- [ ] **Step 7: Go live**

Set Dry Run OFF. Malware Blocker and Blacklist Sync are now active. Leave Queue Cleaner untouched.

---

### Task 9: Phase 3 — Queue Cleaner

Only start this after Phase 2 has run live and clean for several days.

**Files:** none — Cleanuparr UI configuration.

- [ ] **Step 1: Re-enable Dry Run**

General → Dry Run: enabled. Every phase gets its own observation window.

- [ ] **Step 2: Configure Failed Import**

- `Max Strikes`: 3 (0 disables; the minimum to enable is 3).
- `Pattern Mode`: **Exclude**.
- Patterns: `manual import required`, `recently aired`.
- `Ignore Private`: on. `Delete Private`: off.

Patterns are case-insensitive plain substrings — no regex, no wildcards. Never include the `{0}`-style placeholders from the arrs' message templates; the real message carries the substituted value, so a pattern containing a placeholder never matches. Confirm the exact wording against the messages in your own Sonarr/Radarr queue.

- [ ] **Step 3: Configure Stalled**

- `Max Strikes`: 3.
- `Reset Strikes on Progress`: on.
- `Minimum Progress to Reset`: set a real value (e.g. 100MB). **Do not leave it blank** — blank resets on *any* progress, so a torrent trickling a few KB per run never accumulates strikes and never gets cleaned.
- `Downloading Metadata Max Strikes`: 3. This one is separate from the rule system and global (qBittorrent only).

- [ ] **Step 4: Leave Slow rules disabled**

Do not create any slow rule yet. qBittorrent runs through Mullvad using *userspace* WireGuard at MTU 1170, so throughput is both lower and lumpier than bare metal — a naive floor like `1MB/s` will reap healthy downloads. Gather real speed data first, then set a threshold grounded in it.

- [ ] **Step 5: Set the schedule deliberately**

Strikes accumulate one per run, so the real grace period is *strikes × interval*. At a 5-minute schedule, 3 strikes is 15 minutes — probably too aggressive for a stalled torrent that may recover. Prefer a longer interval (e.g. hourly) for the Queue Cleaner than for the Malware Blocker.

- [ ] **Step 6: Observe, then go live**

Watch the logs across at least one full download cycle, ideally including a genuinely stalled torrent. Confirm nothing healthy accumulates strikes, then set Dry Run OFF.

---

### Task 10: Phase 4 — Searching and seeding cleanup

Convenience features. They wait until the cleanup path is trusted, and go in one at a time so a misbehaving one is unambiguous.

**Files:** none — Cleanuparr UI configuration.

- [ ] **Step 1: Enable missing + cutoff-unmet search**

Dry Run ON, configure it for Sonarr and Radarr, observe that the search volume it generates is sane (this hits indexers — an over-eager schedule earns rate limits), then Dry Run OFF.

- [ ] **Step 2: Enable seeding cleanup**

Dry Run ON, set the seeding threshold, confirm in the logs that it targets only what you expect, then Dry Run OFF.

No coordination with Qui is needed: Qui runs only on the seedbox, so it and Cleanuparr act on different qBittorrent instances.

- [ ] **Step 3: Update the spec's status**

Edit `docs/superpowers/specs/2026-08-06-cleanuparr-design.md`, changing the header `**Status:** Approved, not yet implemented` to `**Status:** Implemented <date>`.

```bash
git add docs/superpowers/specs/2026-08-06-cleanuparr-design.md
git commit -m "docs(cleanuparr): mark spec implemented"
```

---

## Deferred

Recorded so they are decisions rather than oversights:

- **Orphan / no-hardlink cleanup** — needs `/data` at qBittorrent's exact paths; a mismatch deletes library files. Excluded from the design.
- **Slow download rules** — need real throughput data from the VPN path first (Task 9, Step 4).
- **A Lidarr blocklist** — the official lists are Sonarr/Radarr-specific.
- **Cleanuparr's own notifications** (Notifiarr/Apprise) — Alertmanager already exists.
- **PostgreSQL via CloudNativePG** — SQLite is the documented default and fine at this scale.
- **A `# renovate:` comment for `apps/unpackerr/values.yaml`** — Task 1 makes tracking possible; actually pinning unpackerr's currently-untracked `0.15.2` is separate work.
