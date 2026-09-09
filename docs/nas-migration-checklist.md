# NAS Migration Checklist

What has to change in this repo when `/mnt/storage` stops being a USB drive on worker-01 and
becomes a NAS.

Throughout: `NAS_IP` is the NAS's address on `192.168.30.0/24`.

## Hardware

CWWK N305 mini-ITX (6x SATA, 2x i226-V 2.5G), 16GB DDR5, 256GB NVMe boot, PicoPSU-160-XT +
192W adapter, 2U rack shelf. One new 12TB disk to start; worker-01's existing 12TB joins as a
mirror once the data is copied and verified.

160W does not cover six drives spinning up at once. Fine for the two this build ends at.

## Decisions

- **OS: TrueNAS SCALE.** ZFS snapshots, scrubs and disk monitoring without building them.
- **Pool name: `storage`.** TrueNAS mounts a pool at `/mnt/<poolname>`, so this gives
  `/mnt/storage` verbatim and the repo change stays a sed on the IP alone. Any other pool name
  costs every `path:` in the tables below plus re-pointing the arrs' root folders, Jellyfin's
  libraries and qBittorrent's save paths by hand in their own UIs.
- **One dataset, plain directories underneath.** `downloads/ media/ photos/ nextcloud/
  backups/ vaultwarden/` stay directories at the pool root, so one NFS export covers them all.
  Separate datasets would buy per-directory snapshots and quotas at the cost of NFSv4
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

`192.168.30.194` → `NAS_IP` everywhere it means "the storage server". Note that the same IP is
also worker-01's node address in `ansible/inventory.yml` and must **not** change there.

| File | What it is |
|---|---|
| `system/nfs-provisioner/values.yaml` | `nfs.server` / `nfs.path` for the `nfs` StorageClass. Everything using `storageClass: nfs` follows this one value. |
| `ansible/roles/nfs_client/defaults/main.yml` | `nfs_server_host`, `nfs_server_export` |
| `apps/immich/library-pv.yaml` | static PV → `/mnt/storage/photos` |
| `apps/nextcloud/data-pv.yaml` | static PV → `/mnt/storage/nextcloud` |
| `apps/{sonarr,radarr,lidarr,bazarr,prowlarr,qbittorrent,unpackerr,jellyfin,navidrome,rclone-seedbox}/values.yaml` | inline `type: nfs` data volume |
| `apps/jellyfin/backup-cronjob.yaml` | inline NFS volume → `/mnt/storage/backups/jellyfin` |
| `apps/cleanuparr/backup-cronjob.yaml` | inline NFS volume → `/mnt/storage` |
| `CLAUDE.md`, `.claude/commands/add-app.md`, `README.md`, `system/infisical/README.md` | documented patterns new apps get copied from — update or the next app regresses |

Consumers that need **no** edit because they go through the StorageClass: `apps/vaultwarden/data-pvc-nfs.yaml`,
`apps/recyclarr/values.yaml`, the four `pg-backup.yaml` PVCs (immich, nextcloud, vaultwarden,
infisical), `system/loki/values.yaml`, `system/monitoring-system/values.yaml`.

The static PVs (immich, nextcloud) are the awkward ones: `spec.nfs.server` is immutable. Changing
it means deleting and recreating the PV/PVC pair. `persistentVolumeReclaimPolicy: Retain` means
the data survives that, but the pods must be scaled to zero first and the PVC recreated with the
same `volumeName` before they come back.

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

`system/monitoring-system/prometheusrule-temperature.yaml` has a rule group for the USB drive fed
by a `smart-temp-textfile.timer` unit in `ansible/roles/common`. The file already says to delete
both when storage moves to a NAS — but only configured TrueNAS alerting makes that true, see
"Talos, next". Also check
`system/monitoring-system/dashboard-media-stack.yaml` for panels keyed to the worker-01 mount.

## Sequence

1. Provision the NAS, create the export, verify from a node: `mount -t nfs4 NAS_IP:NAS_EXPORT /mnt/test`.
2. Copy data. `rsync -aHAX --numeric-ids` from worker-01's `/mnt/storage`, run twice — once live,
   once after the apps are stopped, to catch the delta.
3. Scale to zero everything holding NFS state: the arrs, qBittorrent, unpackerr, Jellyfin,
   Navidrome, Immich, Nextcloud, Vaultwarden, Loki, Prometheus. Simplest via ArgoCD by suspending
   auto-sync and scaling deployments, not by deleting Applications.
4. Final rsync delta.
5. Merge the repo changes to `main`, let ArgoCD sync. Recreate the two static PVs by hand.
6. Bring apps back in dependency order: storage-facing infra (Loki, Prometheus) first, then media.
7. Verify writes land on the NAS, not on a stale local mount — an empty `/mnt/storage` on a node
   with a failed mount looks identical to a working one until something writes into it.

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

- `apps/vaultwarden/data-pvc-nfs.yaml` documents its recovery path as
  `192.168.30.194:/mnt/storage/vaultwarden/vaultwarden-db-backup`. That comment is the restore
  runbook — update it or the next restore looks in the wrong place.
- The Vaultwarden data-PVC deletion gated to 2026-08-26 is unrelated but touches the same volume;
  don't interleave the two.
- qBittorrent's gluetun `FIREWALL_OUTBOUND_SUBNETS: 10.0.0.0/8,192.168.0.0/16` already covers any
  address in `192.168.30.0/24`, so NFS traffic to the NAS bypasses the VPN without a change. If
  the NAS lands on a different subnet, that list needs the new CIDR or torrent I/O goes through
  Mullvad.
- Do not let TrueNAS name the pool anything but `storage`. It is renameable only by
  export/import, and every path in this repo assumes `/mnt/storage`.
- Attaching worker-01's 12TB as a mirror destroys everything on it. It is the only other copy
  until the attach completes and resilvers, so verify the new disk first — a full `rsync -n`
  pass, not a spot check.
