#!/bin/sh
# phoenix-typec-recover: rescue from "stuck as source" typec state.
#
# When the phone loses its upstream charger but keeps the hub attached, the
# typec stack transitions to source/host so the hub stays alive on battery
# power. When the charger reappears, USB-PD's PR_Swap message would normally
# hand the source role back to the wall — but phoenix's common hubs have no
# PD support (pd_revision=0.0), so no swap happens and the phone keeps
# sourcing forever, slowly draining its battery while the unused charger
# sits idle on the other side of the cable.
#
# This script detects that pattern and forces a manual swap by writing
# "sink" to /sys/class/typec/port0/power_role. If no external power was
# actually available, it reverts to "source" so the hub stays powered.
#
# Voltage is the primary urgency escalator; capacity is kept as legacy fallback.
set -eu

CAP_THRESHOLD=${CAP_THRESHOLD:-30}
VOLTAGE_THRESHOLD_UV=${VOLTAGE_THRESHOLD_UV:-3600000}
PERSIST_SEC=${PERSIST_SEC:-0}
LOCK_FILE=${LOCK_FILE:-/run/lock/phoenix-usb-role.lock}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
TYPEC_ROOT=${TYPEC_ROOT:-/sys/class/typec}
[ -r /etc/phoenix-typec-recover.conf ] && . /etc/phoenix-typec-recover.conf

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
qg="$POWER_SUPPLY_ROOT/qcom_qg"
typec="$TYPEC_ROOT/port0"

[ -e "$typec/power_role" ] || exit 0
[ -e "$charger/online" ] || exit 0
[ -e "$charger/status" ] || exit 0

[ -d "$TYPEC_ROOT/port0-partner" ] || exit 0

if ! command -v flock >/dev/null 2>&1; then
	logger -p daemon.err -t phoenix-typec-recover "flock not found, cannot safely recover Type-C role"
	exit 1
fi

is_stuck_source() {
	pr=$(cat "$typec/power_role" 2>/dev/null || echo "")
	case "$pr" in
		*"[source]"*) return 0 ;;
		*) return 1 ;;
	esac
}

# Early exit if not stuck
if ! is_stuck_source; then
	exit 0
fi
[ "$(cat "$charger/online" 2>/dev/null)" = "0" ] || exit 0
# Note: qcom_smbx never returns Discharging, so don't require charger/status
# The stronger evidence is partner present + source + offline + low voltage (checked below)

# Check voltage/capacity urgency. Voltage is primary; capacity is used whenever
# no valid voltage sample is available, including missing/unreadable files.
urgent=0
voltage_uv=""

for voltage_file in "$qg/voltage_avg" "$qg/voltage_now"; do
	[ -r "$voltage_file" ] || continue
	voltage_uv=$(cat "$voltage_file" 2>/dev/null || true)
	case "$voltage_uv" in
		''|*[!0-9]*) voltage_uv="" ;;
	esac
	[ -n "$voltage_uv" ] && break
done

if [ -n "$voltage_uv" ]; then
	if [ "$voltage_uv" -lt "$VOLTAGE_THRESHOLD_UV" ]; then
		urgent=1
	else
		logger -t phoenix-typec-recover "stuck as source at ${voltage_uv}uV but above threshold ${VOLTAGE_THRESHOLD_UV}uV, deferring"
		exit 0
	fi
else
	# Voltage unavailable or invalid: fall back to the voltage-derived level.
	cap=""
	if [ -r "$qg/capacity" ]; then
		cap=$(cat "$qg/capacity" 2>/dev/null || true)
		case "$cap" in
			''|*[!0-9]*) cap="" ;;
		esac
	fi
	if [ -n "$cap" ]; then
		if [ "$cap" -lt "$CAP_THRESHOLD" ]; then
			urgent=1
		else
			logger -t phoenix-typec-recover "stuck as source with voltage unavailable at ${cap}% but above threshold CAP $CAP_THRESHOLD, deferring"
			exit 0
		fi
	else
		logger -t phoenix-typec-recover "stuck as source with no valid voltage/capacity urgency signal, deferring"
		exit 0
	fi
fi
[ "$urgent" -eq 1 ] || exit 0

# Optional persistence: require stuck for PERSIST_SEC (if timer is 5min, this is extra)
if [ "$PERSIST_SEC" -gt 0 ]; then
	sleep "$PERSIST_SEC"
	if ! is_stuck_source; then
		exit 0
	fi
fi

# Acquire lock only for role mutation, re-check stuck after lock
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9 2>/dev/null; then
	logger -t phoenix-typec-recover "USB role lock busy, skipping"
	exit 0
fi
if ! is_stuck_source; then
	logger -t phoenix-typec-recover "stuck state cleared while waiting for lock"
	exit 0
fi
# Attempt: swap to sink and observe.
cap_disp=$(cat "$qg/capacity" 2>/dev/null || echo "?")
voltage_disp=$(cat "$qg/voltage_avg" 2>/dev/null || cat "$qg/voltage_now" 2>/dev/null || echo "?")
if ! echo sink > "$typec/power_role" 2>/dev/null; then
	logger -p daemon.err -t phoenix-typec-recover "failed to write sink to power_role at ${cap_disp}%/${voltage_disp}uV"
	exit 1
fi
sleep 3
new_online=$(cat "$charger/online" 2>/dev/null || echo 0)
new_status=$(cat "$charger/status" 2>/dev/null || echo Unknown)
new_pr=$(cat "$typec/power_role" 2>/dev/null || echo "")
case "$new_pr" in
	*"[sink]"*) sink_ok=1 ;;
	*) sink_ok=0 ;;
esac
# Also check TCPM online
tcpm_online=0
for _tcpm in "$POWER_SUPPLY_ROOT"/tcpm-source-psy-*; do
	[ -d "$_tcpm" ] || continue
	if [ "$(cat "$_tcpm/online" 2>/dev/null)" = "1" ]; then tcpm_online=1; break; fi
done
if [ "$sink_ok" = "1" ] && { [ "$new_online" = "1" ] || [ "$tcpm_online" = "1" ]; }; then
	logger -t phoenix-typec-recover "recovered to sink at ${cap_disp}%/${voltage_disp}uV (external power detected after manual swap, power_role $new_pr)"
	exit 0
fi

# No external power — restore source so the hub keeps VBUS, verify.
if ! echo source > "$typec/power_role" 2>/dev/null; then
	logger -p daemon.err -t phoenix-typec-recover "no external power at ${cap_disp}%/${voltage_disp}uV — failed to revert to source (hub may lose VBUS)"
	exit 1
fi
sleep 1
revert_pr=$(cat "$typec/power_role" 2>/dev/null || echo "")
case "$revert_pr" in
	*"[source]"*)
		logger -t phoenix-typec-recover "no external power at ${cap_disp}%/${voltage_disp}uV — reverted to source (hub still attached, power_role $revert_pr)"
		;;
	*)
		logger -p daemon.err -t phoenix-typec-recover "no external power at ${cap_disp}%/${voltage_disp}uV — attempted revert to source but power_role is $revert_pr"
		;;
esac
