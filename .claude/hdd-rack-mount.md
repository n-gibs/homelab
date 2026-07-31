# Runbook: shuck the 12TB drive and rack-mount it

Written 2026-07-31, executed in stages as parts arrive — see the staging table below. Background
and evidence live in [`hdd-running-hot.md`](hdd-running-hot.md); this is the execution plan only.

**Goal:** get the WD120EDGZ out of the fanless WD Elements shell, where it idles at 56–57C
against a 65C ceiling, and mount it bare in the 12U 10-inch rack on a WAVLINK SATA-to-USB-C
adapter. Success is a lower steady-state temperature with SMART, APM and the mount all still
working.

**Not a data migration.** The platters are untouched. WD *Elements* has no hardware encryption
in the bridge (unlike My Book), so the drive is readable in any enclosure. It is also a helium
drive — hermetically sealed — so running it bare exposes nothing.

## Hardware decisions already made

**Destination: bare drive, rack-mounted, on the WAVLINK adapter.** Its spec clears the two
things that would have ruled it out — a 12V brick is included (USB cannot power a 3.5" drive)
and it addresses to 20TB (cheap 32-bit-LBA bridges cap at 2TiB and corrupt rather than fail on
a 12TB disk). UASP support implies a modern ASMedia or JMicron bridge, so SAT passthrough will
probably work better than the WD bridge, which throws a bogus threshold checksum on every call.

**Mount it low in the rack.** The rack is open front and back with acrylic sides *and bottom*.
The capped bottom is the problem: there is no low intake, so the 12U column stratifies and heat
pools at the top. Above the nodes is the worst position available — it puts a drive with 9C of
headroom in three mini PCs' rising exhaust. Low and clear is the coolest air in the rack, and
until the fan lands it is the only cooling lever available.

**Vibration:** on the open shelf (stage A) that means a rubber or anti-static mat under the
drive. In the 2-bay enclosure (stage C) it means grommets rather than a rigid mount — a 7200rpm
3.5" drive bolted hard to the frame turns the rack into a soundboard.

**Testable prediction worth checking while you are in there:** if worker-02 is the highest node
in the rack, that confirms stratification. It took the biggest ambient hit on 07-30 (+5C, vs +3
and +2 for the others).

## Three stages, gated on parts — not one job

Hardware is arriving over about two weeks, and the stages are independent. Do each as its parts
land, one variable at a time, and the dashboard attributes each change on its own.

| stage | needs | disruptive? | when |
|---|---|---|---|
| **B — 1U intake fan** | the fan | **no**, nothing unmounts | available now — **do first** |
| **A — shuck, WAVLINK, open shelf** | adapter + shelf | **yes**, full cluster quiesce | available now |
| **C — 2x 3.5" rack enclosure** | the enclosure | **yes**, second quiesce | ~1–2 weeks |

**B before A**, both doable in one day. B costs no downtime, so it goes first: fit it, give it an
hour, record the numbers, and only then start A. That way the fan's effect and the shuck's effect
are separate measurements instead of one combined mystery — the same discipline that made the APM
result trustworthy.

**A and C each cost a cluster outage.** Doing A now means doing the quiesce twice. That is a
real cost and the alternative — wait, do it once when the enclosure lands — is defensible: the
urgent problem (head parking) is already fixed, and what remains is a slow longevity issue with
9C of margin, 0 seconds over-temperature and clean SMART. Two more weeks is ~330 hours against a
multi-year life.

What makes either choice safe is that the thermal risk is now monitored. If a hot spell erodes
the margin, `DiskTemperatureAboveSpec` fires at the rated max sustained 15m and
`DiskTemperatureCritical` 5C past it. Waiting is a decision, not an oversight.

Doing A early buys two weeks of much cooler running and the bare-drive floor measurement, at the
price of a second outage. Either is reasonable; the runbook supports both.

**Open question that affects C:** if the 2-bay enclosure is *passive* — a cage holding bare
drives with the WAVLINK still the bridge — then Phase 4's bridge checks happen once and stage C
is purely mechanical. If it is an *active* DAS with its own bridge, it replaces the WAVLINK
entirely and stage C needs the full Phase 4 verification again with a different chip. Worth
knowing before C, not during it.

### Stage B — the 1U fan (do this first)

1U panel, 3x 40mm dual-ball-bearing fans, 13.41 CFM total, 5V 1A barrel supply, on/off switch.
Non-disruptive: no unmount, no downtime, so it never needs to be bundled with drive work.

**Mount it as designed — rear exhaust — and mount it low.** The nodes already establish
front-to-back flow (ProDesk Minis pull in and exhaust out the back), so rear exhaust reinforces
what the hardware does rather than introducing a competing stream at one height. The "prevent
thermal recirculation" claim is real in a small acrylic-sided rack: hot air leaving the back
cannot loop round to the front intakes.

**Do not decide orientation yet — it cannot be answered in this stage.** During B the drive is
still in its shell on the floor, so the fan cannot affect it; B measures the *node* effect only,
and for that either direction moves air through the column. Orientation only matters once the
drive is on the shelf. If the drive disappoints after stage A, flip the panel 180 degrees to
front intake aimed across the shelf, wait an hour, and compare — 13.41 CFM is modest (a 120mm
case fan moves 50–70), so aiming it at the one component near a limit may beat diffusing it. Two
hours, zero downtime, and it settles the question for this specific geometry instead of by
argument.

Correcting an earlier assumption in this doc: the front and back are fully open, so intake is
**not** blocked the way a closed-door rack would be — air can enter at any height. What is
missing is movement, not access. Expect a smaller ambient win than a sealed rack would give, and
do not be disappointed by a couple of degrees.

**Noise is the likely reason this comes back out.** Three 40mm fans at 4500 RPM: 25 dBA is the
claim, but small high-RPM fans are tonal in a way that number does not capture, and the panel has
an on/off switch with no speed control. Worth an honest listen before committing it to 24/7.

**Placement, decided:** rear rails (confirmed available), fans blowing outward, low in the rack
and below the nodes so the drive is never in their rising exhaust. Adjacent to the drive shelf,
not across the rack — with 13.41 CFM, distance costs a lot. **Below** the shelf if it is vented or
mesh, so air rises through it past the drive's underside; **directly behind** it at the same
height if the shelf is solid metal, since a solid shelf makes "below" a separate airflow zone that
never touches the drive. If mounting behind, push the drive as close to the fan as the cable
allows: a flat 3.5" drive is only ~26mm tall, so most of a 1U aperture is looking at empty air
rather than at the drive.

- [ ] Fitted low on the rear rails, blowing outward
- [ ] Noise acceptable where the rack actually lives
- [ ] One hour elapsed, all three node temps recorded in the Phase 6 table
- [ ] Only then start stage A
- [ ] **After** stage A: if the drive disappoints, flip to front intake and re-measure

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
- [ ] **PWDIS / the 3.3V pin — the most likely "I killed it" false alarm.** WD white-labels
      implement SATA power pin 3 as power-disable. A supply that puts 3.3V on that pin holds the
      drive in reset and it simply will not spin up. This matters *more* with a bare adapter
      than with an enclosure, because the WAVLINK presents a real SATA power connector. If the
      drive appears dead on first power-on, tape pins 1–3 with Kapton before concluding
      anything. It is not the shuck.
- [ ] Connect to the WAVLINK adapter, power from its 12V brick.
- [ ] **Optional but recommended: run it bare in open air for an hour first.** That is the floor
      value — the coldest this drive can physically be. Every later number is measured against
      it, and you cannot get it any other way. Record it here.
- [ ] Place on the open shelf, **as low in the rack as the shelf allows, and never above the
      nodes** — that would put a drive with 9C of headroom in three mini PCs' rising exhaust.
      With no fan yet, position is the only cooling lever you have, so spend it here.
- [ ] **Label up, and not directly on bare metal.** The PCB is exposed on the underside of a
      bare drive; resting it on a metal shelf is a short and ESD risk. A rubber or anti-static
      mat underneath, which also damps vibration — a 7200rpm drive on a bare shelf will buzz.
- [ ] Secure it so it cannot be knocked or slide. Cable ties or a strap are fine until the
      2-bay enclosure arrives; the acrylic sides help, but an unsecured drive on a shelf next
      to a live cluster is the main risk of running stage A ahead of stage C.
- [ ] Cable management: enough slack on the USB-C run to worker-01 that nothing is under
      tension, and the 12V brick reaching an outlet without strain. A tugged cable on a live NFS
      export is a worse failure than the heat we are fixing.

Open-air baseline: ______ C   ·   On the shelf, no fan: ______ C

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

Temperature needs hours, not minutes — a 12TB drive has a thermal time constant of tens of
minutes and the answer is the steady state, not the first reading.

Four numbers to compare, which is why each change gets its own window:

| | drive | worker-00 | worker-01 | worker-02 | stage |
|---|---|---|---|---|---|
| WD Elements shell, on the floor | **56–57C** | 48–55 | 47–51 | 43–44 | baseline 2026-07-31 |
| after the 1U fan, rear exhaust | n/a — still on the floor | | | | B |
| bare in open air | | — | — | — | A, Phase 3 |
| bare on the rack shelf | | | | | A, Phase 6 |
| fan flipped to front intake | | | | | only if needed |
| in the 2-bay enclosure | | | | | C |

Node columns matter: the fan's effect is cluster-wide, and all three got warmer on 07-30, not
just the disk. If the nodes improve and the drive barely does, the air is not reaching the shelf.

- [ ] Same evening: read the racked steady state off the dashboard
- [ ] Confirm `rate(node_smart_load_cycle_count[1h]) * 3600` is at 0, not ~50
- [ ] Confirm Load_Cycle_Count is near 55971 — a few cycles from the power cycle are normal
- [ ] Update `hdd-running-hot.md` with the result and close out hypothesis #1
- [ ] If the serial changed, commit the udev rule fix
- [ ] Note whether the other two nodes also improved — the fan's effect is cluster-wide

**What good looks like:** a steady-state idle temperature meaningfully below 56C with SMART
still readable, APM at 254, and load cycles flat.

**How to read the gaps.** If racked lands within a couple of degrees of open air, the rack
breathes fine and you are done. A large gap means the rack is now the bottleneck, not the
enclosure — which is an argument for prioritising the DeskPi top exhaust when it restocks, and a
fact worth knowing about all the hardware in there, not just this drive.

## Rollback

At any point before Phase 5, the WD Elements shell still works. Put the drive back, remount,
restore. The only irreversible step is physical damage during shucking, and the clips are the
only fragile part.
