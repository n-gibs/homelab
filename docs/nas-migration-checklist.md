# NAS Migration Checklist

What has to change in this repo when `/mnt/storage` stops being a USB drive on worker-01 and
becomes a NAS. Written against the state of `main` on 2026-08-13.

Throughout: `NAS_IP` is the NAS's address on `192.168.30.0/24`, `NAS_EXPORT` its NFS export
path. Everything below assumes the NAS speaks NFSv4.1 and the export keeps the existing
`downloads/ media/ photos/ nextcloud/ backups/ vaultwarden/` layout. If the layout changes,
every path in the tables below changes with it and the arrs need their root folders re-pointed
in their own UIs (not in git).

## Decide first

These three choices change the size of the migration.

0. **Which network segment it lands on.** The nodes sit on `192.168.30.0/24`, served by a
   dedicated OPNsense interface. Plugged into the same switch as the nodes, the NAS picks up an
   address on that subnet with no switch configuration — give it a static DHCP reservation in
   OPNsense and use that as `NAS_IP`. Confirm from the lease table before doing anything else: a
   NAS on a different subnet means firewall rules between OPNsense interfaces and an extra CIDR
   in gluetun's `FIREWALL_OUTBOUND_SUBNETS`, or torrent I/O routes through Mullvad.
1. **Export path layout.** Keeping `/mnt/storage/...` verbatim on the NAS means only the server
   IP changes — a sed across ~25 files. Any other layout means touching every `path:` too and
   reconfiguring the arrs, Jellyfin libraries, and qBittorrent's save paths by hand.
2. **Do the nodes still mount it?** `ansible/roles/nfs_client` mounts the share on all three
   hosts at `/mnt/storage`. Nothing in the cluster consumes the host mount — pods mount NFS
   directly — so this role exists for shell convenience. Keep it (repoint) or delete it.
3. **Does `homelab.io/media=true` still mean anything?** Media apps pin to worker-01 with a
   nodeSelector because that is where the disk is. Once storage is off-node that reason is
   gone; the label then mostly means "the biggest node." Either keep it as a capacity hint or
   drop the nodeSelector blocks. Note this frees only the three apps with no `local-path`
   volume, and Jellyfin should keep the label for a different reason — see "After" below.

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
settings that mattered on the NAS side:

- Export to `192.168.30.0/24` only.
- `no_root_squash` — qBittorrent's `fix-perms` initContainer runs `chmod -R 777 /data/downloads
  /data/media` as uid 0 on every pod start and silently fails without it.
- Directories owned `nobody:nogroup`, mode 0755. Nextcloud's init container chowns its own
  subdir to 33:33 on start; Immich and the arrs run as 1000:1000 against 777 dirs.
- Consider whether `sync` is still wanted. The current export is `sync` on a spinning USB disk,
  which is a large part of why Nextcloud's ~15k-file PHP tree was moved to `local-path`.

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

- Every `local-path` PVC in the repo (the arrs' SQLite configs, Nextcloud's `html`, the CNPG
  clusters) stays on `local-path`. The NAS does not change the SQLite-over-NFS problem or make
  NFS a supported CNPG backing store. The `CLAUDE.md` rationale that says "`nfs` was never giving
  these volumes a second node, since worker-01 *is* the NFS server" **does** become wrong though,
  and should be rewritten — after the migration NFS genuinely is off-host.
- Media apps no longer need the `homelab.io/media` nodeSelector to reach storage — but removing
  it frees fewer of them than it looks. Seven of the ten labelled apps (sonarr, radarr, lidarr,
  bazarr, prowlarr, navidrome, jellyfin) keep their SQLite config on a bound `local-path` PV,
  whose node affinity pins the pod regardless of any label. The NAS does not change that: SQLite
  over NFS is still the deadlock that put them there. Only **qbittorrent, unpackerr, and
  rclone-seedbox** — the three with no `local-path` volume — actually become schedulable
  elsewhere. Worth doing (qBittorrent plus gluetun is not a small pod), but it is a modest
  rebalance, not a cluster-wide one. Do it as a separate PR after the storage move is proven
  stable, and drop the now-inert `tolerations:` blocks in the same pass — the matching taint was
  removed on 2026-07-31.
- **Jellyfin keeps the label**, for QuickSync rather than for storage. Both worker-01 and
  worker-02 advertise `gpu.intel.com/i915`, so the resource request alone only rules out
  worker-00 (i915 blacklisted) and would happily schedule Jellyfin onto worker-02's 10th-gen
  iGPU instead of worker-01's 12th-gen. The label is what expresses "the better encoder."
  Note it is not what actually pins the pod: `jellyfin-config-local` is a bound `local-path`
  PV, and its node affinity is the real constraint. Keep the label pointed at the node that PV
  lives on — repointing it elsewhere leaves the pod Pending, not migrated.
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
- If the NAS exports NFSv3 only, the `mountOptions: [nfsvers=4.1]` on both static PVs will fail
  to mount with no useful error beyond a stuck pod.
