#!/bin/sh
# Integrate QGauge battery current and terminal voltage using monotonic time.
# New logs are segmented by boot_id; legacy logs are segmented on uptime reset.
set -eu

LOG_DIR=${LOG_DIR:-/var/log/phoenix-battery}
MAX_GAP_SECONDS=${MAX_GAP_SECONDS:-30}
_orig_LOG_DIR=$LOG_DIR
_orig_MAX_GAP=$MAX_GAP_SECONDS
[ -r /etc/phoenix-battery-telemetry.conf ] && . /etc/phoenix-battery-telemetry.conf
# Env takes precedence for testing (preserve original if set via env)
if [ "$_orig_LOG_DIR" != "/var/log/phoenix-battery" ]; then
	LOG_DIR=$_orig_LOG_DIR
fi
if [ "$_orig_MAX_GAP" != "30" ]; then
	MAX_GAP_SECONDS=$_orig_MAX_GAP
fi

file=${1:-}
if [ -z "$file" ]; then
	# Prefer newest mtime; on ties prefer -v2 schema (lexicographically later but time-based)
	# Use -t to avoid picking legacy file when both exist for same day.
	file=$(ls -1t "$LOG_DIR"/telemetry-*.tsv 2>/dev/null | head -n 1 || true)
fi
[ -n "$file" ] && [ -r "$file" ] || {
	echo "usage: $0 [telemetry.tsv]" >&2
	exit 1
}

awk -F '\t' -v maxgap="$MAX_GAP_SECONDS" '
BEGIN { OFS="\t" }
NR == 1 {
	for (i = 1; i <= NF; i++) col[$i] = i
	uptime_col = col["uptime_s"]
	boot_col = col["boot_id"]
	voltage_col = col["battery_voltage_uv"]
	current_col = col["battery_current_ua"]
	if (!uptime_col || !voltage_col || !current_col) {
		print "missing required telemetry columns" > "/dev/stderr"
		exit 2
	}
	next
}
{
	uptime_value = $uptime_col
	voltage_value = $voltage_col
	current_value = $current_col
	boot = boot_col ? $boot_col : ""

	if (uptime_value !~ /^[0-9]+([.][0-9]+)?$/ ||
	    voltage_value !~ /^[0-9]+$/ ||
	    current_value !~ /^-?[0-9]+$/)
		next

	uptime_s = uptime_value + 0
	voltage = voltage_value + 0
	current = current_value + 0
	if (!started) {
		started = 1
		min_v = max_v = voltage
		min_i = max_i = current
	}
	samples++
	if (voltage < min_v) min_v = voltage
	if (voltage > max_v) max_v = voltage
	if (current < min_i) min_i = current
	if (current > max_i) max_i = current

	if (have_prev) {
		boot_changed = boot_col && boot != prev_boot
		dt = uptime_s - prev_uptime
		if (boot_changed || dt <= 0) {
			segments++
		} else if (dt <= maxgap) {
			avg_i = (prev_current + current) / 2
			q_mah = avg_i * dt / 3600000
			# Energy: integrate power, not avg(V)*avg(I)
			p0 = prev_voltage * prev_current
			p1 = voltage * current
			avg_p = (p0 + p1) / 2
			e_mwh = avg_p * dt / 3600000000000
			net_mah += q_mah
			net_mwh += e_mwh
			integrated_s += dt
			if (q_mah >= 0) {
				charge_in_mah += q_mah
				energy_in_mwh += e_mwh
			} else {
				discharge_out_mah -= q_mah
				energy_out_mwh -= e_mwh
			}
		} else {
			skipped_gaps++
		}
	}

	prev_uptime = uptime_s
	prev_voltage = voltage
	prev_current = current
	prev_boot = boot
	have_prev = 1
}
END {
	if (!samples) {
		print "no usable samples" > "/dev/stderr"
		exit 1
	}
	printf "file: %s\n", FILENAME
	printf "samples: %d\n", samples
	printf "integrated: %.2f h\n", integrated_s / 3600
	printf "boot/uptime boundaries: %d\n", segments
	printf "skipped gaps: %d\n", skipped_gaps
	printf "charge in: %.3f mAh / %.3f mWh\n", charge_in_mah, energy_in_mwh
	printf "discharge out: %.3f mAh / %.3f mWh\n", discharge_out_mah, energy_out_mwh
	printf "net: %.3f mAh / %.3f mWh\n", net_mah, net_mwh
	printf "voltage range: %.0f..%.0f uV\n", min_v, max_v
	printf "current range: %.0f..%.0f uA\n", min_i, max_i
}' "$file"
