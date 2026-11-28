# opnsense

The firewall is not managed from this repo. This directory holds the one file it runs for the
cluster's benefit, and the steps that put it there, so a rebuilt or replaced box can be brought
back into monitoring.

Prometheus scrapes it through `system/monitoring-system/scrapeconfig-opnsense.yaml`, and the
alerts are in `prometheusrule-opnsense.yaml` next to it.

## Why a script

The `os-node_exporter` plugin covers CPU, memory, ZFS, filesystems and per-NIC error counters.
FreeBSD's node_exporter has no link-speed or CPU temperature collector, though, and a port that
renegotiates from 1000 to 100 Mbit stays up in every metric it does have. `textfile-metrics.sh`
fills that gap: it writes `opnsense_interface_link_{up,speed_mbps}` keyed by `device` like
node_exporter's own NIC series, `opnsense_interface_info` to join a description onto any of them, and
`opnsense_cpu_{temperature,tjmax}_celsius` to the textfile collector's directory every minute.
It also reads dpinger's sockets for `opnsense_gateway_{rtt_seconds,rtt_stddev_seconds,loss_ratio}`,
which exist only while the WAN gateway has a monitor IP set (System → Gateways, currently
`1.1.1.1`). Finally it turns the daily firmware check's `/tmp/pkg_upgrade.json` into
`opnsense_firmware_*`, caching the last result because the check deletes that file while it runs.

## Setup

1. **System → Firmware → Plugins:** install `os-node_exporter`.
2. **Services → Prometheus Exporter:** enable it. Set the listen address to the OPT2 address,
   `192.168.30.1`, port `9100`, and enable the cpu, filesystem, loadavg, meminfo, netdev, time
   and zfs collectors. The existing OPT2 rule (`OPT2 net → any`) already lets the nodes in, and
   Cilium masquerades pod traffic to node IPs, so no new firewall rule is needed.
3. **System → Settings → Miscellaneous → Thermal Sensors:** select the Intel Core on-die sensor so
   `coretemp` loads. Without it the temperature series are empty and that alert can never fire.
4. Copy the script and register it as a configd action:

   ```sh
   scp opnsense/textfile-metrics.sh root@192.168.10.1:/usr/local/bin/homelab-textfile-metrics.sh
   ssh root@192.168.10.1 chmod 755 /usr/local/bin/homelab-textfile-metrics.sh
   ```

   Then create `/usr/local/opnsense/service/conf/actions.d/actions_homelab.conf` on the box:

   ```ini
   [textfile]
   command:/usr/local/bin/homelab-textfile-metrics.sh
   parameters:
   type:script
   message:writing node_exporter textfile metrics
   description:Write node_exporter textfile metrics (homelab)

   [firmware_check]
   command:/usr/sbin/daemon -f /usr/local/opnsense/scripts/firmware/launcher.sh check
   parameters:
   type:script
   message:checking for firmware updates
   description:Check for OPNsense firmware updates (homelab)
   ```

   and run `service configd restart`.
5. **System → Settings → Cron:** add a job running every minute (`*` in all five fields) with the
   command *Write node_exporter textfile metrics (homelab)*. Add a second job at `17 4 * * *` with
   *Check for OPNsense firmware updates (homelab)*; OPNsense otherwise only checks when someone
   opens the firmware page.

Check it with `curl -s http://192.168.30.1:9100/metrics | grep ^opnsense_` from a node.
`OPNsenseTextfileMetricsStale` fires if the cron job stops.
