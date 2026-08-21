#!/bin/sh
# Integrate qcom_qg current and terminal voltage from a telemetry TSV.
# Positive qcom_qg current means charging on this driver; negative means
# discharging. Gaps over MAX_GAP_SECONDS are excluded instead of fabricating
# charge while the logger was stopped or the system was suspended.
set -eu

LOG_DIR=/var/log/phoenix-battery
MAX_GAP_SECONDS=30
[ -r /etc/phoenix-battery-telemetry.conf ] && . /etc/phoenix-battery-telemetry.conf

file=${1:-}
if [ -z "$file" ]; then
    file=$(ls -1 "$LOG_DIR"/telemetry-*.tsv 2>/dev/null | tail -n 1 || true)
fi
[ -n "$file" ] && [ -r "$file" ] || {
    echo "usage: $0 [telemetry.tsv]" >&2
    exit 1
}

awk -F '\t' -v maxgap="$MAX_GAP_SECONDS" '
BEGIN { OFS="\t" }
NR == 1 { next }
$1 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $8 ~ /^-?[0-9]+$/ {
    epoch=$1+0; voltage=$5+0; current=$8+0
    if (!started) {
        started=1; start_epoch=epoch; min_v=max_v=voltage; min_i=max_i=current
    }
    samples++
    if (voltage < min_v) min_v=voltage
    if (voltage > max_v) max_v=voltage
    if (current < min_i) min_i=current
    if (current > max_i) max_i=current

    if (have_prev) {
        dt=epoch-prev_epoch
        if (dt > 0 && dt <= maxgap) {
            avg_i=(prev_current+current)/2
            avg_v=(prev_voltage+voltage)/2
            q_mah=avg_i*dt/3600000
            e_mwh=avg_v*avg_i*dt/3600000000000
            net_mah+=q_mah; net_mwh+=e_mwh; integrated_s+=dt
            if (q_mah >= 0) { charge_in_mah+=q_mah; energy_in_mwh+=e_mwh }
            else { discharge_out_mah-=q_mah; energy_out_mwh-=e_mwh }
        } else if (dt > maxgap) {
            skipped_gaps++
        }
    }
    prev_epoch=epoch; prev_voltage=voltage; prev_current=current; have_prev=1
    end_epoch=epoch
}
END {
    if (!samples) { print "no usable samples" > "/dev/stderr"; exit 1 }
    printf "file: %s\n", FILENAME
    printf "samples: %d\n", samples
    printf "elapsed: %.2f h\n", (end_epoch-start_epoch)/3600
    printf "integrated: %.2f h\n", integrated_s/3600
    printf "skipped gaps: %d\n", skipped_gaps
    printf "charge in: %.3f mAh / %.3f mWh\n", charge_in_mah, energy_in_mwh
    printf "discharge out: %.3f mAh / %.3f mWh\n", discharge_out_mah, energy_out_mwh
    printf "net: %.3f mAh / %.3f mWh\n", net_mah, net_mwh
    printf "voltage range: %.0f..%.0f uV\n", min_v, max_v
    printf "current range: %.0f..%.0f uA\n", min_i, max_i
}' "$file"
