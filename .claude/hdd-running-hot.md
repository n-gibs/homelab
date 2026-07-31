# Investigation prompt: why the 12TB HDD runs at 56–61C

Investigation handoff written 2026-07-31. Paste the section below into a new session.

---

Find out why worker-01's 12TB USB drive runs at 56–61C against a 65C vendor maximum, and
fix it if it is fixable. Rigorous systematic debugging: measure before concluding, one
hypothesis at a time, and verify with a real reading before declaring anything solved.

**Read this whole file before touching anything.** The obvious first guess — "something is
hammering the disk" — is already measured and disproved below. Do not start there.

## The symptom

`/dev/sda` on worker-01 (192.168.30.194) sits at 56–61C. Vendor-specified maximum operating
temperature is **65C**, so there is roughly 4–9C of headroom on the disk that backs
`/mnt/storage`: every NFS PVC in the cluster and the entire media library.

Nothing is failing. This is a longevity question, not an outage.

```bash
sudo smartctl -A /dev/sda | grep 194          # current temp, raw value
sudo smartctl -l devstat /dev/sda | grep -i temp   # min/max/average history
```

## Measured baseline — do not re-derive

Hardware:
- Enclosure: **WD Elements**, external USB, fanless. **Bought used on eBay**, so whether the
  drive inside is the one that shipped in it is unconfirmed.
- Drive: **WDC WD120EDGZ-11CNVA0**, serial `WD-B002KX5D`, firmware `01.01A01`. smartctl
  reports Model Family `Western Digital Ultrastar (He10/12)` from its own drive database, and
  **7200 rpm / 3.5" / 12TB** read from the drive itself.
- A 7200rpm helium drive in a fanless plastic shell is the leading explanation for the
  temperature. Note this does **not** require anyone to have swapped the drive — WD Elements
  units of this capacity are commonly found with 7200rpm helium white-label drives inside, so
  the pairing may well be factory. Treat "is it original" and "does the enclosure cool it" as
  two separate questions; only the second one affects the temperature.
- USB-attached (`lsblk -d -o NAME,TRAN` → `usb`). No hwmon entry, which is why its
  temperature reaches Prometheus through a textfile-collector feed rather than node-exporter's
  hwmon collector — see `ansible/roles/common/tasks/main.yml`.

Temperatures (`smartctl -l devstat`):
| reading | value |
|---|---|
| current | 56C |
| average short term | 59C |
| highest ever | 63C |
| lowest ever | 30C |
| highest average short term | 61C |
| lowest average short term | 47C |
| **specified maximum** | **65C** |
| time in over-temperature | 0 |

Health is otherwise clean: `PASSED`, 0 reallocated sectors, 0 current-pending, 0 offline
uncorrectable, 0 seek errors, 0 UDMA CRC errors.

**Wear is negligible, despite being bought used — the drive is effectively new:**
| counter | value |
|---|---|
| Power_On_Hours | 937 (normalized 099, worst 099) |
| Power_Cycle_Count | 29 |
| Start_Stop_Count | 29 |
| SMART error log | `No Errors Logged` |
| Self-test log | `No self-tests have been logged` |

worker-01 has ~41 days of uptime and 937 hours is ~39 days, so **essentially every power-on
hour on this drive was accumulated in this cluster.** Power_Cycle_Count and Start_Stop_Count
agree at 29, which is internally consistent with a drive that has only ever run here, and a
reseller refurbishing a drive would normally leave a self-test in the log — there is none.

So **a worn-out or abused used drive is ruled out.** Whatever is happening is a property of
this drive model in this enclosure, not of degradation. Do not spend time hunting for hidden
prior-owner damage.

## Already ruled out — do not re-derive

**Workload is NOT the cause.** The drive is effectively idle and still runs hot:
- `/proc/diskstats` shows **662 seconds of accumulated I/O time across 937 power-on hours**
  — about **0.02% busy**.
- A 10-second sample caught **0 sectors read** and 3072 sectors written (~1.5MB).
- Lifetime totals: 8360 reads / 3.38M sectors, 1.09M writes / 31.6M sectors (~16GB).

So do not go looking for a runaway scanner, an arr-stack rescan, a Jellyfin library crawl, or
a chatty NFS client. Four NFS clients are connected (all three nodes plus two loopback
mounts) and they are collectively doing nothing. **A drive this idle sitting 9C from its
ceiling points at cooling, not access patterns.**

## Hypotheses, most to least likely

1. **The fanless WD Elements shell cannot keep a 7200rpm helium drive cool.** No fan, minimal
   venting, drive mounted in plastic. If true, the fix is physical: re-house it in a
   ventilated bay or one with a fan, or add airflow across the existing shell.
   **No software change can fix this.**

   Practical note on provenance: because the unit was bought used, there is realistically no
   warranty left to protect on either the enclosure or the drive, so **opening the shell costs
   nothing** — normally the argument against shucking. That makes re-housing a live option
   rather than a last resort. If you do want to settle whether the drive is original, the two
   things that actually answer it are physical inspection of the shell's clips for prior
   pry marks, and WD's own warranty/serial lookup for `WD-B002KX5D`. Neither is answerable
   over SSH, and neither changes the temperature.
2. **Ambient / placement.** The cluster was physically relocated on 2026-07-30. Check what
   the enclosure is now sitting on, next to, or inside — a cabinet, a shelf against a wall,
   or stacked on/under one of the mini PCs. For reference, worker-01's internal sensors read
   56C (CPU package) and 56C (NVMe) at the time of writing, and that node's pod count went
   from 17 to 34 earlier the same day, so it is now genuinely warmer than it was.
3. **Orientation / no thermal contact.** A bare drive in a plastic shell with no pad or
   bracket has only air to conduct into.
4. **Never spins down.** `APM level is: 128 (minimum power consumption without standby)` —
   the platters turn continuously. Spin-down *would* cut heat, but it is the wrong trade for
   a disk backing live NFS PVCs: spin-up latency would stall every PVC-backed pod, and
   start/stop cycles are their own wear mechanism. Consider it only as a last resort, and
   never for the PVC path.

## Separate finding worth its own look — load cycles

`Load_Cycle_Count` is **55964 at 937 power-on hours** — roughly **60 head load/unload cycles
per hour**, about one a minute, on an essentially idle drive. The normalized value has
already fallen 200 → 182, so ~9% of the rated budget is gone in about five weeks of uptime.
Straight-line, that exhausts a 600k-cycle rating in roughly 14 months.

This is the classic aggressive head-parking timer (WD `idle3` / APM interaction). It is a
**wear** problem rather than a heat problem, so keep it separate from the thermal question —
but it is arguably the more urgent of the two, and `idle3ctl` may not reach the drive through
the USB bridge. Worth confirming whether it can be read/set at all in this enclosure.

## Constraints

- **`smartctl` exits non-zero on this drive on every call** — its exit status is a bitmask
  and the enclosure reports an invalid checksum in the SMART threshold structure while still
  returning good data. Any script needs `|| true`; under `set -euo pipefail` it will
  otherwise die after reading the value. This already bit once.
- `smartctl -d usbjmicron` and `-d usbsunplus` both fail; **auto-detect works** — pass no
  `-d` flag.
- Do not add a monitoring component. `node_smart_temperature_celsius` /
  `node_smart_temperature_limit_celsius` already exist, fed by
  `smart-temp-textfile.timer` every 2 minutes, with `DiskTemperatureAboveSpec` /
  `DiskTemperatureCritical` alerts in `system/monitoring-system/prometheusrule-temperature.yaml`
  and a Homepage widget. Use that history — query Prometheus for the trend rather than
  taking spot readings, and check whether the temperature tracks worker-01's CPU (shared
  ambient) or moves independently (enclosure-local).
- Repo rules apply: no `sleep`, changes go through git → ArgoCD, node-level changes go in
  Ansible so they survive a rebuild.

## Accept this may not be a software fix

The measured evidence — an idle enterprise 7200rpm drive in a passive enclosure, 9C from its
ceiling, with 0 time over-temperature and perfect health — most likely resolves to "this
drive needs better cooling." A legitimate outcome is a written recommendation about the
enclosure and its placement plus the load-cycle finding, with no code change at all. Do not
manufacture a config change to feel productive, and do not lower the alert thresholds to
make the warning go away.

The one genuinely useful software deliverable, if the trend data supports it: establish
whether the temperature correlates with node CPU load now that worker-01 carries 34 pods
instead of 17, since that is the one variable that changed on 2026-07-31 and it is
answerable from Prometheus history alone.
