#!/bin/sh
# Record raw battery, charger and TCPM observations without interpreting the
# voltage-derived qcom_qg capacity. Files are tab-separated to keep parsing
# reliable when a status or USB type contains spaces.
set -eu

INTERVAL_SECONDS=${INTERVAL_SECONDS:-5}
LOG_DIR=${LOG_DIR:-/var/log/phoenix-battery}
RETENTION_DAYS=${RETENTION_DAYS:-14}
MAX_SAMPLES=${MAX_SAMPLES:-0}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
TYPEC_ROOT=${TYPEC_ROOT:-/sys/class/typec}
PROC_ROOT=${PROC_ROOT:-/proc}
[ -r /etc/phoenix-battery-telemetry.conf ] && . /etc/phoenix-battery-telemetry.conf

case "$INTERVAL_SECONDS:$RETENTION_DAYS:$MAX_SAMPLES" in
    *[!0-9:]*|:*|*:) logger -p daemon.err -t phoenix-battery-telemetry "invalid numeric configuration"; exit 1 ;;
esac
[ "$INTERVAL_SECONDS" -gt 0 ] || exit 1

gauge="$POWER_SUPPLY_ROOT/qcom_qg"
charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
typec="$TYPEC_ROOT/port0"
boot_id=$(cat "$PROC_ROOT/sys/kernel/random/boot_id" 2>/dev/null || echo unknown)

mkdir -p "$LOG_DIR"

read_attr() {
    value=
    if [ -r "$1" ]; then
        value=$(cat "$1" 2>/dev/null || true)
    fi
    printf '%s' "$value" | tr '\t\r\n' '   '
}

write_header() {
    printf 'epoch_s\tiso8601\tuptime_s\tboot_id\tvoltage_level_pct\tbattery_voltage_uv\tbattery_voltage_avg_uv\tbattery_voltage_ocv_uv\tbattery_current_ua\tbattery_current_avg_ua\tbattery_temp_decic\tcharger_online\tcharger_status\tcharger_health\tcharger_usb_type\tusb_input_voltage_uv\tusb_input_current_ua\tusb_input_current_limit_ua\ttcpm_online\ttcpm_voltage_uv\ttcpm_current_max_ua\ttcpm_usb_type\ttypec_power_role\n'
}

SCHEMA_VERSION=2
last_day=
sample_count=0
while :; do
    day=$(date -u +%F)
    base_log="$LOG_DIR/telemetry-$day.tsv"
    # Find correct versioned log for today's schema
    expected_header=$(write_header)
    log="$base_log"
    if [ -s "$log" ]; then
        IFS= read -r existing_header < "$log" || existing_header=
        if [ "$existing_header" != "$expected_header" ]; then
            # Legacy schema present — migrate to -v2
            log="$LOG_DIR/telemetry-$day-v2.tsv"
            # If v2 already exists with wrong schema (future v3), bump again
            if [ -s "$log" ]; then
                IFS= read -r v2_header < "$log" || v2_header=
                if [ "$v2_header" != "$expected_header" ]; then
                    log="$LOG_DIR/telemetry-$day-v3.tsv"
                    # Ensure v3 header validated or created fresh
                    if [ -s "$log" ]; then
                        IFS= read -r v3_header < "$log" || v3_header=
                        [ "$v3_header" = "$expected_header" ] || : > "$log"
                    fi
                fi
            fi
        fi
    fi
    # If selected log exists but is empty/truncated, ensure header present
    if [ ! -s "$log" ]; then
        :
    else
        # Validate header matches before append
        IFS= read -r cur_header < "$log" || cur_header=
        if [ "$cur_header" != "$expected_header" ]; then
            # Schema drift — find next version
            log="$LOG_DIR/telemetry-$day-v3.tsv"
        fi
    fi

    if [ "$day" != "$last_day" ]; then
        [ -s "$log" ] || write_header > "$log"
        find "$LOG_DIR" -type f -name 'telemetry-*.tsv' \
            -mtime "+$RETENTION_DAYS" -exec rm -f '{}' ';' 2>/dev/null || true
        last_day=$day
    fi

    tcpm=
    # Prefer online TCPM source for deterministic telemetry
    for candidate in "$POWER_SUPPLY_ROOT"/tcpm-source-psy-*; do
        [ -d "$candidate" ] || continue
        if [ "$(cat "$candidate/online" 2>/dev/null)" = "1" ]; then
            tcpm=$candidate
            break
        fi
        # keep first as fallback if none online
        [ -z "$tcpm" ] && tcpm=$candidate
    done

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%s)" \
        "$(date -Iseconds)" \
        "$(cut -d' ' -f1 "$PROC_ROOT/uptime")" \
        "$boot_id" \
        "$(read_attr "$gauge/capacity")" \
        "$(read_attr "$gauge/voltage_now")" \
        "$(read_attr "$gauge/voltage_avg")" \
        "$(read_attr "$gauge/voltage_ocv")" \
        "$(read_attr "$gauge/current_now")" \
        "$(read_attr "$gauge/current_avg")" \
        "$(read_attr "$gauge/temp")" \
        "$(read_attr "$charger/online")" \
        "$(read_attr "$charger/status")" \
        "$(read_attr "$charger/health")" \
        "$(read_attr "$charger/usb_type")" \
        "$(read_attr "$charger/voltage_now")" \
        "$(read_attr "$charger/current_now")" \
        "$(read_attr "$charger/current_max")" \
        "$(read_attr "$tcpm/online")" \
        "$(read_attr "$tcpm/voltage_now")" \
        "$(read_attr "$tcpm/current_max")" \
        "$(read_attr "$tcpm/usb_type")" \
        "$(read_attr "$typec/power_role")" >> "$log"

    sample_count=$((sample_count + 1))
    [ "$MAX_SAMPLES" -gt 0 ] && [ "$sample_count" -ge "$MAX_SAMPLES" ] && exit 0
    sleep "$INTERVAL_SECONDS"
done
