# NAS Migration Checklist

What has to change in this repo when `/mnt/storage` stops being a USB drive on worker-01 and
becomes a NAS.

`NAS_IP` is `192.168.30.144` (DHCP reservation in OPNsense). The export is
`192.168.30.144:/mnt/storage/data`.

## Hardware

CWWK N305 mini-ITX (6x SATA, 2x i226-V 2.5G), 16GB DDR5, 256GB NVMe boot, PicoPSU-160-XT +
192W adapter, 10" rack case. One new 12TB disk to start; worker-01's existing 12TB joins as a
mirror once the data is copied and verified.

160W does not cover six drives spinning up at once. Fine for the two this build ends at.

## Decisions

- **OS: TrueNAS SCALE.** ZFS snapshots, scrubs and disk monitoring without building them.
- **Pool `storage`, export from the child dataset `storage/data`.** TrueNAS warns against
  sharing a pool's root dataset, and a child leaves room for siblings that must not sit in the
  cluster's share (Talos's `secrets.yaml`, below). The cost is only the server-side `path:`:
  `/mnt/storage` becomes `/mnt/storage/data`, on the same lines the IP change already touches.
  The arrs' root folders, Jellyfin's libraries and qBittorrent's save paths are container paths
  (`/data/...`) and do not change.
- **One exported dataset, plain directories underneath.** `downloads/ media/ photos/ nextcloud/
  backups/ vaultwarden/` stay directories inside `storage/data`, so one NFS export covers them
  all. Separate datasets would buy per-directory snapshots and quotas at the cost of NFSv4
  submount handling and a share per dataset.
- **Layout: single disk now, mirror later.** Copy to the new 12TB, verify, then wipe
  worker-01's drive and `zpool attach` it. Do not attach before the verify — attaching wipes
  the disk holding the only other copy.
- **Network: same switch as the nodes.** The NAS picks up a `192.168.30.0/24` address with no
  switch configuration; give it a static DHCP reservation in OPNsense and use that as
  `NAS_IP`. Confirm from the lease table before anything else — a NAS on a different subnet
  means firewall rules between OPNsense interfaces and an extra CIDR in gluetun's
  `FIREWALL_OUTBOUND_SUBNETS`, or torrent I/O routes through Mullvad.

- **`ansible/roles/nfs_client` goes away rather than getting repointed.** It mounts the share
  on all three hosts at `/mnt/storage`, but nothing in the cluster consumes the host mount —
  pods mount NFS directly. It exists for shell convenience, and Talos has no shell, so keeping
  it only defers the deletion by one project. See "Talos, next" below.

Still open:

- **Does `homelab.io/media=true` still mean anything?** Media apps pin to worker-01 with a
  nodeSelector because that is where the disk is. Once storage is off-node that reason is
  gone; the label then mostly means "the biggest node." Jellyfin should keep it for a
  different reason — see "After" below.

## Change: NFS server address

`192.168.30.194` → `192.168.30.144`, and server-side `/mnt/storage` → `/mnt/storage/data`,
everywhere they mean "the storage server". The same IP is also worker-01's node address in
`ansible/inventory.yml` and `system/monitoring-system/scrapeconfig-etcd.yaml` and must **not**
change there. Done on branch `feat/hom-10-nas-repoint` (HOM-10).

| File | What it is |
|---|---|
| `system/nfs-provisioner/values.yaml` | `nfs.server` / `nfs.path` for the `nfs` StorageClass. Everything using `storageClass: nfs` follows this one value. |
| `apps/immich/library-pv.yaml` | static PV → `/mnt/storage/photos` |
| `apps/nextcloud/data-pv.yaml` | static PV → `/mnt/storage/nextcloud` |
| `apps/{sonarr,radarr,lidarr,bazarr,prowlarr,qbittorrent,unpackerr,jellyfin,navidrome,rclone-seedbox}/values.yaml` | inline `type: nfs` data volume; prowlarr, jellyfin and navidrome also mount `backups/` |
| `system/longhorn-system/values.yaml` | `backupTarget`, now a directory inside the single export |
| `system/blackbox-exporter/{probes,prometheusrule}.yaml` | the `:2049` probe and `NFSServerUnreachable` |
| `apps/jellyfin/backup-cronjob.yaml` | inline NFS volume → `/mnt/storage/backups/jellyfin` |
| `apps/cleanuparr/backup-cronjob.yaml` | inline NFS volume → `/mnt/storage` |
| `CLAUDE.md`, `.claude/commands/add-app.md`, `README.md`, `system/infisical/README.md` | documented patterns new apps get copied from — update or the next app regresses |

`ansible/roles/nfs_client` and `nfs_server` are deleted in HOM-14 rather than repointed. Deleting
a role leaves its state on the hosts (fstab entries, `/etc/exports`, the udev rule, UFW rules for
2049), so that is cleaned up by hand when worker-01's drive comes out in HOM-12. `nfs-common`
stays: the `common` role installs it, and kubelet needs `mount.nfs` for every NFS pod volume.

Consumers that go through the StorageClass need no *git* edit: `apps/vaultwarden/data-pvc-nfs.yaml`,
`apps/recyclarr/values.yaml`, the four `pg-backup.yaml` PVCs, `system/loki/values.yaml`,
`system/monitoring-system/values.yaml`. **They still need their live PVs recreated.** The
provisioner bakes `server` and `path` into each PV at creation time, and `spec.nfs` is immutable,
so changing its values only affects PVs created afterwards. That is 8 bound dynamic PVs (Loki,
qbittorrent, recyclarr, vaultwarden-data and the four `*-db-backup` volumes) plus the two static
ones (immich, nextcloud), 10 in all. The 16 `Released` NFS PVs are prune leftovers: delete them
before the rsync rather than recreating them.

Every one is `Retain`, so the data survives. Per PV, with its consumers at zero: delete the PVC,
delete the PV, recreate the PV with the new server and `/mnt/storage/data/...` path and a
`claimRef` of namespace and name only, then let ArgoCD (or the StatefulSet, for Loki) recreate
the PVC. The dynamic PVCs carry no `volumeName`; the pre-bound `claimRef` is what makes them bind
to the recreated PV instead of provisioning a fresh one. The two static PVs come from git as-is.
Script this for the cutover rather than doing 10 by hand.

Delete finished Job pods before deleting the PVCs. A `Succeeded` pod that mounted a claim still
holds its `pvc-protection` finalizer, and the PVC sits in `Terminating` until the pod is gone. The
db-backup CronJobs, `nextcloud-cron` and `recyclarr` all leave pods like this behind.

## Change: the NFS server role

`ansible/roles/nfs_server` exists to make worker-01 an NFS server: it mounts the 12TB drive by
UUID (`nfs_drive_uuid: 9701ed19-...`), exports it to `192.168.30.0/24` with `no_root_squash`, and
opens 2049 in UFW. Once the NAS serves the share, delete the role and its play entry. Mirror the
settings that mattered, in TrueNAS terms:

- **Authorized networks: `192.168.30.0/24`** only, on the NFS share.
- **Maproot User `root`, Maproot Group `root`** — this is TrueNAS's `no_root_squash`.
  qBittorrent's `fix-perms` initContainer runs `chmod -R 777 /data/downloads /data/media` as
  uid 0 on every pod start and silently fails without it.
- **NFSv4 enabled** in Service → NFS. SCALE serves v3 by default and both static PVs carry
  `mountOptions: [nfsvers=4.1]`, which fails with no useful error beyond a stuck pod.
- Directories owned `nobody:nogroup`, mode 0755. Nextcloud's init container chowns its own
  subdir to 33:33 on start; Immich and the arrs run as 1000:1000 against 777 dirs.
- Leave ZFS `sync=standard`. The USB export's `sync` on a spinning disk is a large part of why
  Nextcloud's ~15k-file PHP tree left NFS; ZFS's ZIL handles this differently and the tree now
  lives on `longhorn` regardless.

## Change: monitoring

TrueNAS alerts on its own disks and pool (HOM-13): Drive Health Management polls SMART every 90
minutes and alerts above each drive's rated maximum temperature. 25.10 has no webhook alert type,
so its **Slack** type posts `{"text": ...}` to an ntfy.sh topic with `?tpl=yes&m={{.text}}`. The
topic name is the credential and lives only in TrueNAS. SMART self-tests are TrueNAS cron jobs.

That made the USB drive's monitoring deletable: the `smart-temp-textfile` exporter and APM udev
rule in `ansible/roles/common`, the disk rule group in `prometheusrule-temperature.yaml`, and
`prometheusrule-nfs-export.yaml`. Merge that deletion **before** unmounting the drive in HOM-12:
`NfsExportDriveUnmounted` (critical) and `DiskTemperatureMetricsMissing` fire on the series going
absent. The media dashboard's capacity panels now read the NAS through kubelet's NFS PVC stats.

## Sequence

1. Provision the NAS, create the export, verify from a node: `mount -t nfs4 NAS_IP:NAS_EXPORT /mnt/test`.
2. Copy data. `rsync -aHAX --numeric-ids` from worker-01's `/mnt/storage`, run twice — once live,
   once after the apps are stopped, to catch the delta.
3. Scale to zero everything holding NFS state: the arrs, qBittorrent, unpackerr, Jellyfin,
   Navidrome, Immich, Nextcloud, Vaultwarden and Loki, and suspend every CronJob that mounts NFS.
   Prometheus is on `longhorn` and stays up. Simplest via ArgoCD by suspending auto-sync and
   scaling deployments, not by deleting Applications. Build the list from the live cluster, not
   from this doc.
4. Final rsync delta, with `--delete`. Loki compaction and backup rotation remove files on the
   source after the first pass copies them.
5. Recreate all 10 NFS PVs against the NAS (see above), then merge the repo changes to `main`
   and let ArgoCD sync.
6. Bring apps back in dependency order: storage-facing infra (Loki) first, then media. Unsuspend
   the CronJobs explicitly; ArgoCD's selfHeal leaves `spec.suspend` alone.
7. Verify writes land on the NAS, not on a stale local mount — an empty `/mnt/storage` on a node
   with a failed mount looks identical to a working one until something writes into it.

## Mirror: worker-01's 12TB joins the pool (HOM-12)

`zpool attach` wipes the WD, which until then is the only other copy. Nothing below starts until
both gates pass.

**Gates.** First, a full `rsync -n -c` checksum pass from worker-01 (`/var/log/nas-checksum.txt`)
ending `exit=0` with no `c` (checksum) or `s` (size) flag in any itemize code. Other flags are
expected and need an explanation, not a fix. A `t` on a directory comes from writes into it, and
a `p` comes from qBittorrent's `fix-perms`, which ran `chmod -R 777` over `/data/downloads` as it
started after the 16:24 UTC cutover on 2026-09-30. `chmod` leaves mtime alone, so sort by ctime:

```bash
cut=$(date -d '2026-09-30 16:24 UTC' +%s)
sudo grep -v '^exit=' /var/log/nas-checksum.txt | while IFS= read -r line; do
  c=$(sudo stat -c %Z "/mnt/nas/${line#* }" 2>/dev/null || echo 0)
  [[ "$c" -gt "$cut" ]] && echo "after   $line" || echo "BEFORE  $line"
done | sort
```

Every line should read `after`. A `BEFORE` line is a difference the cutover doesn't explain.

Second, a clean scrub of `storage` (TrueNAS, Storage, the pool's Scrub action; `zpool status
storage` shows 0 errors).

**Window.** Keep clear of 03:00–04:30 UTC (database and Longhorn backups) and ~06:00 UTC
(unattended-upgrades re-execs systemd and restarts transient units).

### 1. Retire the drive's monitoring

Merge the HOM-13 PR first. `NfsExportDriveUnmounted` is critical and fires 10 minutes after the
mount disappears; `DiskTemperatureMetricsMissing` follows at 30. Confirm ArgoCD synced it:
`kubectl -n monitoring-system get prometheusrule nfs-export` returns NotFound.

### 2. Detach everything from worker-01's export

Clients before the server. These are hard NFS mounts: once nfsd stops, anything still mounted
blocks the process that touches it.

```bash
# Longhorn keeps the old backup target mounted in every manager pod after the URL changed
for p in $(kubectl -n longhorn-system get pods -l app=longhorn-manager -o name); do
  kubectl -n longhorn-system exec "${p#pod/}" -c longhorn-manager -- \
    umount -l /var/lib/longhorn-backupstore-mounts/192_168_30_194/mnt/storage/longhorn-backups
done

# worker-00 and worker-02: the nfs_client mount (the role is gone, its fstab line is not)
for h in 192.168.30.129 192.168.30.136; do
  ssh homelab@$h 'sudo umount -l /mnt/storage; sudo sed -i "\#^192.168.30.194:/mnt/storage #d" /etc/fstab; sudo systemctl daemon-reload'
done
```

Then on worker-01 (`ssh homelab@192.168.30.194`). The first command must print nothing:

```bash
sudo find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -lname '/mnt/storage*' 2>/dev/null
sudo umount /mnt/nas
sudo systemctl disable --now nfs-kernel-server smart-temp-textfile.timer
for src in 192.168.30.0/24 10.42.0.0/16; do for p in tcp udp; do
  sudo ufw delete allow from "$src" to any port 2049 proto "$p"; done; done
sudo rm -f /etc/systemd/system/smart-temp-textfile.{service,timer} /usr/local/bin/smart-temp-textfile \
  /var/lib/node_exporter/textfile_collector/smart_temp.prom \
  /etc/udev/rules.d/60-wd-elements-apm.rules /etc/udev/rules.d/99-nfs-storage.rules
sudo systemctl stop mnt-storage.automount
sudo umount /mnt/storage
sudo sed -i '\#^UUID=9701ed19-d894-496c-8594-1d671d789b8e #d' /etc/fstab
sudo systemctl daemon-reload
lsblk -o NAME,MOUNTPOINTS /dev/sda   # no mountpoint left
```

Stop the automount unit before unmounting: `x-systemd.automount` otherwise remounts the drive on
the next access. Unplug the enclosure once `lsblk` shows no mountpoint.

### 3. Quiesce, move the disk, bring back

Installing the disk means powering the NAS off, which stalls every NFS mount. Quiesce exactly as
in Sequence step 3, then silence the NAS-down alert for the window:

```bash
kubectl -n monitoring-system exec alertmanager-monitoring-system-kube-pro-alertmanager-0 -c alertmanager -- \
  amtool silence add alertname=NFSServerUnreachable --duration=1h \
  --comment="HOM-12 NAS power-off" --alertmanager.url=http://localhost:9093
```

Shut the NAS down from the TrueNAS UI, take the WD120EDGZ out of its USB enclosure, and connect
it to a free SATA port. It is a white-label drive: if TrueNAS does not see it, the likely cause is
the 3.3V power-disable pin, fixed with Kapton tape over SATA power pin 3 or a Molex-to-SATA
adapter. Power on and confirm the disk under Storage, Disks. Then bring the apps back as in
Sequence steps 6 and 7, including the CronJob unsuspend.

### 4. Attach and resilver

In TrueNAS: Storage, the `storage` pool, Manage Devices, select the data vdev's disk, and use
**Extend** to add the WD, which turns the single disk into a mirror. This is the step that wipes
the WD. In System, Shell, `zpool status storage` shows `mirror-0` resilvering; expect a few hours
for ~3.3 TB. Scrub again once it finishes.

### 5. After the resilver

- **Head parking.** The WD120EDGZ is an Ultrastar He12 white-label that ships at APM 128 and
  parks its heads ~50 times an hour when idle, burning its 600k load-cycle rating in about 14
  months. APM 254 stops it with no temperature cost. On worker-01 a udev rule set it; on the NAS,
  use the disk's Advanced Power Management setting if 25.10 offers it, otherwise a Post Init
  script running `smartctl --set=apm,254 /dev/disk/by-id/<the WD's ata- link>`. Confirm SMART
  attribute 193 (`Load_Cycle_Count`) stays flat across a day.
- **SMART self-tests.** Add both disks to the cron jobs from HOM-13: weekly short, monthly long,
  by `/dev/disk/by-id` path, scheduled away from the scrub.
- **Linear.** HOM-12 Done when the resilver and scrub are clean. HOM-13 and HOM-14 are Done once
  step 2's host cleanup is complete.

## After

- Config volumes stay off NFS. The arrs, Jellyfin, Navidrome, Cleanuparr and Nextcloud's `html`
  are on `longhorn`; the CNPG clusters are on `local-path`. The NAS changes neither reason:
  SQLite over NFS is still the deadlock, and NFS is still not a supported CNPG backing store.
- **`homelab.io/media` gets replaced by `homelab.io/quicksync`, on Jellyfin only.** The label
  currently means "the node with the disk" and attracts fourteen apps. Storage moving off-node
  ends that, and the Longhorn migration already removed the node pin from their config volumes,
  so dropping the nodeSelector genuinely frees the whole set rather than the three it would
  have in August. Delete it everywhere except Jellyfin, and drop the eleven now-inert
  `tolerations:` blocks in the same pass — the matching taint went on 2026-07-31.
- **Jellyfin keeps a constraint, renamed for what it now means.** With worker-00 retired and a
  second G9 arriving, the surviving question is not "which node has the media" but "keep
  transcodes off the G6." Three reasons: Intel deprecated the MediaSDK runtime behind **QSV**
  on Comet Lake and older, so worker-02's supported path is VA-API and Jellyfin's own advice is
  to buy newer ([Jellyfin hardware selection](https://jellyfin.org/docs/general/administration/hardware-selection/));
  Gen9 has no AV1 acceleration at all, so AV1 falls back to CPU there; and worker-02 never idles
  below C3 (`intel_idle` falls back to ACPI `_CST`, no BIOS knob), making it the worst host for
  sustained transcode load. `gpu.intel.com/i915: 1` alone can't express any of that — all three
  remaining nodes advertise it. Label both G9s `homelab.io/quicksync=true` and point Jellyfin's
  nodeSelector at that.
  `homelab.io/media` used by one app chosen for encoder reasons is a name that lies, and the
  rename is free while `ansible/host_vars` is being replaced by Talos machine configs anyway.
  A hard nodeSelector across two nodes leaves Jellyfin Pending only if both G9s are down. If it
  ever does land on the G6, hardware transcoding has to be set to VA-API rather than QSV — and
  `encoding.xml` is currently reset to none by the 12.0 upgrade, so that is a fresh
  configuration either way.
- worker-01 loses its 12TB USB drive, its NFS server duties, and its special status. It is still
  the largest node; nothing else about it is load-bearing.

## Talos, next

The next project is k3s → Talos (`docs/talos-migration-audit.md`). That audit's verdict is
"NAS first, Talos second": worker-01 running `nfs-kernel-server` is the migration's one hard
blocker, and this move is what removes it. A few choices here are load-bearing for that.

- **NFSv4 answers a Talos open question for free.** Audit verify-item #4 asks whether any arr
  needs NFSv3 locking, which on Talos would mean adding the `nfs-utils` system extension to
  the Image Factory schematic. Exporting v4-only settles it during this migration, months
  before the schematic has to be written — v4 carries locking in-protocol, no `rpc.statd`.
  If something does turn out to need v3, that is worth knowing now rather than mid-rebuild.
- **Every backup must be on the NAS before a node is wiped.** Talos Phase 2 is a rebuild of all
  three nodes, not a rolling migration — k3s and Talos control planes do not interoperate. The
  arrs' own System → Backup, both CNPG `pg_dump`s, and the Longhorn backup target all currently
  write to `/mnt/storage`, i.e. to the node being wiped. Once the NAS holds them that hazard is
  gone, and it is the single largest reason to finish this project first.
- **Don't join the NAS to the cluster.** An N305 with 16GB is tempting as a fourth node. It is
  the box that has to survive the Talos rebuild with the data on it.
- **The NAS becomes the out-of-band host.** Talos has no SSH. Something on `192.168.30.0/24`
  needs to run `talosctl`, hold `secrets.yaml` (a cluster root CA bundle — never committed),
  and verify a mount from outside the cluster. TrueNAS has a shell and stays up during the
  rebuild.
- **Deleting the SMART exporter deletes the disk observability with it.** The audit counts this
  as a NAS-first win because the Talos nodes are left with only NVMe, which `hwmon` covers. True
  only if TrueNAS is actually alerting on its own disks — its default is email, not Prometheus.
  Set that up in the same pass as deleting `smart-temp-textfile`, or the 12TB's temperature and
  head-parking go unwatched.

## Gotchas

- The Vaultwarden data-PVC deletion gated to 2026-08-26 is unrelated but touches the same volume;
  don't interleave the two.
- qBittorrent's gluetun `FIREWALL_OUTBOUND_SUBNETS: 10.0.0.0/8,192.168.0.0/16` already covers any
  address in `192.168.30.0/24`, so NFS traffic to the NAS bypasses the VPN without a change. If
  the NAS lands on a different subnet, that list needs the new CIDR or torrent I/O goes through
  Mullvad.
- The pool is renameable only by export/import, and every path in this repo now assumes
  `/mnt/storage/data`. Leave both names alone.
- `system/monitoring-system/prometheusrule-nfs-export.yaml` and the media dashboard's capacity
  panels read worker-01's local XFS mount. They stay correct until that disk is wiped for the
  mirror (HOM-12), and go with the SMART exporter in HOM-13.
- Attaching worker-01's 12TB as a mirror destroys everything on it. It is the only other copy
  until the attach completes and resilvers, so verify the new disk first — a full `rsync -n`
  pass, not a spot check.
