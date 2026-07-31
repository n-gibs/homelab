# The 12TB HDD at 56–61C — findings

Investigated 2026-07-31 (handoff written the same morning, then executed). worker-01's
`/dev/sda` — the WD Elements 12TB backing `/mnt/storage`, every NFS PVC, and the media
library — runs 56–61C against a 65C vendor maximum.

**This turned out to be two unrelated problems.** Keep them separate.

| | problem | cause | status |
|---|---|---|---|
| 1 | 56–61C, ~4–9C of headroom | cooling: passive enclosure + a warmer room since the 07-30 move | **not software-fixable** — physical action needed |
| 2 | ~50 head load/unload cycles per hour on an idle drive | APM level 128 | **fix applied 2026-07-31, under measurement** |

Nothing is failing. Health is `PASSED`, 0 reallocated / pending / offline-uncorrectable,
0 seek errors, 0 UDMA CRC errors, 0 time over-temperature, no errors logged.

## Problem 1 — temperature

### It is not the workload, and it is not the node's CPU load

The drive is effectively idle: **662 seconds of accumulated I/O time across 937 power-on
hours, ~0.02% busy.** Lifetime totals are 3.38M sectors read, 31.6M written (~16GB). Four
NFS clients are connected and collectively doing nothing. So there is no runaway scanner,
arr-stack rescan, or Jellyfin crawl to find.

worker-01's pod count doubled from 17 to 34 on the morning of 07-31, which was the obvious
suspect. **It is not the cause.** Across that window worker-01's load went 0.35 → 0.84 and
its CPU package 49 → 52C, while the drive went **58 → 57C**. Drive temperature moves
independently of the node's own load.

### It is ambient, and the 07-30 relocation is visible in the data

The drive's own metric only starts 08:47 on 07-31 (the textfile feed shipped that morning),
so it cannot show its own step across the move. But all three nodes' CPU sensors have full
history, and across the relocation gap (07-30 19:32 → 22:47) — with loads unchanged —
every node got warmer:

| node | before | after | delta |
|---|---|---|---|
| worker-02 | 38–40C | 43–44C | **+5** |
| worker-00 | 50–52C | 52–55C | +3 |
| worker-01 | 47–49C | 49–51C | +2 |

Loads did not change across that gap, so this is the room, not the work. A passive
enclosure sits at ambient plus a roughly fixed delta, so a +3–5C ambient shift moves the
drive +3–5C — which is most of the distance between "warm" and "9C from spec".

**worker-02 taking the largest jump (+5C) is worth a look on its own** — it suggests the new
spot is more enclosed than the old one, which is a cluster-wide fact, not just an HDD one.

### What to actually do

In order of cost:

1. **Placement.** Check what the enclosure is sitting on, next to, under, or inside now.
   Free, and the data above says it is a real 3–5C lever.
2. **Airflow across the existing shell.** Any small fan pointed at it.
3. **Re-house the drive.** A 7200rpm helium enterprise drive in a fanless plastic shell is
   a design mismatch. The unit was bought used on eBay so there is no warranty to void on
   either part — **opening it costs nothing**, which makes shucking a live option rather
   than a last resort.

Note the pairing may well be factory: WD Elements units at this capacity commonly ship with
7200rpm helium white-label drives. "Is the drive original" and "does the enclosure cool it"
are separate questions and only the second affects temperature. If you want the first
answered anyway, it takes physical inspection of the shell clips for pry marks or WD's
warranty lookup on serial `WD-B002KX5D` — neither is answerable over SSH.

**Do not lower the alert thresholds to make the warning go away.**

## Problem 2 — head parking (APM)

`Load_Cycle_Count` was **55971 at 937 power-on hours** — ~60/hr lifetime average, confirmed
live at 48–60/hr across repeated sampling, on a drive that is 0.02% busy. Normalized value
has already fallen 200 → 182: **~9% of a 600k budget gone in five weeks**, which
straight-lines to exhaustion in roughly 14 months.

**The original handoff blamed `idle3`. That was wrong.** `WD120EDGZ-11CNVA0` is an Ultrastar
He12 white-label — HGST platform, which has no `idle3` timer. Head unload is governed by
**APM**, which was at 128 ("minimum power consumption without standby"). This matters
practically: `idle3ctl` sends raw vendor ATA commands that may not survive the USB bridge,
whereas APM is a standard ATA feature reachable through SAT with the `smartctl` already
installed. No extra tooling, and no vendor commands aimed at the drive backing every PVC.

Applied 2026-07-31 17:38:38Z:

```bash
sudo smartctl --set=apm,254 /dev/sda   # maximum performance, no idle unload
sudo smartctl --get=apm  /dev/sda      # reads back: 254 (maximum performance)
sudo smartctl --set=apm,128 /dev/sda   # revert
```

The drive reports `ATA Security is: Disabled, NOT FROZEN`, so settings are accepted.

**Two things still open on this:**

- **Does it hold?** Watch `rate(node_smart_load_cycle_count[1h])` — expect it to fall to ~0.
- **It does not persist across a power cycle.** APM resets to the drive default on power
  loss. If the measurement confirms the fix, persistence belongs in Ansible as a udev rule
  keyed on the drive serial — not in the existing `smart-temp-textfile` timer, which has a
  different job.

**The trade-off to keep in mind:** APM 254 raises idle power, which pushes the drive
*warmer* — the opposite direction from problem 1. If temperature climbs materially after
this change, the two fixes are in tension and placement has to come first to buy back the
headroom.

## Instrumentation

`node_smart_load_cycle_count` was added to the existing textfile exporter
(`ansible/roles/common/tasks/main.yml`, commit `768cdfd`) — attribute 193 rides along on the
SMART read already happening for temperature. No new exporter, no new timer. No alert on it
yet; a sane threshold depends on the rate this is now measuring.

Already present, do not duplicate: `node_smart_temperature_celsius` /
`node_smart_temperature_limit_celsius` from `smart-temp-textfile.timer` every 2 minutes,
`DiskTemperatureAboveSpec` / `DiskTemperatureCritical` in
`system/monitoring-system/prometheusrule-temperature.yaml`, and a Homepage widget.

## Constraints worth keeping

- **`smartctl` exits non-zero on this drive on every call.** Its exit status is a bitmask and
  the enclosure reports an invalid checksum in the SMART threshold structure while still
  returning good data. Any script needs `|| true`; under `set -euo pipefail` it otherwise
  dies *after* reading the value. This has bitten twice.
- `smartctl -d usbjmicron` and `-d usbsunplus` both fail. **Auto-detect works** — pass no
  `-d` flag.
- No hwmon entry for USB-attached disks (`drivetemp` binds SATA hosts, not usb-storage),
  which is why the textfile feed exists.
- `hdparm` and `idle3ctl` are not installed on the nodes, and neither is needed.
- `thermal_thermal_zone0` on worker-01 reads **-268C**. That is a garbage acpitz sensor, not
  a real reading — ignore it.
- Spinning the drive down would cut heat but is the wrong trade for a disk backing live NFS
  PVCs: spin-up latency stalls every PVC-backed pod, and start/stop cycles are their own
  wear mechanism. Not for the PVC path.
- Repo rules: no `sleep`, changes go through git → ArgoCD, node-level changes go in Ansible
  so they survive a rebuild.
