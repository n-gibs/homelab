#!/bin/sh
# FreeBSD's node_exporter has no link-speed or coretemp collector, and a NIC that
# renegotiates down to 100 Mbit stays "up" in every metric it does have.
set -eu

DIR=/var/tmp/node_exporter
OUT="$DIR/opnsense.prom"
TMP="$OUT.$$"

# "(1000baseT <full-duplex>)" -> 1000, "(10Gbase-T ...)" -> 10000, no carrier -> 0
link_speed_mbps() {
	printf '%s\n' "$1" | sed -nE 's/.*media: .*\(([0-9]+)(G?)[bB]ase.*/\1 \2/p' |
		awk '{ print ($2 == "G") ? $1 * 1000 : $1 }'
}

link_metrics() {
	up_lines=""
	speed_lines=""
	for ifc in $(ifconfig -l ether); do
		info=$(ifconfig "$ifc")
		desc=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*description: //p' | tr -d '"')
		labels="interface=\"$ifc\",description=\"$desc\""
		up=0
		printf '%s\n' "$info" | grep -q 'status: active' && up=1
		speed=$(link_speed_mbps "$info")
		[ "$up" -eq 1 ] || speed=0
		up_lines="${up_lines}opnsense_interface_link_up{$labels} $up
"
		speed_lines="${speed_lines}opnsense_interface_link_speed_mbps{$labels} ${speed:-0}
"
	done
	echo "# HELP opnsense_interface_link_up 1 if the NIC has carrier."
	echo "# TYPE opnsense_interface_link_up gauge"
	printf '%s' "$up_lines"
	echo "# HELP opnsense_interface_link_speed_mbps Negotiated link speed in Mbit/s, 0 without carrier."
	echo "# TYPE opnsense_interface_link_speed_mbps gauge"
	printf '%s' "$speed_lines"
}

temperature_metrics() {
	ncpu=$(sysctl -n hw.ncpu)
	echo "# HELP opnsense_cpu_temperature_celsius Per-core temperature from coretemp."
	echo "# TYPE opnsense_cpu_temperature_celsius gauge"
	i=0
	while [ "$i" -lt "$ncpu" ]; do
		t=$(sysctl -n "dev.cpu.$i.temperature" 2>/dev/null | tr -d C) || t=""
		[ -n "$t" ] && echo "opnsense_cpu_temperature_celsius{cpu=\"$i\"} $t"
		i=$((i + 1))
	done
	echo "# HELP opnsense_cpu_tjmax_celsius Junction temperature at which the CPU throttles."
	echo "# TYPE opnsense_cpu_tjmax_celsius gauge"
	tj=$(sysctl -n dev.cpu.0.coretemp.tjmax 2>/dev/null | tr -d C) || tj=""
	[ -n "$tj" ] && echo "opnsense_cpu_tjmax_celsius $tj"
	return 0
}

# dpinger answers each socket with "<gateway> <rtt_us> <stddev_us> <loss_pct>" for gateways
# that have monitoring enabled (System → Gateways → monitor IP).
gateway_metrics() {
	lines=""
	for sock in /var/run/dpinger_*.sock; do
		[ -S "$sock" ] || continue
		lines="${lines}$(nc -U "$sock" </dev/null)
"
	done
	printf '%s' "$lines" | awk '
		NF == 4 {
			rtt = rtt sprintf("opnsense_gateway_rtt_seconds{gateway=\"%s\"} %.6f\n", $1, $2 / 1e6)
			sd = sd sprintf("opnsense_gateway_rtt_stddev_seconds{gateway=\"%s\"} %.6f\n", $1, $3 / 1e6)
			loss = loss sprintf("opnsense_gateway_loss_ratio{gateway=\"%s\"} %.4f\n", $1, $4 / 100)
		}
		END {
			print "# HELP opnsense_gateway_rtt_seconds dpinger average round trip to the monitor IP."
			print "# TYPE opnsense_gateway_rtt_seconds gauge"
			printf "%s", rtt
			print "# HELP opnsense_gateway_rtt_stddev_seconds dpinger round-trip standard deviation."
			print "# TYPE opnsense_gateway_rtt_stddev_seconds gauge"
			printf "%s", sd
			print "# HELP opnsense_gateway_loss_ratio dpinger packet loss to the monitor IP, 0-1."
			print "# TYPE opnsense_gateway_loss_ratio gauge"
			printf "%s", loss
		}'
}

mkdir -p "$DIR"
trap 'rm -f "$TMP"' EXIT
{
	link_metrics
	temperature_metrics
	gateway_metrics
} >"$TMP"
# node_exporter reads the directory on every scrape; rename so it never sees a half-written file.
mv "$TMP" "$OUT"
