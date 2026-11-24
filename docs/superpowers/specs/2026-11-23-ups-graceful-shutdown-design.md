# UPS monitoring and graceful shutdown

Issue #187. Short design: one approach picked, most of the work is configuration.

## Why

A CyberPower CP1500PFCLCD (1500VA / 900W) has protected the rack since 2026-09-10 and reports
nothing. Every device (the nodes, the NAS, the switch, OPNsense) hangs off one PDU on the UPS's
battery side. On a power cut nothing alerts and nothing shuts down, so the battery only delays a
hard power-off. The two outages this month came from unplugging the UPS itself, so it has never
seen a real cut.

Success: a cut sends an alert within a minute, and if power stays off, every node stops its pods
cleanly and powers off before the NAS, which powers off last. When power returns, everything boots
on its own.

## Scope and timing

The Talos migration (#174-184) starts with the new G9 the weekend of 2026-11-28. So:

- **Now: the NAS half.** NUT server, alerts, low-battery threshold, power-off of the UPS. None of
  it depends on what the nodes run.
- **With Talos: the node half**, in the Image Factory schematic and machine configs (#177), so
  each Talos node is protected from its first boot.
- **The k3s nodes get no NUT client.** It would be an Ansible role, a logind fix and a systemd
  drop-in, all deleted within weeks. While they remain, a long cut ends as it does today, a hard
  power-off, only about ten minutes earlier because the NAS cuts UPS power at low battery. The
  on-battery alert leaves time to run `docs/cluster-shutdown.md` by hand.

## Goals

- Alert on `onbatt` immediately, and again on low battery and lost communication.
- Shut down every Talos node cleanly before the battery runs out, NAS last.

## Non-goals

- Automating the full runbook quiesce (`docs/cluster-shutdown.md` steps 2-6). This was approach B,
  rejected: a lot of code that runs only during an outage and can scale the cluster to zero if it
  misfires. Add it later only if a real cut leaves Longhorn rebuilding.
- Graceful shutdown of the k3s nodes (see Scope).
- Prometheus metrics for the UPS (a nut-exporter). TrueNAS alerts cover the need.
- Ordered bring-up. Hard NFS mounts retry until the NAS is back; the runbook covers a manual
  bring-up if that proves wrong.

## Anti-goals

- A test that powers off the cluster unannounced. The full-chain test happens in a planned window.
- A shutdown that fires on a short blip. Only low battery triggers it.

## Approaches

- **A. Plain NUT plus kubelet graceful node shutdown (picked).** The NAS runs the NUT server; nodes
  run `upsmon` as network secondaries; kubelet holds shutdown until pods stop.
- **B. A plus an automated quiesce Job on battery.** Rejected, see non-goals.
- **C. NAS drives node shutdown over SSH or `talosctl`.** Rejected: custom scripts on the TrueNAS
  appliance, and only needed while Talos seemed to lack a NUT client. It doesn't: the official
  `siderolabs/extensions` `power/nut-client` extension takes an `upsmon.conf` through an
  `ExtensionServiceConfig`, with `SHUTDOWNCMD "/sbin/poweroff"`. #187's premise is out of date.

## Design: NAS (now)

### NUT primary (TrueNAS UI)

USB data cable from the UPS to the NAS (`192.168.30.144`). Services > UPS:

| Setting | Value | Why |
|---|---|---|
| UPS Mode | Master | the UPS is cabled here |
| Driver | `usbhid-ups` | NUT's hardware list has the CP1500PFCLCD under it |
| Remote Monitor | on | Talos nodes connect over the network |
| Monitor Password | a real one | Remote Monitor otherwise uses the documented `upsmon` / `fixmepass` |
| Shutdown Mode | UPS reaches low battery | no shutdown on a blip |
| Power off UPS | on | outlets cycle, so everything boots when mains returns |
| Host Sync | 360 | NAS waits this long for the nodes, see Timing |
| Auxiliary Parameters (ups.conf) | `ignorelb` and `override.battery.runtime.low = 600` | fire LB with 10 min left |

The CP1500PFCLCD's own low-battery flag fires at `battery.runtime.low: 300` (NUT issue #520 shows
its defaults), too short for a 270s drain plus the NAS's own shutdown. An `override` line alone
only changes the reported number; `ignorelb` makes the driver ignore the UPS's flag and raise LB
itself from `battery.runtime < battery.runtime.low`. The same #520 dump shows about 25 minutes of
runtime at 25% load, on someone else's unit; ours gets measured.

As primary, `upsmon` on the NAS sets FSD, then waits up to Host Sync for every secondary to log
out of `upsd` before shutting itself down and cutting UPS power.

Every node BIOS (and the NAS) must be set to power on after AC loss, or "Power off UPS" leaves
them dark when mains returns. The new G9 gets this set during its Talos install.

### Alerts

TrueNAS ships `UPSOnBatteryAlert` (critical), `UPSBatteryLowAlert`, `UPSCommbadAlert` (critical),
`UPSReplbattAlert` and the INFO-level `UPSOnlineAlert`. They go out through the existing TrueNAS →
ntfy service. Check that service's level threshold: at WARNING or above, "back on line power"
never arrives.

## Design: Talos nodes (with #177)

### NUT secondary

Add `siderolabs/nut-client` to the Image Factory schematic. Configure it with an
`ExtensionServiceConfig`:

```
MONITOR <ups>@192.168.30.144 1 <user> <pass> secondary
SHUTDOWNCMD "/sbin/poweroff"
SHUTDOWNEXIT no
```

**`SHUTDOWNEXIT no` is what keeps the NAS last.** By default a secondary's `upsmon` exits right
after calling `SHUTDOWNCMD`, which logs it out of `upsd` and lets the NAS cut UPS power while
kubelet is still stopping pods. With `no`, it stays logged in until its service is stopped. That
only helps if Talos stops the extension service after the kubelet has drained. The extension's
service `depends` on `cri`, so it may stop earlier; verify this (Talos audit, verify item 6).

The password is a secret in the machine config, handled however #177 handles the rest of them.

### Kubelet graceful node shutdown

A patch on the generated `KubeletConfig` document (Talos v1.14.7; the v1alpha1
`machine.kubelet` beside it fails validation), setting `shutdownGracePeriodByPodPriority` (beta,
on by default) under `config:` so pods stop in priority order. The same patch must set
`shutdownGracePeriod: 0s` and `shutdownGracePeriodCriticalPods: 0s`: Talos defaults them to 30s
and 10s unless the keys are present (`kubelet_spec.go`), and kubelet refuses to start with either
non-zero beside a by-priority list.

| Priority from | Who | Grace |
|---|---|---|
| 0 | apps, CNPG | 180s |
| 1000000000 | Longhorn (`longhorn-critical`) | 60s |
| 2000000000 | Cilium, CoreDNS (system-*-critical) | 30s |

The default two-phase mode would stop Longhorn alongside the apps, because `longhorn-critical`
(1e9) sits below the critical threshold (2e9). This table makes apps release their volumes before
Longhorn's instance managers stop. CNPG skips smart shutdown by default (`smartShutdownTimeout: 0`)
and goes straight to a fast shutdown; no cluster in the repo overrides it, so 180s is ample.

Verify on Talos whether `/sbin/poweroff` runs kubelet's graceful shutdown at all, or Talos's own
cordon-and-drain instead. If the latter, the table may not apply and the timing changes.

### Timing

Kubelet's three phases total 270s, then the node stops and `upsmon` logs out. Host Sync 360 covers
that with margin; a stuck node can't hold the NAS past it. The NAS then flushes the pool and powers
off. All of it has to fit inside the 600s low-battery margin.

## Verify before relying on it

NAS half:
- `upsc` on the NAS reports `battery.runtime` and `ups.load` under today's load. If runtime on a
  full battery is under ~20 minutes, 600s of margin leaves too little ride-through; revisit.
- `upsc` shows `LB` raised by the driver at the overridden runtime, not at the UPS's 300s.
- Each alert reaches ntfy: pull the UPS's mains plug for a minute and plug it back in.

Talos half:
- `talosctl service ext-nut-client` is Running and `upsc` on the NAS lists the node as a client.
- Single-node test: `talosctl shutdown` on one node, watch pods leave in priority order and the
  node stay logged in to `upsd` until the end.
- Full test in a planned window, dead-man's switch paused: `upsmon -c fsd` on the NAS.

## Left to the builder

- How #177 stores the NUT password in the machine config.
- If Talos uses its own drain instead of kubelet graceful shutdown, size Host Sync from a measured
  single-node shutdown instead of the 270s table.
