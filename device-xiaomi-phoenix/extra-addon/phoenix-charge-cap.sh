#!/bin/sh
# Voltage-based charge limiter for Phoenix server deployments.
#
# This requires qcom_smbx charge_behaviour support. Unlike the legacy STATUS
# setter, inhibit-charge disables battery charging without suspending USBIN, so
# the adapter continues to power the system.
set -eu

_tunables="START_VOLTAGE_UV STOP_VOLTAGE_UV POWER_SUPPLY_ROOT RUN_DIR
	DEFICIT_CURRENT_UA DEFICIT_SAMPLES DEFICIT_LOCKOUT_SECONDS PROC_ROOT"
for _v in $_tunables; do
	eval "_env_$_v=\${$_v-__unset__}"
done
START_VOLTAGE_UV=${START_VOLTAGE_UV:-4000000}
STOP_VOLTAGE_UV=${STOP_VOLTAGE_UV:-4100000}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
RUN_DIR=${RUN_DIR:-/run}
# Adapter-deficit guard: holding an inhibit while the battery is actually
# discharging cannot save a cycle -- the cell is being cycled either way -- and
# it hides an input path that can no longer carry the system load.  Release the
# inhibit instead, so any surplus tops the battery back up, and make the
# condition loud.
DEFICIT_CURRENT_UA=${DEFICIT_CURRENT_UA:-20000}
DEFICIT_SAMPLES=${DEFICIT_SAMPLES:-5}
DEFICIT_LOCKOUT_SECONDS=${DEFICIT_LOCKOUT_SECONDS:-1800}
PROC_ROOT=${PROC_ROOT:-/proc}

[ -r /etc/phoenix-charge-cap.conf ] && . /etc/phoenix-charge-cap.conf
[ -r /etc/default/phoenix-charge-cap ] && . /etc/default/phoenix-charge-cap
for _v in $_tunables; do
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

# QGauge's averaged channels read garbage for roughly the first 70 s after boot
# (observed: voltage_avg pinned at 6377865, current_avg at 5000003) while the
# instantaneous channels are correct.  Anything acting on a reading must first
# check it is physically possible for this cell.
PLAUSIBLE_MIN_UV=3000000
PLAUSIBLE_MAX_UV=4600000
PLAUSIBLE_MAX_UA=3000000

plausible_voltage() {
	valid_uint "$1" && [ "$1" -ge "$PLAUSIBLE_MIN_UV" ] && [ "$1" -le "$PLAUSIBLE_MAX_UV" ]
}

plausible_current() {
	valid_int "$1" || return 1
	_a=$1; [ "$_a" -lt 0 ] && _a=$((0 - _a))
	[ "$_a" -le "$PLAUSIBLE_MAX_UA" ]
}

# Monotonic clock: /run is tmpfs and uptime resets together with it, so a
# stored uptime can never be compared across a reboot.
uptime_seconds() {
	_u=$(cut -d' ' -f1 "$PROC_ROOT/uptime" 2>/dev/null || true)
	case "$_u" in
		''|*[!0-9.]*) return 1 ;;
		*) printf '%s\n' "${_u%%.*}" ;;
	esac
}

# Prefer the averaged channel; instantaneous current swings by >100 mA between
# samples and would trip or clear the guard on noise alone.
battery_current_ua() {
	for _f in current_avg current_now; do
		_c=$(cat "$gauge/$_f" 2>/dev/null || true)
		if plausible_current "$_c"; then printf '%s\n' "$_c"; return 0; fi
	done
	return 1
}

# Same policy for voltage: averaged first, instantaneous as fallback, and an
# implausible value is treated exactly like a missing one.
battery_voltage_uv() {
	for _f in voltage_avg voltage_now; do
		_v=$(cat "$gauge/$_f" 2>/dev/null || true)
		if plausible_voltage "$_v"; then printf '%s\n' "$_v"; return 0; fi
	done
	return 1
}

behaviour_is() {
	case "$current_behaviour" in
		"$1"|*"[$1]"*) return 0 ;;
		*) return 1 ;;
	esac
}

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
gauge="$POWER_SUPPLY_ROOT/qcom_qg"
behaviour="$charger/charge_behaviour"
state="$RUN_DIR/phoenix-charge-cap.inhibited"
deficit="$RUN_DIR/phoenix-charge-cap.deficit"
lockout="$RUN_DIR/phoenix-charge-cap.lockout"
# Float-voltage control (kernel patch 0018).  Preferred over inhibit-charge:
# the charger keeps regulating, so the adapter carries the system and the cell
# simply rests at the programmed ceiling instead of cycling against it.
float_attr="$charger/constant_charge_voltage"
float_state="$RUN_DIR/phoenix-charge-cap.float-original"

# Read-only assessment of whether adapter-first operation is actually being
# achieved.  Deliberately available even when charge_behaviour is missing.
if [ "${1:-}" = "status" ]; then
	_online=$(cat "$charger/online" 2>/dev/null || echo 0)
	_vin=$(cat "$charger/voltage_now" 2>/dev/null || true)
	_iin=$(cat "$charger/current_now" 2>/dev/null || true)
	_icl=$(cat "$charger/current_max" 2>/dev/null || true)
	_vbat=$(battery_voltage_uv || true)
	_ibat=$(battery_current_ua || true)
	_raw_vavg=$(cat "$gauge/voltage_avg" 2>/dev/null || true)
	_raw_iavg=$(cat "$gauge/current_avg" 2>/dev/null || true)
	if valid_uint "$_raw_vavg" && ! plausible_voltage "$_raw_vavg"; then
		printf 'warning:           voltage_avg reads %s uV (implausible, ignored)\n' "$_raw_vavg"
	fi
	if valid_int "$_raw_iavg" && ! plausible_current "$_raw_iavg"; then
		printf 'warning:           current_avg reads %s uA (implausible, ignored)\n' "$_raw_iavg"
	fi
	printf 'control mode:      %s\n' \
		"$([ -w "$float_attr" ] && echo 'float voltage (adapter-first)' || echo 'inhibit-charge (fallback)')"
	printf 'charge_behaviour:  %s\n' "$(cat "$behaviour" 2>/dev/null || echo unavailable)"
	# status is what an operator reaches for when the configuration is wrong,
	# so it must not do arithmetic on an unvalidated threshold.
	_float=$(cat "$float_attr" 2>/dev/null || true)
	if valid_uint "$_float"; then
		if valid_uint "$STOP_VOLTAGE_UV"; then
			printf 'float ceiling:     %s.%03d V (target %s.%03d V)\n' \
				$((_float / 1000000)) $((_float % 1000000 / 1000)) \
				$((STOP_VOLTAGE_UV / 1000000)) $((STOP_VOLTAGE_UV % 1000000 / 1000))
		else
			printf 'float ceiling:     %s.%03d V (target INVALID: %s)\n' \
				$((_float / 1000000)) $((_float % 1000000 / 1000)) "$STOP_VOLTAGE_UV"
		fi
	fi
	printf 'owned inhibit:     %s\n' "$([ -e "$state" ] && echo yes || echo no)"
	printf 'deficit lockout:   %s\n' "$([ -e "$lockout" ] && echo active || echo none)"
	printf 'charger online:    %s\n' "$_online"
	if valid_uint "$_vin" && valid_int "$_iin"; then
		printf 'adapter input:     %s.%03d V x %s mA = %s mW\n' \
			$((_vin / 1000000)) $((_vin % 1000000 / 1000)) $((_iin / 1000)) \
			$((_vin / 1000 * _iin / 1000000))
	fi
	valid_uint "$_icl" && printf 'settled input ICL: %s mA\n' $((_icl / 1000))
	if valid_uint "$_vbat" && valid_int "$_ibat"; then
		printf 'battery:           %s.%03d V %s mA\n' \
			$((_vbat / 1000000)) $((_vbat % 1000000 / 1000)) $((_ibat / 1000))
		if [ "$_online" = "1" ] && [ "$_ibat" -lt 0 ] &&
		   [ $((0 - _ibat)) -ge "$DEFICIT_CURRENT_UA" ]; then
			printf 'verdict:           DEFICIT - adapter is not carrying the system load\n'
		elif [ "$_online" = "1" ]; then
			printf 'verdict:           OK - system is running on the adapter\n'
		else
			printf 'verdict:           ON BATTERY - no external input\n'
		fi
	fi
	exit 0
fi

use_float=0
[ -w "$float_attr" ] && use_float=1

if [ "$use_float" -eq 0 ] && [ ! -w "$behaviour" ]; then
	logger -p daemon.err -t phoenix-charge-cap \
		"neither constant_charge_voltage nor charge_behaviour is writable; refusing to suspend USB input"
	exit 1
fi

current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)

# Reset must not depend on QGauge, source state, or normal threshold validity.
# The ownership marker is the sole authority to undo an inhibit: without it,
# an inhibit belongs to another controller and must remain untouched.
if [ "${1:-}" = "reset" ]; then
	# Restore a float ceiling we lowered, independently of any inhibit we own.
	if [ -e "$float_state" ]; then
		original=$(cat "$float_state" 2>/dev/null || true)
		if valid_uint "$original" && [ -w "$float_attr" ] &&
		   printf '%s\n' "$original" > "$float_attr" 2>/dev/null; then
			rm -f "$float_state"
			logger -t phoenix-charge-cap "reset: restored float ceiling to ${original}uV"
		else
			logger -p daemon.err -t phoenix-charge-cap \
				"reset: failed to restore float ceiling to ${original}uV"
			exit 1
		fi
	fi
	rm -f "$deficit" "$lockout"
	if [ ! -e "$state" ]; then
		logger -p daemon.info -t phoenix-charge-cap "reset: no owned inhibit, nothing to do"
		exit 0
	fi
	if ! printf '%s\n' auto > "$behaviour" 2>/dev/null; then
		logger -p daemon.err -t phoenix-charge-cap "reset: failed to write auto to $behaviour"
		exit 1
	fi
	sleep 1
	current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)
	if ! behaviour_is auto; then
		logger -p daemon.err -t phoenix-charge-cap "reset: restore to auto failed (still ${current_behaviour}), keeping ownership marker"
		exit 1
	fi
	rm -f "$state"
	logger -t phoenix-charge-cap "reset: restored auto and cleared ownership state"
	exit 0
fi

if [ "$#" -ne 0 ]; then
	logger -p daemon.err -t phoenix-charge-cap "unknown argument: $1"
	exit 2
fi

if ! valid_uint "$START_VOLTAGE_UV" || ! valid_uint "$STOP_VOLTAGE_UV" ||
	   [ "$START_VOLTAGE_UV" -ge "$STOP_VOLTAGE_UV" ]; then
	logger -p daemon.err -t phoenix-charge-cap \
		"invalid voltage thresholds: require START_VOLTAGE_UV < STOP_VOLTAGE_UV"
	exit 1
fi
# Require at least 50 mV hysteresis to avoid toggling
if [ $((STOP_VOLTAGE_UV - START_VOLTAGE_UV)) -lt 50000 ]; then
	logger -p daemon.err -t phoenix-charge-cap \
		"hysteresis too small: STOP - START must be >= 50000 uV"
	exit 1
fi
# Sanity against battery range (3.4-4.4V design)
if [ "$START_VOLTAGE_UV" -lt 3400000 ] || [ "$STOP_VOLTAGE_UV" -gt 4400000 ]; then
	logger -p daemon.err -t phoenix-charge-cap \
		"thresholds outside 3.4-4.4V battery range"
	exit 1
fi

# ---- Preferred mode: cap the float voltage, leave charging enabled ---------
# The cell rests at the ceiling with taper current near zero, the charger keeps
# regulating, and the adapter carries the system.  No hysteresis is needed --
# the hardware holds the setpoint -- so START_VOLTAGE_UV is unused here and the
# recharge threshold is the PMIC's own.
if [ "$use_float" -eq 1 ]; then
	if [ -e "$state" ]; then
		# Float control supersedes a legacy inhibit we own; drop it so the
		# charger regulates instead of leaving the battery to feed the system.
		if [ -w "$behaviour" ] && printf '%s\n' auto > "$behaviour" 2>/dev/null; then
			rm -f "$state" "$deficit"
			logger -t phoenix-charge-cap \
				"float control available; released legacy inhibit and returned to auto"
		fi
	fi

	current_float=$(cat "$float_attr" 2>/dev/null || true)
	if ! valid_uint "$current_float"; then
		logger -p daemon.err -t phoenix-charge-cap "float ceiling is unreadable"
		exit 1
	fi

	# The register quantises to 7.5 mV and the driver truncates, so a readback
	# is "already correct" anywhere inside one step below the request.
	if [ "$current_float" -le "$STOP_VOLTAGE_UV" ] &&
	   [ "$current_float" -gt $((STOP_VOLTAGE_UV - 7500)) ]; then
		exit 0
	fi

	# A lower ceiling without our ownership marker belongs to firmware or
	# another controller.  Raising it would weaken an existing safety policy.
	# Even with a marker, never raise a value that another controller may have
	# lowered since our last run; reset is the explicit restoration operation.
	if [ "$current_float" -lt "$STOP_VOLTAGE_UV" ]; then
		logger -p daemon.info -t phoenix-charge-cap \
			"float ceiling ${current_float}uV is already below target ${STOP_VOLTAGE_UV}uV; leaving the safer external limit unchanged"
		exit 0
	fi

	[ -e "$float_state" ] || printf '%s\n' "$current_float" > "$float_state"
	if ! printf '%s\n' "$STOP_VOLTAGE_UV" > "$float_attr" 2>/dev/null; then
		logger -p daemon.err -t phoenix-charge-cap \
			"failed to program float ceiling ${STOP_VOLTAGE_UV}uV"
		exit 1
	fi
	readback=$(cat "$float_attr" 2>/dev/null || echo unknown)
	logger -t phoenix-charge-cap \
		"float ceiling ${readback}uV (requested ${STOP_VOLTAGE_UV}uV, was ${current_float}uV); charging stays enabled so the adapter carries the system"
	exit 0
fi

[ -r "$gauge/voltage_now" ] || exit 0
if ! voltage_uv=$(battery_voltage_uv); then
	logger -p daemon.warning -t phoenix-charge-cap \
		"no plausible battery voltage (avg=$(cat "$gauge/voltage_avg" 2>/dev/null || echo -) now=$(cat "$gauge/voltage_now" 2>/dev/null || echo -)); taking no action"
	exit 0
fi

# Ownership: state file means *we* performed the inhibit.
# If kernel is inhibit-charge but we have no state file, it was external — do not touch.
if behaviour_is inhibit-charge && [ ! -e "$state" ]; then
	logger -p daemon.info -t phoenix-charge-cap \
		"externally inhibited (${current_behaviour}), leaving alone"
	exit 0
fi
if behaviour_is auto; then
	rm -f "$state" "$deficit"
fi

# If external power is absent, nothing to inhibit (but reset already handled)
if [ "$(cat "$charger/online" 2>/dev/null || echo 0)" != "1" ]; then
	tcpm_online=0
	for _tcpm in "$POWER_SUPPLY_ROOT"/tcpm-source-psy-*; do
		[ -d "$_tcpm" ] || continue
		if [ "$(cat "$_tcpm/online" 2>/dev/null)" = "1" ]; then tcpm_online=1; break; fi
	done
	if [ "$tcpm_online" != "1" ]; then
		logger -p daemon.info -t phoenix-charge-cap "external power offline, no-op"
		exit 0
	fi
fi

# ---- Adapter-deficit guard ----------------------------------------------
# Proof of deficit is a sustained *negative* battery current while the charger
# reports input online.  A missing or unreadable current channel proves nothing
# and must not release an inhibit, so it fails closed.
now_s=$(uptime_seconds || true)
in_deficit=0
if [ "$(cat "$charger/online" 2>/dev/null || echo 0)" = "1" ]; then
	current_ua=$(battery_current_ua || true)
	if valid_int "$current_ua" && [ "$current_ua" -lt 0 ] &&
	   [ $((0 - current_ua)) -ge "$DEFICIT_CURRENT_UA" ]; then
		in_deficit=1
	fi
fi

lockout_active=0
if [ -e "$lockout" ]; then
	lockout_started=$(cat "$lockout" 2>/dev/null || true)
	if [ "$in_deficit" -eq 1 ]; then
		# Still deficient: hold the lockout open rather than re-arming into a
		# 5-minute inhibit/release cycle against an input that cannot cope.
		[ -n "$now_s" ] && printf '%s\n' "$now_s" > "$lockout"
		lockout_active=1
	elif ! valid_uint "$lockout_started" || ! valid_uint "$now_s" ||
	     [ "$now_s" -lt "$lockout_started" ]; then
		# Unreadable clock or a corrupt marker: restart the window rather than
		# guess.  Staying locked out keeps charging enabled, which is the safe
		# direction for a battery that was just observed discharging.
		[ -n "$now_s" ] && printf '%s\n' "$now_s" > "$lockout"
		lockout_active=1
	elif [ $((now_s - lockout_started)) -ge "$DEFICIT_LOCKOUT_SECONDS" ]; then
		rm -f "$lockout"
	else
		lockout_active=1
	fi
fi

if [ -e "$state" ] && [ "$in_deficit" -eq 1 ]; then
	deficit_count=$(cat "$deficit" 2>/dev/null || echo 0)
	valid_uint "$deficit_count" || deficit_count=0
	deficit_count=$((deficit_count + 1))
	printf '%s\n' "$deficit_count" > "$deficit"
	if [ "$deficit_count" -ge "$DEFICIT_SAMPLES" ]; then
		printf '%s\n' auto > "$behaviour"
		current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)
		if ! behaviour_is auto; then
			logger -p daemon.err -t phoenix-charge-cap \
				"deficit release did not stick (still ${current_behaviour}); battery is discharging on adapter power"
			exit 1
		fi
		rm -f "$state" "$deficit"
		[ -n "$now_s" ] && printf '%s\n' "$now_s" > "$lockout"
		logger -p daemon.warning -t phoenix-charge-cap \
			"adapter cannot carry the system load (battery ${current_ua}uA at ${voltage_uv}uV with input online); released inhibit after ${deficit_count} samples"
		exit 0
	fi
elif [ "$in_deficit" -eq 0 ]; then
	rm -f "$deficit"
fi

if [ "$lockout_active" -eq 1 ] && [ ! -e "$state" ]; then
	exit 0
fi

if [ "$voltage_uv" -ge "$STOP_VOLTAGE_UV" ] && [ ! -e "$state" ]; then
	printf '%s\n' inhibit-charge > "$behaviour"
	current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)
	online=$(cat "$charger/online" 2>/dev/null || echo 0)
	if ! behaviour_is inhibit-charge; then
			logger -p daemon.err -t phoenix-charge-cap \
				"inhibit request did not stick at ${voltage_uv}uV (${current_behaviour})"
			exit 1
	fi
	if [ "$online" != "1" ]; then
		# Restore normal charging rather than leave an ambiguous power-path state.
		printf '%s\n' auto > "$behaviour" 2>/dev/null || true
		logger -p daemon.err -t phoenix-charge-cap \
			"inhibit unexpectedly removed USB input at ${voltage_uv}uV"
		exit 1
	fi
	: > "$state"
	logger -t phoenix-charge-cap \
		"inhibited battery charging at ${voltage_uv}uV; USB input remains online"
elif [ "$voltage_uv" -le "$START_VOLTAGE_UV" ] && [ -e "$state" ]; then
	printf '%s\n' auto > "$behaviour"
	current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)
	if ! behaviour_is auto; then
			logger -p daemon.err -t phoenix-charge-cap \
				"resume request did not stick at ${voltage_uv}uV (${current_behaviour})"
			exit 1
	fi
	rm -f "$state"
	logger -t phoenix-charge-cap \
		"restored automatic charging at ${voltage_uv}uV"
fi
