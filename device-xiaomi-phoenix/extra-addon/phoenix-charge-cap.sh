#!/bin/sh
# Voltage-based charge limiter for Phoenix server deployments.
#
# This requires qcom_smbx charge_behaviour support. Unlike the legacy STATUS
# setter, inhibit-charge disables battery charging without suspending USBIN, so
# the adapter continues to power the system.
set -eu

START_VOLTAGE_UV=${START_VOLTAGE_UV:-4000000}
STOP_VOLTAGE_UV=${STOP_VOLTAGE_UV:-4100000}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
RUN_DIR=${RUN_DIR:-/run}

[ -r /etc/phoenix-charge-cap.conf ] && . /etc/phoenix-charge-cap.conf
[ -r /etc/default/phoenix-charge-cap ] && . /etc/default/phoenix-charge-cap

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

if ! valid_uint "$START_VOLTAGE_UV" || ! valid_uint "$STOP_VOLTAGE_UV" ||
   [ "$START_VOLTAGE_UV" -gt "$STOP_VOLTAGE_UV" ]; then
	logger -p daemon.err -t phoenix-charge-cap \
		"invalid voltage thresholds: require START_VOLTAGE_UV <= STOP_VOLTAGE_UV"
	exit 1
fi

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
gauge="$POWER_SUPPLY_ROOT/qcom_qg"
behaviour="$charger/charge_behaviour"
state="$RUN_DIR/phoenix-charge-cap.inhibited"

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

# Reconstruct state after a service or system restart from the kernel property.
if behaviour_is inhibit-charge; then
	: > "$state"
elif behaviour_is auto; then
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
