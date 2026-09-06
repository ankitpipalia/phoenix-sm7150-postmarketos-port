#!/bin/sh
# Verify that the adapter powers the SoC directly and the battery stays idle.
#
# The claim under test is narrow and physical: with charging inhibited, battery
# current should sit at zero while the adapter carries the whole system.  A
# single reading cannot establish that, because system draw and cell current
# both move with temperature, background work and AICL state.  So this walks a
# matrix of load levels against charge behaviours, settling before each
# measurement and cooling between load steps, and reports what the cell was
# actually doing in each cell of the matrix.
set -eu

SETTLE_SECONDS=${SETTLE_SECONDS:-10}
MEASURE_SECONDS=${MEASURE_SECONDS:-20}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-3}
COOL_TEMP_C=${COOL_TEMP_C:-45}
COOL_WAIT_S=${COOL_WAIT_S:-180}
ABORT_TEMP_C=${ABORT_TEMP_C:-85}
IDLE_BAND_UA=${IDLE_BAND_UA:-10000}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
THERMAL_ROOT=${THERMAL_ROOT:-/sys/class/thermal}
RESULT_DIR=${RESULT_DIR:-/var/log/phoenix-adapter-tests}

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
gauge="$POWER_SUPPLY_ROOT/qcom_qg"
behaviour="$charger/charge_behaviour"

usage() {
	cat <<'EOF'
usage: phoenix-power-path-verify.sh [--label NAME] [--measure N] [--settle N]
                                    [--quick]

Walks load x charge-behaviour conditions and reports, for each, whether the
battery was idle (adapter carrying everything), supplying, or charging.

  BATTERY IDLE      |mean cell current| within the idle band -- adapter is
                    powering the SoC directly and the cell is doing nothing
  SUPPLYING         cell is discharging: the adapter cannot carry this load
  CHARGING          cell is taking current (expected in auto below the ceiling)
EOF
}

LABEL=verify
quick=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--label) LABEL=${2:-}; shift 2 ;;
		--measure) MEASURE_SECONDS=${2:-}; shift 2 ;;
		--settle) SETTLE_SECONDS=${2:-}; shift 2 ;;
		--quick) quick=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "--label: use only A-Za-z0-9._-" >&2; exit 2 ;; esac

valid_int() {
	case "${1:-}" in
		''|-) return 1 ;;
		-*) case "${1#-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac ;;
		*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

read_first() { cat "$1" 2>/dev/null | head -1 || true; }

# in_range VALUE MIN MAX -- integers only.  QGauge's averaged channels read
# garbage for ~70 s after boot; a single 5 A ghost sample would flip a verdict.
in_range() {
	valid_int "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

hottest_c() {
	_max=0
	for _z in "$THERMAL_ROOT"/thermal_zone*/temp; do
		[ -r "$_z" ] || continue
		_t=$(read_first "$_z")
		case "$_t" in ''|*[!0-9]*) continue ;; esac
		_t=$((_t / 1000))
		[ "$_t" -gt "$_max" ] && _max=$_t
	done
	printf '%s\n' "$_max"
}

selected() {
	_raw=$(read_first "$1")
	case "$_raw" in
		*"["*"]"*) printf '%s\n' "${_raw#*[}" | sed 's/].*//' ;;
		*) printf '%s\n' "$_raw" ;;
	esac
}

worker_pids=""

# Load workers are pure-shell spin loops.  They have no child processes, so the
# tracked PIDs are the whole story and stopping them needs no pattern matching:
# pkill -f would happily match any unrelated command line that merely mentions
# the pattern, including the shell that launched this script.
start_load() {
	_workers=$1
	_i=0
	while [ "$_i" -lt "$_workers" ]; do
		sh -c 'while :; do :; done' &
		worker_pids="$worker_pids $!"
		_i=$((_i + 1))
	done
}

stop_load() {
	[ -n "$worker_pids" ] || return 0
	kill $worker_pids 2>/dev/null || true
	_i=0
	while [ "$_i" -lt 10 ]; do
		_alive=0
		for _p in $worker_pids; do
			if kill -0 "$_p" 2>/dev/null; then _alive=1; fi
		done
		[ "$_alive" -eq 0 ] && break
		sleep 1
		_i=$((_i + 1))
	done
	for _p in $worker_pids; do kill -9 "$_p" 2>/dev/null || true; done
	wait 2>/dev/null || true
	worker_pids=""
}

original_behaviour=$(selected "$behaviour")
timer_was_active=0
if systemctl is-active --quiet phoenix-charge-cap.timer 2>/dev/null; then
	timer_was_active=1
fi

cleanup() {
	trap - EXIT HUP INT TERM
	stop_load
	[ -n "$original_behaviour" ] &&
		printf '%s\n' "$original_behaviour" > "$behaviour" 2>/dev/null || true
	[ "$timer_was_active" -eq 1 ] &&
		systemctl start phoenix-charge-cap.timer 2>/dev/null || true
}
trap 'cleanup' EXIT HUP INT TERM

[ -w "$behaviour" ] || { echo "charge_behaviour is not writable; run as root" >&2; exit 1; }
[ "$(read_first "$charger/online")" = "1" ] ||
	{ echo "charger offline -- plug the adapter in first" >&2; exit 1; }

[ "$timer_was_active" -eq 1 ] && systemctl stop phoenix-charge-cap.timer 2>/dev/null || true

cool_to() {
	_t=$(hottest_c)
	[ "$_t" -lt "$COOL_TEMP_C" ] && return 0
	printf '   cooling from %s C ' "$_t"
	_deadline=$(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) + COOL_WAIT_S ))
	while [ "$(hottest_c)" -ge "$COOL_TEMP_C" ] &&
	      [ "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)" -lt "$_deadline" ]; do
		printf '.'
		sleep 5
	done
	printf ' now %s C\n' "$(hottest_c)"
}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RESULT_DIR"
out="$RESULT_DIR/$stamp-$LABEL-powerpath.txt"

printf '%-22s %-9s %9s %9s %9s %8s %7s  %s\n' \
	CONDITION BEHAVIOUR 'cell_mA' 'min_mA' 'max_mA' 'input_W' 'temp_C' VERDICT | tee "$out"

run_condition() {
	_name=$1; _beh=$2; _workers=$3

	cool_to
	printf '%s\n' "$_beh" > "$behaviour" 2>/dev/null || true
	sleep 1
	if [ "$(selected "$behaviour")" != "$_beh" ]; then
		printf '%-22s %-9s  could not select behaviour\n' "$_name" "$_beh" | tee -a "$out"
		return 0
	fi

	[ "$_workers" -gt 0 ] && start_load "$_workers"
	sleep "$SETTLE_SECONDS"

	_n=0; _sum=0; _min=; _max=; _pin=0; _aborted=0
	_end=$(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) + MEASURE_SECONDS ))
	while [ "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)" -lt "$_end" ]; do
		_t=$(hottest_c)
		if [ "$_t" -ge "$ABORT_TEMP_C" ]; then _aborted=1; break; fi
		_ib=$(read_first "$gauge/current_now")
		_vin=$(read_first "$charger/voltage_now")
		_iin=$(read_first "$charger/current_now")
		if in_range "$_ib" -3000000 3000000 && in_range "$_vin" 3000000 13000000 &&
		   in_range "$_iin" 0 5000000; then
			_sum=$((_sum + _ib)); _n=$((_n + 1))
			[ -z "$_min" ] && _min=$_ib; [ -z "$_max" ] && _max=$_ib
			[ "$_ib" -lt "$_min" ] && _min=$_ib
			[ "$_ib" -gt "$_max" ] && _max=$_ib
			_pin=$((_pin + _vin / 1000 * _iin / 1000000))
		fi
		sleep "$SAMPLE_SECONDS"
	done
	stop_load

	if [ "$_n" -eq 0 ]; then
		# This SoC can cross the abort threshold during the settle window, so
		# distinguish "too hot to measure" from "sensors unreadable".
		if [ "$_aborted" -eq 1 ]; then
			printf '%-22s %-9s  THERMAL LIMIT - reached %s C before a sample could be taken\n' \
				"$_name" "$_beh" "$(hottest_c)" | tee -a "$out"
		else
			printf '%-22s %-9s  no valid samples\n' "$_name" "$_beh" | tee -a "$out"
		fi
		return 0
	fi
	_mean=$((_sum / _n))
	_abs=$_mean; [ "$_abs" -lt 0 ] && _abs=$((0 - _abs))
	if [ "$_abs" -le "$IDLE_BAND_UA" ]; then
		_verdict="BATTERY IDLE"
	elif [ "$_mean" -lt 0 ]; then
		_verdict="SUPPLYING"
	else
		_verdict="CHARGING"
	fi
	[ "$_aborted" -eq 1 ] && _verdict="$_verdict (hot-abort)"

	printf '%-22s %-9s %9s %9s %9s %8s %7s  %s\n' \
		"$_name" "$_beh" \
		"$(awk -v v="$_mean" 'BEGIN{printf "%+.1f", v/1000}')" \
		"$(awk -v v="$_min" 'BEGIN{printf "%+.1f", v/1000}')" \
		"$(awk -v v="$_max" 'BEGIN{printf "%+.1f", v/1000}')" \
		"$(awk -v v="$_pin" -v n="$_n" 'BEGIN{printf "%.2f", v/n/1000}')" \
		"$(hottest_c)" "$_verdict" | tee -a "$out"
}

run_condition "idle"             inhibit-charge 0
run_condition "idle"             auto           0
run_condition "light (1 core)"   inhibit-charge 1
run_condition "light (1 core)"   auto           1
if [ "$quick" -eq 0 ]; then
	run_condition "medium (2 cores)" inhibit-charge 2
	run_condition "medium (2 cores)" auto           2
fi

echo
echo "saved: $out"
echo "idle band: +/- $((IDLE_BAND_UA / 1000)) mA"
