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

Still open:

- **Do the nodes still mount it?** `ansible/roles/nfs_client` mounts the share on all three
  hosts at `/mnt/storage`. Nothing in the cluster consumes the host mount — pods mount NFS
  directly — so this role exists for shell convenience. Keep it (repoint) or delete it.
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
both when storage moves to a NAS — the NAS monitors its own disks. Also check
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
- Media apps no longer need the `homelab.io/media` nodeSelector to reach storage, and since the
  Longhorn migration removed the node pin from their config volumes, dropping it genuinely
  frees the whole set rather than the three it would have in August. Do it as a separate PR
  after the storage move is proven stable, and drop the now-inert `tolerations:` blocks in the
  same pass — the matching taint was removed on 2026-07-31.
- **Jellyfin keeps the label**, for QuickSync rather than for storage. Both worker-01 and
  worker-02 advertise `gpu.intel.com/i915`, so the resource request alone only rules out
  worker-00 (i915 blacklisted) and would happily schedule Jellyfin onto worker-02's 10th-gen
  iGPU instead of worker-01's 12th-gen. The label is what expresses "the better encoder."
- worker-01 loses its 12TB USB drive, its NFS server duties, and its special status. It is still
  the largest node; nothing else about it is load-bearing.

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
