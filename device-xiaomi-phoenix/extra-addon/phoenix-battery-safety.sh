#!/bin/sh
# Orderly shutdown guard for unattended Phoenix server deployments.
set -eu

# Save env for testing (allow env to override config)
for _v in INTERVAL_SECONDS SHUTDOWN_VOLTAGE_UV SHUTDOWN_SAMPLES EMERGENCY_VOLTAGE_UV EMERGENCY_SAMPLES MAX_TEMP_DECIC MAX_TEMP_SAMPLES SHUTDOWN_COMMAND DRY_RUN MAX_SAMPLES POWER_SUPPLY_ROOT; do
	eval "_env_$_v=\${$_v-__unset__}"
done
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
for _v in INTERVAL_SECONDS SHUTDOWN_VOLTAGE_UV SHUTDOWN_SAMPLES EMERGENCY_VOLTAGE_UV EMERGENCY_SAMPLES MAX_TEMP_DECIC MAX_TEMP_SAMPLES SHUTDOWN_COMMAND DRY_RUN MAX_SAMPLES POWER_SUPPLY_ROOT; do
	eval "_env_val=\${_env_$_v}"
	if [ "$_env_val" != "__unset__" ]; then eval "$_v=\${_env_val}"; fi
done

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
vnow_invalid_count=0
vavg_invalid_count=0
current_invalid_count=0
temp_invalid_count=0
sensor_fail_logged=0

while :; do
	voltage_now_uv=$(read_value "$gauge/voltage_now")
	voltage_avg_uv=$(read_value "$gauge/voltage_avg")
	current_ua=$(read_value "$gauge/current_now")
	temp_decic=$(read_value "$gauge/temp")

	# ---- Sensor validity + fault isolation counters (separate Vnow/Vavg) ----
	if valid_uint "$temp_decic"; then
		temp_invalid_count=0
	else
		temp_invalid_count=$((temp_invalid_count + 1))
	fi
	if valid_int "$current_ua"; then
		current_invalid_count=0
	else
		current_invalid_count=$((current_invalid_count + 1))
	fi
	if valid_uint "$voltage_now_uv"; then
		vnow_invalid_count=0
	else
		vnow_invalid_count=$((vnow_invalid_count + 1))
	fi
	if valid_uint "$voltage_avg_uv"; then
		vavg_invalid_count=0
	else
		vavg_invalid_count=$((vavg_invalid_count + 1))
	fi

	# Log prolonged sensor failure, and fail-safe to shutdown if voltage/current
	# stay invalid while external power is absent (cannot prove safe).
	# Use independent flags for each sensor to avoid shadowing
	if [ "$vnow_invalid_count" -ge 12 ] && [ "$vavg_invalid_count" -lt 12 ]; then
		if [ "$sensor_fail_logged" -eq 0 ]; then
			logger -p daemon.warning -t phoenix-battery-safety "instantaneous voltage unavailable for ${vnow_invalid_count} samples; emergency guard degraded, sustained guard remains active"
			sensor_fail_logged=1
		fi
	elif [ "$vnow_invalid_count" -ge 12 ] && [ "$vavg_invalid_count" -ge 12 ] && ! external_power_online; then
		# Both voltage channels lost and no external power: cannot prove cell safety
		if [ "$sensor_fail_logged" -eq 0 ]; then
			logger -p daemon.crit -t phoenix-battery-safety "both voltage sensors invalid for ${vavg_invalid_count} samples without external power; shutting down"
			sensor_fail_logged=1
		fi
		shutdown_now "both voltage sensors invalid for ${vavg_invalid_count} samples without external power; shutting down"
	elif [ "$vnow_invalid_count" -ge 12 ] || [ "$current_invalid_count" -ge 12 ] || [ "$vavg_invalid_count" -ge 12 ]; then
		if [ "$sensor_fail_logged" -eq 0 ]; then
			logger -p daemon.crit -t phoenix-battery-safety "sensor failure: vnow_invalid=${vnow_invalid_count} vavg_invalid=${vavg_invalid_count} current_invalid=${current_invalid_count} temp_invalid=${temp_invalid_count}"
			sensor_fail_logged=1
		fi
		if ! external_power_online && [ "$vavg_invalid_count" -ge 12 ] && [ "$current_invalid_count" -ge 12 ]; then
			shutdown_now "battery sensors invalid for ${vavg_invalid_count} samples without external power; shutting down conservatively"
		fi
	elif [ "$temp_invalid_count" -ge 12 ] && [ "$sensor_fail_logged" -eq 0 ]; then
		logger -p daemon.warning -t phoenix-battery-safety "temperature sensor invalid for ${temp_invalid_count} samples"
		sensor_fail_logged=1
	fi
	if [ "$vnow_invalid_count" -lt 12 ] && [ "$vavg_invalid_count" -lt 12 ] && [ "$current_invalid_count" -lt 12 ] && [ "$temp_invalid_count" -lt 12 ]; then
		sensor_fail_logged=0
	fi

	# ---- Independent protection channels ----

	# Thermal channel: uses temp only, isolated from voltage/current validity
	if valid_uint "$temp_decic"; then
			if [ "$temp_decic" -ge "$MAX_TEMP_DECIC" ]; then
				hot_count=$((hot_count + 1))
			else
				hot_count=0
			fi
			if [ "$hot_count" -ge "$MAX_TEMP_SAMPLES" ]; then
				shutdown_now "battery temperature ${temp_decic} deci-C persisted for ${hot_count} samples; shutting down"
			fi
	fi

	# Emergency channel: must use instantaneous voltage_now, not avg.
	# Correct predicate: critical_voltage AND (proof_of_discharge OR no_external_source)
	if valid_uint "$voltage_now_uv" && [ "$voltage_now_uv" -le "$EMERGENCY_VOLTAGE_UV" ]; then
		proof_discharge=0
		no_source=0
		if valid_int "$current_ua" && [ "$current_ua" -lt 0 ]; then proof_discharge=1; fi
		if ! external_power_online; then no_source=1; fi
		if [ "$proof_discharge" -eq 1 ] || [ "$no_source" -eq 1 ]; then
			emergency_count=$((emergency_count + 1))
		else
			emergency_count=0
		fi
		if [ "$emergency_count" -ge "$EMERGENCY_SAMPLES" ]; then
				shutdown_now "battery voltage_now ${voltage_now_uv}uV is below emergency threshold; shutting down"
			fi
	else
		emergency_count=0
	fi

	# Sustained low-voltage channel: uses voltage_avg (fallback to voltage_now if avg absent)
	# Correct predicate: Vavg <= threshold AND (current<0 OR no_external_source)
	sustained_voltage_uv="$voltage_avg_uv"
	if ! valid_uint "$sustained_voltage_uv"; then
		sustained_voltage_uv="$voltage_now_uv"
	fi
	if valid_uint "$sustained_voltage_uv" && [ "$sustained_voltage_uv" -le "$SHUTDOWN_VOLTAGE_UV" ]; then
		proof_discharge=0
		no_source=0
		if valid_int "$current_ua" && [ "$current_ua" -lt 0 ]; then proof_discharge=1; fi
		if ! external_power_online; then no_source=1; fi
		if [ "$proof_discharge" -eq 1 ] || [ "$no_source" -eq 1 ]; then
			low_count=$((low_count + 1))
		else
			low_count=0
		fi
		if [ "$low_count" -ge "$SHUTDOWN_SAMPLES" ]; then
				shutdown_now "battery voltage_avg ${sustained_voltage_uv}uV remained below shutdown threshold; shutting down"
			fi
	else
		low_count=0
	fi

	sample_count=$((sample_count + 1))
	[ "$MAX_SAMPLES" -gt 0 ] && [ "$sample_count" -ge "$MAX_SAMPLES" ] && exit 0
	sleep "$INTERVAL_SECONDS"
done
