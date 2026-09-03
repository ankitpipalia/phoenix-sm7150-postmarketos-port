#!/bin/sh
# Voltage-based charge limiter for Phoenix server deployments.
#
# This requires qcom_smbx charge_behaviour support. Unlike the legacy STATUS
# setter, inhibit-charge disables battery charging without suspending USBIN, so
# the adapter continues to power the system.
set -eu

for _v in START_VOLTAGE_UV STOP_VOLTAGE_UV POWER_SUPPLY_ROOT RUN_DIR; do
	eval "_env_$_v=\${$_v-__unset__}"
done
START_VOLTAGE_UV=${START_VOLTAGE_UV:-4000000}
STOP_VOLTAGE_UV=${STOP_VOLTAGE_UV:-4100000}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
RUN_DIR=${RUN_DIR:-/run}

[ -r /etc/phoenix-charge-cap.conf ] && . /etc/phoenix-charge-cap.conf
[ -r /etc/default/phoenix-charge-cap ] && . /etc/default/phoenix-charge-cap
for _v in START_VOLTAGE_UV STOP_VOLTAGE_UV POWER_SUPPLY_ROOT RUN_DIR; do
	eval "_env_val=\${_env_$_v}"
	if [ "$_env_val" != "__unset__" ]; then eval "$_v=\${_env_val}"; fi
done

valid_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

behaviour_is() {
	case "$current_behaviour" in
		"$1"|*"[$1]"*) return 0 ;;
		*) return 1 ;;
	esac
}

# Reset helper for disabling timer while owning inhibit
if [ "${1:-}" = "reset" ]; then
	if [ -e "$state" ]; then
		printf '%s\n' auto > "$behaviour" 2>/dev/null || true
		rm -f "$state"
		logger -t phoenix-charge-cap "reset: restored auto and cleared ownership state"
	else
		# Even without state file, ensure auto if currently inhibited by us (check state file only)
		if behaviour_is inhibit-charge; then
			printf '%s\n' auto > "$behaviour" 2>/dev/null || true
			logger -t phoenix-charge-cap "reset: restored auto (no state file but was inhibited)"
		fi
	fi
	exit 0
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

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
gauge="$POWER_SUPPLY_ROOT/qcom_qg"
behaviour="$charger/charge_behaviour"
state="$RUN_DIR/phoenix-charge-cap.inhibited"

# If external power is absent, nothing to inhibit
if [ "$(cat "$charger/online" 2>/dev/null || echo 0)" != "1" ]; then
	# Check TCPM as well
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

[ -r "$gauge/voltage_now" ] || exit 0
[ -w "$behaviour" ] || {
	logger -p daemon.err -t phoenix-charge-cap \
		"charge_behaviour is unavailable; refusing to suspend USB input"
	exit 1
}

voltage_file="$gauge/voltage_avg"
[ -r "$voltage_file" ] || voltage_file="$gauge/voltage_now"
voltage_uv=$(cat "$voltage_file" 2>/dev/null || true)
valid_uint "$voltage_uv" || exit 0

current_behaviour=$(cat "$behaviour" 2>/dev/null || echo unknown)

# Ownership: state file means *we* performed the inhibit.
# If kernel is inhibit-charge but we have no state file, it was external — do not touch.
if behaviour_is inhibit-charge && [ ! -e "$state" ]; then
	logger -p daemon.info -t phoenix-charge-cap \
		"externally inhibited (${current_behaviour}), leaving alone"
	exit 0
fi
if behaviour_is auto; then
	rm -f "$state"
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
