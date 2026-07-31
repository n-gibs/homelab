# Runbook: move the 12TB drive into the UGREEN enclosure

Planned for 2026-08-01. Background and evidence live in [`hdd-running-hot.md`](hdd-running-hot.md);
this is the execution plan only.

**Goal:** get the WD120EDGZ out of the fanless WD Elements shell, where it idles at 56–57C
against a 65C ceiling, and into a ventilated UGREEN enclosure. Success is a lower steady-state
temperature with SMART, APM and the mount all still working.

**Not a data migration.** The platters are untouched. WD *Elements* has no hardware encryption
in the bridge (unlike My Book), so the drive is readable in any enclosure.

---

## Before-state — captured 2026-07-31, verify against this afterwards

| | value |
|---|---|
| `ID_SERIAL_SHORT` | `WD-B002KX5D` |
| `ID_MODEL` | `WDC_WD120EDGZ-11CNVA0` |
| USB ID (old bridge) | `1058:25a3` Western Digital Elements Desktop |
| filesystem UUID | `9701ed19-d894-496c-8594-1d671d789b8e` (xfs) |
| PARTUUID | `404ca8c1-e777-43ea-a65b-1d2c3e80fb3a`, PARTLABEL `Elements` |
| sector size | **512 logical / 4096 physical** (512e) |
| size | `12000105070592` bytes |
| APM | 254 (set by udev rule) |
| Load_Cycle_Count | **55971** |
| Power_On_Hours | 937 |
| temperature | 56–57C idle |
| fstab | `UUID=9701ed19-… /mnt/storage xfs defaults,nofail,x-systemd.automount 0 0` |
| export | `/mnt/storage 192.168.30.0/24(rw,sync,no_root_squash,…)` |

The mount is **UUID-based** and the export is **path-based**, so a device rename `sda` → `sdb`
breaks nothing. Don't "fix" fstab if the kernel name changes.

---

## Blast radius

`/mnt/storage` backs 13 PVCs on the `nfs` StorageClass plus direct NFS mounts. **14 workloads
across 14 namespaces** depend on it:

```
bazarr  jellyfin  lidarr  loki  monitoring-system(prometheus)  navidrome
nfs-provisioner  prowlarr  qbittorrent  radarr  recyclarr  sonarr
unpackerr  vaultwarden
```

Plus two CronJobs that a running-pod scan misses because they only exist while firing:
`recyclarr/recyclarr` (04:00) and `immich/immich-db-backup` (03:30), both writing to NFS PVCs.

Two of these change how we do this:

- **Prometheus's TSDB PVC is on the drive.** The dashboard and alerts we built to watch this
  swap are themselves inside the blast radius. Capture the before-state over SSH, not from
  Grafana. The TSDB itself is fine — it lives on the drive and comes back with it — there will
  just be a gap in every series across the window.
- **Vaultwarden is a SQLite database on NFS.** Yanking storage out from under it risks
  corruption. It gets a clean shutdown, not a hang.

NFS hard mounts *block* rather than error, so an unplanned pull doesn't return errors — pods
just freeze until the drive returns. That is survivable for stateless things and not worth
risking for the SQLite-backed ones (vaultwarden, the whole arr stack, navidrome, jellyfin).

**`selfHeal: true` is set on every Application and `replicas` is tracked in the rendered
manifests.** A plain `kubectl scale ... --replicas=0` gets reverted within seconds. Patching the
Application spec doesn't help either — the ApplicationSet controller rewrites it. The lever that
works is stopping the application controller for the window.

---

## Phase 0 — capture (before touching anything)

```bash
ssh homelab@192.168.30.194 '
  udevadm info --query=property --name=/dev/sda | grep -E "ID_SERIAL_SHORT|ID_MODEL|ID_BUS"
  sudo smartctl -A /dev/sda 2>/dev/null | awk "\$1==9||\$1==193||\$1==194"
  sudo smartctl --get=apm /dev/sda | grep -i "apm level"
  sudo blockdev --getss --getpbsz --getsize64 /dev/sda
  sudo blkid /dev/sda1
  findmnt -n /mnt/storage
' | tee ~/hdd-swap-before.txt
```

`smartctl` exits non-zero on this drive on **every** call — the enclosure reports an invalid
checksum in the SMART threshold structure while returning good data. Under `set -euo pipefail`
that kills the script after reading the value. Use `|| true` in anything scripted.

- [ ] Output captured and matches the table above

## Phase 1 — quiesce

Expect the dead-man's switch to fire: Prometheus and Alertmanager go down with the drive, the
healthchecks.io ping stops, and you get notified. That is the switch working. Pause the check
first if you don't want the page.

- [ ] Pause the healthchecks.io check (or accept the notification)

```bash
# 1. Stop self-heal fighting us. Nothing reconciles while this is at 0.
kubectl -n argocd scale sts argocd-application-controller --replicas=0

# 2. Scale down every NFS-dependent workload.
for ns in bazarr jellyfin lidarr navidrome nfs-provisioner prowlarr \
          qbittorrent radarr sonarr unpackerr vaultwarden; do
  kubectl -n "$ns" scale deploy --all --replicas=0
done
kubectl -n loki scale sts loki --replicas=0

# 3. Two CronJobs write to NFS PVCs. Suspend both so neither fires mid-swap.
#    They run at 03:30 and 04:00, so a daytime swap is unlikely to collide — but a Job
#    that starts while the mount is gone is a corrupt backup, not a failed one.
kubectl -n recyclarr patch cronjob recyclarr        -p '{"spec":{"suspend":true}}'
kubectl -n immich    patch cronjob immich-db-backup -p '{"spec":{"suspend":true}}'

# 4. Prometheus is operator-managed: scaling the StatefulSet gets reconciled back.
#    Patch the Prometheus CR instead. (Safe now that the app controller is down.)
kubectl -n monitoring-system patch prometheus monitoring-system-kube-pro-prometheus \
  --type merge -p '{"spec":{"replicas":0}}'
```

- [ ] `kubectl get pods -A | grep -v Running` shows the above gone, not restarting

## Phase 2 — detach

```bash
ssh homelab@192.168.30.194 '
  sudo exportfs -ua                      # drop all NFS exports
  sudo fuser -vm /mnt/storage || true    # expect nothing; investigate if not
  sudo umount /mnt/storage
  sudo systemctl stop mnt-storage.automount || true
  findmnt /mnt/storage || echo "unmounted cleanly"
'
```

If `umount` reports the target is busy, find the holder with `fuser -vm` and stop it. **Do not
use `umount -l`** — a lazy unmount detaches the tree while writes are still in flight, which is
the one way to actually lose data here.

- [ ] Unmounted cleanly, then power off and unplug the enclosure

## Phase 3 — the physical swap

- [ ] Shuck the WD Elements. Shell is clipped, not screwed — a guitar pick or spudger along the
      seam. No warranty to lose on either part.
- [ ] Seat the drive in the UGREEN enclosure.
- [ ] **If the UGREEN uses a real SATA power connector:** WD white-labels implement SATA power
      pin 3 as PWDIS (power disable). A PSU that supplies 3.3V there holds the drive in reset
      and it simply won't spin up. Kapton tape over pins 1–3, or a Molex-to-SATA adapter, which
      doesn't carry 3.3V. If the drive appears dead on first power-up, this is the cause — not
      the shuck.
- [ ] Confirm the new enclosure actually moves air. A second fanless shell buys nothing; that
      was the whole problem.

## Phase 4 — reattach and verify

```bash
ssh homelab@192.168.30.194 '
  dmesg | tail -20                       # confirm enumeration, note the kernel name
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL | grep -v nvme
  DEV=/dev/sda                           # adjust if it came back as sdb
  udevadm info --query=property --name=$DEV | grep -E "ID_SERIAL_SHORT|ID_MODEL"
  sudo smartctl --get=apm $DEV | grep -i "apm level"
  sudo blockdev --getss $DEV
  sudo blkid ${DEV}1
'
```

Check each against Phase 0, in this order:

| check | expected | if it differs |
|---|---|---|
| `blkid` UUID | `9701ed19-…` | Stop. Wrong device, or see sector size below. |
| `blockdev --getss` | `512` | If `4096`, the bridge presents 4Kn and the partition table looks unreadable. **This is not data loss and you must not reformat.** Put it back in the WD shell or a 512e enclosure. |
| SMART readable at all | yes | Bridge doesn't do SAT passthrough. Try `-d sat`. If nothing works you lose temperature, load-cycle metrics and APM control — `DiskTemperatureMetricsMissing` will fire in 30m. Consider a different enclosure. |
| `ID_SERIAL_SHORT` | `WD-B002KX5D` | Bridge substituted its own serial → the udev rule no longer matches. See below. |
| `--get=apm` | `254` | If the serial matched, this should already be 254 with no action. |

**If `ID_SERIAL_SHORT` changed**, the udev rule is dead and head parking resumes silently.
Fix in `ansible/roles/common/tasks/main.yml`, task *"Stop the 12TB USB drive parking its heads
every minute"* — replace the serial in `ENV{ID_SERIAL_SHORT}=="WD-B002KX5D"`, then:

```bash
ansible-playbook -i ansible/inventory.yml ansible/site.yml --tags common --limit worker-01
ssh homelab@192.168.30.194 'sudo smartctl --set=apm,254 /dev/sda; sudo smartctl --get=apm /dev/sda'
```

`DiskHeadParkingResumed` is the backstop if we miss this — it fires at >10 cycles/hr sustained
for 1h — but fixing it here is better than being told in two hours.

- [ ] All five checks pass or are consciously accepted

## Phase 5 — remount and restore

```bash
ssh homelab@192.168.30.194 '
  sudo systemctl daemon-reload
  sudo mount /mnt/storage        # fstab is UUID-based; no edit needed
  findmnt /mnt/storage
  sudo exportfs -ra
  sudo exportfs -s
  ls /mnt/storage
'
```

Then reverse Phase 1 — **app controller last**, so ArgoCD restores desired state rather than
racing our manual scale-ups:

```bash
kubectl -n monitoring-system patch prometheus monitoring-system-kube-pro-prometheus \
  --type merge -p '{"spec":{"replicas":1}}'
kubectl -n recyclarr patch cronjob recyclarr        -p '{"spec":{"suspend":false}}'
kubectl -n immich    patch cronjob immich-db-backup -p '{"spec":{"suspend":false}}'
kubectl -n argocd scale sts argocd-application-controller --replicas=1
```

Everything else scales itself back up — `selfHeal` restores the tracked `replicas: 1` once the
controller returns. That is the same mechanism that would have fought us in Phase 1, used
deliberately.

- [ ] `kubectl get pods -A | grep -v Running | grep -v Completed` is empty
- [ ] All ArgoCD apps Synced/Healthy
- [ ] Grafana *Homelab — Temperatures* is reporting again
- [ ] Un-pause the healthchecks.io check

## Phase 6 — did it work?

Temperature needs hours, not minutes — a 12TB drive in a new enclosure has a thermal time
constant of tens of minutes and the answer is the steady state, not the first reading.

- [ ] Same evening: compare against the 56–57C idle baseline on the dashboard
- [ ] Confirm `rate(node_smart_load_cycle_count[1h]) * 3600` is at 0, not ~50
- [ ] Confirm Load_Cycle_Count is near 55971 — a few cycles from the power cycle are normal
- [ ] Update `hdd-running-hot.md` with the result and close out hypothesis #1
- [ ] If the serial changed, commit the udev rule fix

**What good looks like:** a steady-state idle temperature meaningfully below 56C with SMART
still readable, APM at 254, and load cycles flat. If temperature barely moves, the new enclosure
isn't moving enough air either and a fan pointed at it is the next cheapest thing.

## Rollback

At any point before Phase 5, the WD Elements shell still works. Put the drive back, remount,
restore. The only irreversible step is physical damage during shucking, and the clips are the
only fragile part.
