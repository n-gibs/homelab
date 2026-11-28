#!/bin/sh
# FreeBSD's node_exporter has no link-speed or coretemp collector, and a NIC that
# renegotiates down to 100 Mbit stays "up" in every metric it does have.
set -eu

DIR=/var/tmp/node_exporter
OUT="$DIR/opnsense.prom"
TMP="$OUT.$$"

# Autoselect prints the active speed in parentheses, a forced port prints it bare:
# "autoselect (1000baseT <full-duplex>)" / "1000baseT <full-duplex>" -> 1000, "10Gbase-T" -> 10000.
link_speed_mbps() {
	printf '%s\n' "$1" | sed -nE 's/.*media: [^<]*[ (]([0-9]+)(G?)[bB]ase.*/\1 \2/p' |
		awk '{ print ($2 == "G") ? $1 * 1000 : $1 }'
}

# Only NICs backed by a device (dev.igb.1, ...): VLANs, taps and bridges have no
# negotiated speed of their own and would read as a degraded link.
is_physical_nic() {
	drv=${1%%[0-9]*}
	sysctl -n "dev.$drv.${1#"$drv"}.%driver" >/dev/null 2>&1
}

link_metrics() {
	up_lines=""
	speed_lines=""
	for ifc in $(ifconfig -l ether); do
		is_physical_nic "$ifc" || continue
		info=$(ifconfig "$ifc") || continue
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
		# A socket left behind by a dead dpinger must not take the link metrics down with it.
		reply=$(nc -w 2 -U "$sock" </dev/null 2>/dev/null) || continue
		lines="${lines}${reply}
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

FIRMWARE_JSON=/tmp/pkg_upgrade.json
FIRMWARE_CACHE="$DIR/firmware.cache"

firmware_from_json() {
	checked=$(stat -f %m "$FIRMWARE_JSON")
	jq -r --arg checked "$checked" '
		([.upgrade_packages[]? | select(.name == "opnsense") | .new_version][0] // .product_version) as $latest
		| "# HELP opnsense_firmware_updates_available Packages with a pending upgrade at the last firmware check.",
		  "# TYPE opnsense_firmware_updates_available gauge",
		  "opnsense_firmware_updates_available{current=\"\(.product_version)\",latest=\"\($latest)\"} \(.upgrade_packages // [] | length)",
		  "# HELP opnsense_firmware_update_needs_reboot 1 if installing the pending updates needs a reboot.",
		  "# TYPE opnsense_firmware_update_needs_reboot gauge",
		  "opnsense_firmware_update_needs_reboot \(.needs_reboot // "0")",
		  "# HELP opnsense_firmware_check_ok 1 if the last check reached the package mirror.",
		  "# TYPE opnsense_firmware_check_ok gauge",
		  "opnsense_firmware_check_ok \(if .connection == "ok" and .repository == "ok" then 1 else 0 end)",
		  "# HELP opnsense_firmware_last_check_timestamp_seconds When the firmware check last wrote its result.",
		  "# TYPE opnsense_firmware_last_check_timestamp_seconds gauge",
		  "opnsense_firmware_last_check_timestamp_seconds \($checked)"
	' "$FIRMWARE_JSON"
}

# check.sh deletes and rewrites its JSON while a check runs; serve the last good result
# meanwhile so the update alert doesn't resolve and re-fire every day.
firmware_metrics() {
	if [ -s "$FIRMWARE_JSON" ] && fw=$(firmware_from_json 2>/dev/null); then
		printf '%s\n' "$fw" >"$FIRMWARE_CACHE"
	fi
	[ -r "$FIRMWARE_CACHE" ] && cat "$FIRMWARE_CACHE"
	return 0
}

mkdir -p "$DIR"
trap 'rm -f "$TMP"' EXIT
{
	link_metrics
	temperature_metrics
	gateway_metrics
	firmware_metrics
} >"$TMP"
# node_exporter reads the directory on every scrape; rename so it never sees a half-written file.
mv "$TMP" "$OUT"
