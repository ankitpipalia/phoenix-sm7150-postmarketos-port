#!/bin/sh
# Orderly shutdown guard for unattended Phoenix server deployments.
set -eu

INTERVAL_SECONDS=${INTERVAL_SECONDS:-5}
SHUTDOWN_VOLTAGE_UV=${SHUTDOWN_VOLTAGE_UV:-3450000}
SHUTDOWN_SAMPLES=${SHUTDOWN_SAMPLES:-12}
EMERGENCY_VOLTAGE_UV=${EMERGENCY_VOLTAGE_UV:-3350000}
EMERGENCY_SAMPLES=${EMERGENCY_SAMPLES:-3}
MAX_TEMP_DECIC=${MAX_TEMP_DECIC:-450}
MAX_TEMP_SAMPLES=${MAX_TEMP_SAMPLES:-6}
SHUTDOWN_COMMAND=${SHUTDOWN_COMMAND:-"systemctl poweroff"}
DRY_RUN=${DRY_RUN:-0}
MAX_SAMPLES=${MAX_SAMPLES:-0}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}

[ -r /etc/phoenix-battery-safety.conf ] && . /etc/phoenix-battery-safety.conf
[ -r /etc/default/phoenix-battery-safety ] && . /etc/default/phoenix-battery-safety

valid_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_int() {
	case "$1" in
		-*) valid_uint "${1#-}" ;;
		*) valid_uint "$1" ;;
	esac
}

for value in "$INTERVAL_SECONDS" "$SHUTDOWN_VOLTAGE_UV" \
	"$SHUTDOWN_SAMPLES" "$EMERGENCY_VOLTAGE_UV" "$EMERGENCY_SAMPLES" \
	"$MAX_TEMP_DECIC" "$MAX_TEMP_SAMPLES" "$DRY_RUN" "$MAX_SAMPLES"; do
	valid_uint "$value" || {
		logger -p daemon.err -t phoenix-battery-safety "invalid numeric configuration"
		exit 1
	}
done

if [ "$INTERVAL_SECONDS" -eq 0 ] || [ "$SHUTDOWN_SAMPLES" -eq 0 ] ||
   [ "$EMERGENCY_SAMPLES" -eq 0 ] || [ "$MAX_TEMP_SAMPLES" -eq 0 ] ||
   [ "$EMERGENCY_VOLTAGE_UV" -gt "$SHUTDOWN_VOLTAGE_UV" ]; then
	logger -p daemon.err -t phoenix-battery-safety "unsafe threshold configuration"
	exit 1
fi

gauge="$POWER_SUPPLY_ROOT/qcom_qg"
charger="$POWER_SUPPLY_ROOT/pm8150b-charger"

read_value() {
	if [ -r "$1" ]; then
		cat "$1" 2>/dev/null || true
	fi
}

external_power_online() {
	[ "$(read_value "$charger/online")" = "1" ] && return 0
	for candidate in "$POWER_SUPPLY_ROOT"/tcpm-source-psy-*; do
		[ -d "$candidate" ] || continue
		[ "$(read_value "$candidate/online")" = "1" ] && return 0
	done
	return 1
}

shutdown_now() {
	reason=$1
	logger -p daemon.crit -t phoenix-battery-safety "$reason"
	if [ "$DRY_RUN" = "1" ]; then
		printf '%s\n' "$reason"
		exit 0
	fi
	exec sh -c "$SHUTDOWN_COMMAND"
}

low_count=0
emergency_count=0
hot_count=0
sample_count=0

while :; do
	voltage_file="$gauge/voltage_avg"
	[ -r "$voltage_file" ] || voltage_file="$gauge/voltage_now"
	voltage_uv=$(read_value "$voltage_file")
	current_ua=$(read_value "$gauge/current_now")
	temp_decic=$(read_value "$gauge/temp")

	if valid_uint "$voltage_uv" && valid_int "$current_ua" && valid_uint "$temp_decic"; then
			if [ "$temp_decic" -ge "$MAX_TEMP_DECIC" ]; then
				hot_count=$((hot_count + 1))
			else
				hot_count=0
			fi
			if [ "$hot_count" -ge "$MAX_TEMP_SAMPLES" ]; then
				shutdown_now "battery temperature ${temp_decic} deci-C persisted for ${hot_count} samples; shutting down"
			fi

			if [ "$current_ua" -lt 0 ] && [ "$voltage_uv" -le "$EMERGENCY_VOLTAGE_UV" ]; then
				emergency_count=$((emergency_count + 1))
			else
				emergency_count=0
			fi
			if [ "$emergency_count" -ge "$EMERGENCY_SAMPLES" ]; then
				shutdown_now "battery voltage ${voltage_uv}uV is below emergency threshold while discharging; shutting down"
			fi

			if ! external_power_online && [ "$current_ua" -lt 0 ] &&
			   [ "$voltage_uv" -le "$SHUTDOWN_VOLTAGE_UV" ]; then
				low_count=$((low_count + 1))
			else
				low_count=0
			fi
			if [ "$low_count" -ge "$SHUTDOWN_SAMPLES" ]; then
				shutdown_now "battery voltage ${voltage_uv}uV remained below shutdown threshold without external power; shutting down"
			fi
	fi

	sample_count=$((sample_count + 1))
	[ "$MAX_SAMPLES" -gt 0 ] && [ "$sample_count" -ge "$MAX_SAMPLES" ] && exit 0
	sleep "$INTERVAL_SECONDS"
done
