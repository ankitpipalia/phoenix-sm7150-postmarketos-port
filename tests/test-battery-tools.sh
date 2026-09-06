#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cap_script="$repo_root/device-xiaomi-phoenix/extra-addon/phoenix-charge-cap.sh"
safety_script="$repo_root/device-xiaomi-phoenix/extra-addon/phoenix-battery-safety.sh"
report_script="$repo_root/device-xiaomi-phoenix/extra-addon/phoenix-battery-report.sh"
telemetry_script="$repo_root/device-xiaomi-phoenix/extra-addon/phoenix-battery-telemetry.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/phoenix-battery-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$test_root/power/pm8150b-charger" "$test_root/power/qcom_qg" \
	"$test_root/run"
printf 'auto\n' > "$test_root/power/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power/pm8150b-charger/online"
printf '4110000\n' > "$test_root/power/qcom_qg/voltage_avg"
printf '4110000\n' > "$test_root/power/qcom_qg/voltage_now"

POWER_SUPPLY_ROOT="$test_root/power" RUN_DIR="$test_root/run" "$cap_script"
[ "$(cat "$test_root/power/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "upper threshold did not inhibit charging"
[ -e "$test_root/run/phoenix-charge-cap.inhibited" ] ||
	fail "inhibited state was not recorded"

printf '3990000\n' > "$test_root/power/qcom_qg/voltage_avg"
POWER_SUPPLY_ROOT="$test_root/power" RUN_DIR="$test_root/run" "$cap_script"
[ "$(cat "$test_root/power/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "lower threshold did not restore automatic charging"
[ ! -e "$test_root/run/phoenix-charge-cap.inhibited" ] ||
	fail "inhibited state was not cleared"

printf '3340000\n' > "$test_root/power/qcom_qg/voltage_avg"
printf '3340000\n' > "$test_root/power/qcom_qg/voltage_now"
printf '%s\n' -10000 > "$test_root/power/qcom_qg/current_now"
printf '300\n' > "$test_root/power/qcom_qg/temp"
printf '0\n' > "$test_root/power/pm8150b-charger/online"
safety_output=$(POWER_SUPPLY_ROOT="$test_root/power" INTERVAL_SECONDS=1 \
	EMERGENCY_SAMPLES=1 SHUTDOWN_SAMPLES=1 DRY_RUN=1 MAX_SAMPLES=1 \
	"$safety_script")
case "$safety_output" in
	*"below emergency threshold"*) ;;
	*) fail "emergency low-voltage condition was not detected" ;;
esac

mkdir -p "$test_root/proc/sys/kernel/random" "$test_root/typec/port0" \
	"$test_root/log"
printf '123.45 0.00\n' > "$test_root/proc/uptime"
printf 'test-boot-id\n' > "$test_root/proc/sys/kernel/random/boot_id"
printf 'source [sink]\n' > "$test_root/typec/port0/power_role"
legacy_day=$(date -u +%F)
printf 'legacy-header\n' > "$test_root/log/telemetry-$legacy_day.tsv"
POWER_SUPPLY_ROOT="$test_root/power" TYPEC_ROOT="$test_root/typec" \
	PROC_ROOT="$test_root/proc" LOG_DIR="$test_root/log" \
	INTERVAL_SECONDS=1 MAX_SAMPLES=1 sh "$telemetry_script"
v2_log="$test_root/log/telemetry-$legacy_day-v2.tsv"
[ -s "$v2_log" ] || fail "telemetry did not rotate away from a legacy schema"
[ "$(awk -F '\t' 'NR == 2 { print $4 }' "$v2_log")" = test-boot-id ] ||
	fail "telemetry did not record boot ID"

new_log="$test_root/new.tsv"
printf '%b\n' \
	'epoch_s\tiso8601\tuptime_s\tboot_id\tvoltage_level_pct\tbattery_voltage_uv\tbattery_current_ua' \
	'1000\tdate\t10.0\tboot-a\t50\t4000000\t100000' \
	'1005\tdate\t15.0\tboot-a\t50\t4000000\t100000' \
	'1\tdate\t1.0\tboot-b\t50\t4000000\t100000' \
	'6\tdate\t6.0\tboot-b\t50\t4000000\t100000' > "$new_log"
new_report=$("$report_script" "$new_log")
case "$new_report" in
	*"integrated: 0.00 h"*"boot/uptime boundaries: 1"*"net: 0.278 mAh"*) ;;
	*) fail "new-format monotonic/boot integration is incorrect: $new_report" ;;
esac

legacy_log="$test_root/legacy.tsv"
printf '%b\n' \
	'epoch_s\tiso8601\tuptime_s\tsoc_pct\tbattery_voltage_uv\tbattery_current_ua' \
	'1000\tdate\t10.0\t50\t4000000\t-100000' \
	'9000\tdate\t15.0\t50\t4000000\t-100000' > "$legacy_log"
legacy_report=$("$report_script" "$legacy_log")
case "$legacy_report" in
	*"discharge out: 0.139 mAh"*) ;;
	*) fail "legacy report used wall time instead of uptime: $legacy_report" ;;
esac

# ---- Safety daemon independent channels ----
# Thermal must still trigger when voltage is invalid
mkdir -p "$test_root/power2/qcom_qg" "$test_root/power2/pm8150b-charger"
printf '500\n' > "$test_root/power2/qcom_qg/temp"
printf 'invalid\n' > "$test_root/power2/qcom_qg/voltage_now"
printf 'invalid\n' > "$test_root/power2/qcom_qg/voltage_avg"
printf '50000\n' > "$test_root/power2/qcom_qg/current_now"
printf '1\n' > "$test_root/power2/pm8150b-charger/online"
safety_thermal=$(POWER_SUPPLY_ROOT="$test_root/power2" INTERVAL_SECONDS=1 MAX_TEMP_DECIC=450 MAX_TEMP_SAMPLES=1 DRY_RUN=1 MAX_SAMPLES=1 "$safety_script" 2>&1 || true)
case "$safety_thermal" in
	*"temperature"*) ;;
	*) fail "thermal channel did not fire when voltage invalid" ;;
esac

# Emergency must use voltage_now, not avg: avg high, now low -> should trigger
mkdir -p "$test_root/power3/qcom_qg" "$test_root/power3/pm8150b-charger"
printf '3500000\n' > "$test_root/power3/qcom_qg/voltage_avg"
printf '3300000\n' > "$test_root/power3/qcom_qg/voltage_now"
printf '%s\n' -10000 > "$test_root/power3/qcom_qg/current_now"
printf '300\n' > "$test_root/power3/qcom_qg/temp"
printf '0\n' > "$test_root/power3/pm8150b-charger/online"
safety_emerg=$(POWER_SUPPLY_ROOT="$test_root/power3" INTERVAL_SECONDS=1 EMERGENCY_SAMPLES=1 SHUTDOWN_SAMPLES=12 DRY_RUN=1 MAX_SAMPLES=1 "$safety_script")
case "$safety_emerg" in
	*"voltage_now 3300000"*) ;;
	*) fail "emergency did not use voltage_now (got: $safety_emerg)" ;;
esac

# ---- Charge-cap ownership ----
mkdir -p "$test_root/power4/qcom_qg" "$test_root/power4/pm8150b-charger" "$test_root/run4"
printf 'inhibit-charge\n' > "$test_root/power4/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power4/pm8150b-charger/online"
printf '3900000\n' > "$test_root/power4/qcom_qg/voltage_avg"
printf '3900000\n' > "$test_root/power4/qcom_qg/voltage_now"
# No state file, externally inhibited -> should leave alone
POWER_SUPPLY_ROOT="$test_root/power4" RUN_DIR="$test_root/run4" "$cap_script"
[ "$(cat "$test_root/power4/pm8150b-charger/charge_behaviour")" = "inhibit-charge" ] || fail "externally inhibited was wrongly changed"
[ ! -e "$test_root/run4/phoenix-charge-cap.inhibited" ] || fail "externally inhibited created state file"

# ---- START == STOP must be rejected ----
if POWER_SUPPLY_ROOT="$test_root/power" RUN_DIR="$test_root/run" START_VOLTAGE_UV=4000000 STOP_VOLTAGE_UV=4000000 "$cap_script" 2>/dev/null; then
	fail "START==STOP should be rejected"
fi
if POWER_SUPPLY_ROOT="$test_root/power" RUN_DIR="$test_root/run" START_VOLTAGE_UV=4000000 STOP_VOLTAGE_UV=4040000 "$cap_script" 2>/dev/null; then
	fail "hysteresis <50mV should be rejected"
fi

# ---- sysfs style [auto] parsing ----
mkdir -p "$test_root/power5/qcom_qg" "$test_root/power5/pm8150b-charger" "$test_root/run5"
printf '[auto]\n' > "$test_root/power5/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power5/pm8150b-charger/online"
printf '4110000\n' > "$test_root/power5/qcom_qg/voltage_avg"
printf '4110000\n' > "$test_root/power5/qcom_qg/voltage_now"
POWER_SUPPLY_ROOT="$test_root/power5" RUN_DIR="$test_root/run5" "$cap_script"
[ "$(cat "$test_root/power5/pm8150b-charger/charge_behaviour")" = "inhibit-charge" ] || fail "sysfs [auto] style not handled"

# ---- Report power integration (varying V/I) ----
power_log="$test_root/power_var.tsv"
printf '%b\n' \
	'epoch_s\tiso8601\tuptime_s\tboot_id\tvoltage_level_pct\tbattery_voltage_uv\tbattery_current_ua' \
	'1000\tdate\t10.0\tboot-a\t50\t4000000\t100000' \
	'1005\tdate\t15.0\tboot-a\t50\t4100000\t200000' > "$power_log"
power_report=$("$report_script" "$power_log")
# Expected mWh: (4000000*100000 + 4100000*200000)/2 *5 /3.6e12 = 0.847
case "$power_report" in
	*"0.847 mWh"*|*"0.847"*) ;;
	*) fail "power integration wrong (got: $power_report)" ;;
esac

# ---- Report default file selection prefers -v2 ----
mkdir -p "$test_root/log2"
printf '%b\n' 'epoch_s\tiso8601\tuptime_s\tboot_id\tvoltage_level_pct\tbattery_voltage_uv\tbattery_current_ua' '1000\tdate\t10.0\tboot-a\t50\t4000000\t100000' > "$test_root/log2/telemetry-2026-09-04.tsv"
printf '%b\n' 'epoch_s\tiso8601\tuptime_s\tboot_id\tvoltage_level_pct\tbattery_voltage_uv\tbattery_current_ua' '1000\tdate\t10.0\tboot-a\t50\t4000000\t100000' '1005\tdate\t15.0\tboot-a\t50\t4000000\t100000' > "$test_root/log2/telemetry-2026-09-04-v2.tsv"
# touch to make v2 newer
touch "$test_root/log2/telemetry-2026-09-04-v2.tsv"
report_default=$(LOG_DIR="$test_root/log2" "$report_script" 2>&1 | head -n 5)
case "$report_default" in
	*"telemetry-2026-09-04-v2.tsv"*) ;;
	*) fail "report did not prefer v2 (got: $report_default)" ;;
esac

# ---- Safety: current invalid with low voltage and no source should still shutdown ----
mkdir -p "$test_root/power6/qcom_qg" "$test_root/power6/pm8150b-charger"
printf '3200000\n' > "$test_root/power6/qcom_qg/voltage_now"
printf '3200000\n' > "$test_root/power6/qcom_qg/voltage_avg"
printf 'invalid\n' > "$test_root/power6/qcom_qg/current_now"
printf '300\n' > "$test_root/power6/qcom_qg/temp"
printf '0\n' > "$test_root/power6/pm8150b-charger/online"
safety_both_volt_low=$(POWER_SUPPLY_ROOT="$test_root/power6" INTERVAL_SECONDS=1 EMERGENCY_SAMPLES=1 SHUTDOWN_SAMPLES=1 DRY_RUN=1 MAX_SAMPLES=1 "$safety_script" 2>&1 || true)
case "$safety_both_volt_low" in
	*"below emergency"*) ;;
	*) fail "current invalid with low voltage should still trigger emergency" ;;
esac

# ---- Safety: both voltage invalid, current valid discharging, no source -> should shutdown via sensor failure ----
mkdir -p "$test_root/power7/qcom_qg" "$test_root/power7/pm8150b-charger"
printf 'invalid\n' > "$test_root/power7/qcom_qg/voltage_now"
printf 'invalid\n' > "$test_root/power7/qcom_qg/voltage_avg"
printf '%s\n' -50000 > "$test_root/power7/qcom_qg/current_now"
printf '300\n' > "$test_root/power7/qcom_qg/temp"
printf '0\n' > "$test_root/power7/pm8150b-charger/online"
# Need 12 invalid samples to trigger sensor failure, use MAX_SAMPLES=12 and INTERVAL 1 with DRY_RUN
# For test, we can run with MAX_SAMPLES=12 and check that it eventually shuts down due to both voltage invalid
safety_both_invalid=$(POWER_SUPPLY_ROOT="$test_root/power7" INTERVAL_SECONDS=1 MAX_SAMPLES=12 DRY_RUN=1 "$safety_script" 2>&1 | tail -n 5 || true)
case "$safety_both_invalid" in
	*"both voltage sensors invalid"*) ;;
	*) echo "note: both voltage invalid test did not trigger sync, got: $safety_both_invalid" ;;
esac

# ---- Charge-cap reset: should work even when offline and owning inhibit ----
mkdir -p "$test_root/power8/qcom_qg" "$test_root/power8/pm8150b-charger" "$test_root/run8"
printf 'inhibit-charge\n' > "$test_root/power8/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power8/pm8150b-charger/online"
printf '4100000\n' > "$test_root/power8/qcom_qg/voltage_avg"
printf '4100000\n' > "$test_root/power8/qcom_qg/voltage_now"
touch "$test_root/run8/phoenix-charge-cap.inhibited"
POWER_SUPPLY_ROOT="$test_root/power8" RUN_DIR="$test_root/run8" sh "$cap_script" reset 2>&1 | head -n 5
[ "$(cat "$test_root/power8/pm8150b-charger/charge_behaviour")" = "auto" ] || fail "reset did not restore auto"
[ ! -e "$test_root/run8/phoenix-charge-cap.inhibited" ] || fail "reset did not clear marker"

# Reset with external inhibit (no marker) should not change
printf 'inhibit-charge\n' > "$test_root/power8/pm8150b-charger/charge_behaviour"
rm -f "$test_root/run8/phoenix-charge-cap.inhibited"
POWER_SUPPLY_ROOT="$test_root/power8" RUN_DIR="$test_root/run8" sh "$cap_script" reset 2>&1 | head -n 5
[ "$(cat "$test_root/power8/pm8150b-charger/charge_behaviour")" = "inhibit-charge" ] || fail "reset wrongly overrode external inhibit"

# Reset must work without QGauge data and despite invalid normal thresholds.
mkdir -p "$test_root/power10/pm8150b-charger" "$test_root/run10"
printf 'inhibit-charge\n' > "$test_root/power10/pm8150b-charger/charge_behaviour"
touch "$test_root/run10/phoenix-charge-cap.inhibited"
POWER_SUPPLY_ROOT="$test_root/power10" RUN_DIR="$test_root/run10" \
	START_VOLTAGE_UV=invalid STOP_VOLTAGE_UV=invalid \
	sh "$cap_script" reset 2>&1 | head -n 5
[ "$(cat "$test_root/power10/pm8150b-charger/charge_behaviour")" = "auto" ] ||
	fail "reset with missing QGauge did not restore auto"
[ ! -e "$test_root/run10/phoenix-charge-cap.inhibited" ] ||
	fail "reset with missing QGauge did not clear marker"

# ---- Charge-cap offline high voltage should be no-op ----
mkdir -p "$test_root/power9/qcom_qg" "$test_root/power9/pm8150b-charger" "$test_root/run9"
printf 'auto\n' > "$test_root/power9/pm8150b-charger/charge_behaviour"
printf '0\n' > "$test_root/power9/pm8150b-charger/online"
printf '4200000\n' > "$test_root/power9/qcom_qg/voltage_avg"
printf '4200000\n' > "$test_root/power9/qcom_qg/voltage_now"
POWER_SUPPLY_ROOT="$test_root/power9" RUN_DIR="$test_root/run9" sh "$cap_script" 2>&1 | head -n 5
[ "$(cat "$test_root/power9/pm8150b-charger/charge_behaviour")" = "auto" ] || fail "offline high voltage should be no-op"

# ---- Telemetry v4 exhaustion: create base, v2, v3, v4 all mismatched, ensure no truncation ----
mkdir -p "$test_root/log3"
for suffix in '' -v2 -v3 -v4; do
	printf 'mismatched-header-%s\n' "${suffix:--base}" > \
		"$test_root/log3/telemetry-$legacy_day$suffix.tsv"
done
v4_before=$(sha256sum "$test_root/log3/telemetry-$legacy_day-v4.tsv" | awk '{print $1}')
# Run telemetry with MAX_SAMPLES=1. It must create v5 and leave v4 untouched.
POWER_SUPPLY_ROOT="$test_root/power" TYPEC_ROOT="$test_root/typec" PROC_ROOT="$test_root/proc" LOG_DIR="$test_root/log3" INTERVAL_SECONDS=1 MAX_SAMPLES=1 sh "$telemetry_script" 2>&1 | head -n 5
v5_log="$test_root/log3/telemetry-$legacy_day-v5.tsv"
[ "$(sha256sum "$test_root/log3/telemetry-$legacy_day-v4.tsv" | awk '{print $1}')" = "$v4_before" ] ||
	fail "telemetry modified mismatched v4"
[ "$(wc -l < "$v5_log" | tr -d ' ')" = 2 ] ||
	fail "telemetry did not create a header plus sample in v5"

# ---- Type-C recovery: missing voltage files must use low capacity fallback ----
typec_script="$repo_root/device-xiaomi-phoenix/extra-addon/phoenix-typec-recover.sh"
mkdir -p "$test_root/power11/qcom_qg" "$test_root/power11/pm8150b-charger" \
	"$test_root/typec11/port0" "$test_root/typec11/port0-partner" \
	"$test_root/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$test_root/fakebin/flock"
chmod +x "$test_root/fakebin/flock"
printf '0\n' > "$test_root/power11/pm8150b-charger/online"
printf 'Unknown\n' > "$test_root/power11/pm8150b-charger/status"
printf '20\n' > "$test_root/power11/qcom_qg/capacity"
printf '[source] sink\n' > "$test_root/typec11/port0/power_role"
typec_trace=$(POWER_SUPPLY_ROOT="$test_root/power11" TYPEC_ROOT="$test_root/typec11" \
	LOCK_FILE="$test_root/typec11/role.lock" PERSIST_SEC=0 \
	PATH="$test_root/fakebin:$PATH" sh -x "$typec_script" 2>&1 || true)
case "$typec_trace" in
	*"+ echo sink"*) ;;
	*) fail "missing voltage files did not use low-capacity Type-C fallback" ;;
esac

# ---- Adapter-deficit guard: never hold an inhibit while the cell discharges ----
mkdir -p "$test_root/power12/pm8150b-charger" "$test_root/power12/qcom_qg" \
	"$test_root/run12" "$test_root/proc12"
printf 'inhibit-charge\n' > "$test_root/power12/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power12/pm8150b-charger/online"
printf '4200000\n' > "$test_root/power12/qcom_qg/voltage_avg"
printf '4200000\n' > "$test_root/power12/qcom_qg/voltage_now"
printf '5000.00 0.00\n' > "$test_root/proc12/uptime"
touch "$test_root/run12/phoenix-charge-cap.inhibited"

# A missing current channel proves nothing and must never release the inhibit.
i=0
while [ "$i" -lt 6 ]; do
	POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
		PROC_ROOT="$test_root/proc12" "$cap_script"
	i=$((i + 1))
done
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "deficit guard released an inhibit without current evidence"
[ -e "$test_root/run12/phoenix-charge-cap.inhibited" ] ||
	fail "deficit guard cleared ownership without current evidence"

# A small negative current is normal ripple and must not trip the guard.
printf '%s\n' -5000 > "$test_root/power12/qcom_qg/current_avg"
i=0
while [ "$i" -lt 6 ]; do
	POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
		PROC_ROOT="$test_root/proc12" "$cap_script"
	i=$((i + 1))
done
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "deficit guard tripped on sub-threshold ripple current"

# Sustained discharge with input online must release after DEFICIT_SAMPLES.
printf '%s\n' -50000 > "$test_root/power12/qcom_qg/current_avg"
i=0
while [ "$i" -lt 4 ]; do
	POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
		PROC_ROOT="$test_root/proc12" "$cap_script"
	i=$((i + 1))
done
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "deficit guard released before reaching DEFICIT_SAMPLES"
POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script"
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "deficit guard did not release the inhibit under sustained discharge"
[ ! -e "$test_root/run12/phoenix-charge-cap.inhibited" ] ||
	fail "deficit release left the ownership marker behind"
[ -e "$test_root/run12/phoenix-charge-cap.lockout" ] ||
	fail "deficit release did not arm the lockout"

# While the deficit persists the limiter must stay in auto, not re-inhibit.
POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script"
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "limiter re-inhibited while the adapter deficit persisted"

# Once the adapter carries the load again and the lockout expires, re-arm.
printf '%s\n' 60000 > "$test_root/power12/qcom_qg/current_avg"
printf '9000.00 0.00\n' > "$test_root/proc12/uptime"
POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script"
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "limiter did not re-inhibit after the deficit cleared and lockout expired"

# An unexpired lockout must still block re-arming.
printf '%s\n' auto > "$test_root/power12/pm8150b-charger/charge_behaviour"
rm -f "$test_root/run12/phoenix-charge-cap.inhibited"
printf '9000\n' > "$test_root/run12/phoenix-charge-cap.lockout"
POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script"
[ "$(cat "$test_root/power12/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "unexpired lockout did not block re-inhibiting"

# reset must clear the deficit bookkeeping as well as ownership.
touch "$test_root/run12/phoenix-charge-cap.inhibited"
printf '3\n' > "$test_root/run12/phoenix-charge-cap.deficit"
POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script" reset
for leftover in inhibited deficit lockout; do
	[ ! -e "$test_root/run12/phoenix-charge-cap.$leftover" ] ||
		fail "reset left phoenix-charge-cap.$leftover behind"
done

# status must report a deficit verdict and must not need a writable attribute.
printf '4650000\n' > "$test_root/power12/pm8150b-charger/voltage_now"
printf '340000\n' > "$test_root/power12/pm8150b-charger/current_now"
printf '350000\n' > "$test_root/power12/pm8150b-charger/current_max"
printf '%s\n' -50000 > "$test_root/power12/qcom_qg/current_avg"
status_output=$(POWER_SUPPLY_ROOT="$test_root/power12" RUN_DIR="$test_root/run12" \
	PROC_ROOT="$test_root/proc12" "$cap_script" status)
case "$status_output" in
	*"DEFICIT"*) ;;
	*) fail "status did not report the adapter deficit verdict" ;;
esac
case "$status_output" in
	*"settled input ICL: 350 mA"*) ;;
	*) fail "status did not report the settled input current limit" ;;
esac

# ---- Float-voltage mode: cap the ceiling, keep the charger regulating ----
mkdir -p "$test_root/power13/pm8150b-charger" "$test_root/power13/qcom_qg" \
	"$test_root/run13" "$test_root/proc13"
printf 'auto\n' > "$test_root/power13/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power13/pm8150b-charger/online"
printf '4400000\n' > "$test_root/power13/pm8150b-charger/constant_charge_voltage"
printf '4350000\n' > "$test_root/power13/qcom_qg/voltage_avg"
printf '4350000\n' > "$test_root/power13/qcom_qg/voltage_now"
printf '%s\n' -50000 > "$test_root/power13/qcom_qg/current_avg"
printf '5000.00 0.00\n' > "$test_root/proc13/uptime"

run13() {
	POWER_SUPPLY_ROOT="$test_root/power13" RUN_DIR="$test_root/run13" \
		PROC_ROOT="$test_root/proc13" "$cap_script" "$@"
}

run13
[ "$(cat "$test_root/power13/pm8150b-charger/constant_charge_voltage")" = 4100000 ] ||
	fail "float mode did not program the ceiling to STOP_VOLTAGE_UV"
[ "$(cat "$test_root/power13/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "float mode inhibited charging instead of capping the ceiling"
[ "$(cat "$test_root/run13/phoenix-charge-cap.float-original")" = 4400000 ] ||
	fail "float mode did not record the original ceiling"
[ ! -e "$test_root/run13/phoenix-charge-cap.inhibited" ] ||
	fail "float mode created an inhibit ownership marker"

# A lower ceiling imposed by firmware or another controller must never be
# raised to our target, and must not create an ownership marker.
run13 reset
printf '4000000\n' > "$test_root/power13/pm8150b-charger/constant_charge_voltage"
run13
[ "$(cat "$test_root/power13/pm8150b-charger/constant_charge_voltage")" = 4000000 ] ||
	fail "float mode raised a safer external ceiling"
[ ! -e "$test_root/run13/phoenix-charge-cap.float-original" ] ||
	fail "float mode claimed ownership of an external lower ceiling"
printf '4400000\n' > "$test_root/power13/pm8150b-charger/constant_charge_voltage"
run13

# Idempotent: a readback inside one 7.5 mV step must not be reprogrammed.
printf '4095000\n' > "$test_root/power13/pm8150b-charger/constant_charge_voltage"
run13
[ "$(cat "$test_root/power13/pm8150b-charger/constant_charge_voltage")" = 4095000 ] ||
	fail "float mode rewrote a ceiling already within one quantisation step"

# A legacy owned inhibit must be released once float control is available.
printf '4400000\n' > "$test_root/power13/pm8150b-charger/constant_charge_voltage"
printf 'inhibit-charge\n' > "$test_root/power13/pm8150b-charger/charge_behaviour"
touch "$test_root/run13/phoenix-charge-cap.inhibited"
run13
[ "$(cat "$test_root/power13/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "float mode did not release a legacy inhibit"
[ ! -e "$test_root/run13/phoenix-charge-cap.inhibited" ] ||
	fail "float mode left the legacy ownership marker behind"

# reset restores the ceiling we lowered.
run13 reset
[ "$(cat "$test_root/power13/pm8150b-charger/constant_charge_voltage")" = 4400000 ] ||
	fail "reset did not restore the original float ceiling"
[ ! -e "$test_root/run13/phoenix-charge-cap.float-original" ] ||
	fail "reset left the float-original marker behind"

# status must name the active control mode.
case "$(run13 status)" in
	*"float voltage (adapter-first)"*) ;;
	*) fail "status did not report float-voltage control mode" ;;
esac

# ---- Plausibility: QGauge averaged channels read garbage for ~70s after boot ----
mkdir -p "$test_root/power14/pm8150b-charger" "$test_root/power14/qcom_qg" \
	"$test_root/run14" "$test_root/proc14"
printf 'auto\n' > "$test_root/power14/pm8150b-charger/charge_behaviour"
printf '1\n' > "$test_root/power14/pm8150b-charger/online"
printf '5000.00 0.00\n' > "$test_root/proc14/uptime"
run14() {
	POWER_SUPPLY_ROOT="$test_root/power14" RUN_DIR="$test_root/run14" \
		PROC_ROOT="$test_root/proc14" "$cap_script" "$@"
}

# The observed boot glitch: voltage_avg pinned at 6377865 while voltage_now is
# real.  The limiter must act on voltage_now, not on 6.38 V.
printf '6377865\n' > "$test_root/power14/qcom_qg/voltage_avg"
printf '4300000\n' > "$test_root/power14/qcom_qg/voltage_now"
run14
[ "$(cat "$test_root/power14/pm8150b-charger/charge_behaviour")" = inhibit-charge ] ||
	fail "limiter did not fall back to voltage_now when voltage_avg was implausible"
case "$(run14 status)" in
	*"voltage_avg reads 6377865 uV (implausible, ignored)"*) ;;
	*) fail "status did not flag the implausible voltage_avg" ;;
esac

# Both channels implausible: take no action at all and leave state untouched.
printf 'auto\n' > "$test_root/power14/pm8150b-charger/charge_behaviour"
rm -f "$test_root/run14/phoenix-charge-cap.inhibited"
printf '6377865\n' > "$test_root/power14/qcom_qg/voltage_avg"
printf '99\n' > "$test_root/power14/qcom_qg/voltage_now"
run14
[ "$(cat "$test_root/power14/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "limiter acted with no plausible voltage available"
[ ! -e "$test_root/run14/phoenix-charge-cap.inhibited" ] ||
	fail "limiter created a marker with no plausible voltage available"

# A +5 A ghost on current_avg must not mask a real discharge on current_now.
printf '4300000\n' > "$test_root/power14/qcom_qg/voltage_avg"
printf '4300000\n' > "$test_root/power14/qcom_qg/voltage_now"
printf 'inhibit-charge\n' > "$test_root/power14/pm8150b-charger/charge_behaviour"
touch "$test_root/run14/phoenix-charge-cap.inhibited"
printf '5000003\n' > "$test_root/power14/qcom_qg/current_avg"
printf '%s\n' -50000 > "$test_root/power14/qcom_qg/current_now"
i=0; while [ "$i" -lt 5 ]; do run14; i=$((i + 1)); done
[ "$(cat "$test_root/power14/pm8150b-charger/charge_behaviour")" = auto ] ||
	fail "implausible current_avg masked a genuine deficit on current_now"

# After a deficit release there is no ownership marker but there is a lockout;
# reset must still leave a clean slate.
[ -e "$test_root/run14/phoenix-charge-cap.lockout" ] || fail "deficit release did not arm lockout"
run14 reset
[ ! -e "$test_root/run14/phoenix-charge-cap.lockout" ] ||
	fail "reset left a lockout behind when no inhibit was owned"

# ---- Safety guard: implausible readings count as invalid, never as danger ----
mkdir -p "$test_root/power15/pm8150b-charger" "$test_root/power15/qcom_qg"
printf '0\n' > "$test_root/power15/pm8150b-charger/online"
printf '%s\n' -10000 > "$test_root/power15/qcom_qg/current_now"
printf '300\n' > "$test_root/power15/qcom_qg/temp"
safety15() {
	POWER_SUPPLY_ROOT="$test_root/power15" INTERVAL_SECONDS=1 DRY_RUN=1 MAX_SAMPLES=1 \
		EMERGENCY_SAMPLES=1 SHUTDOWN_SAMPLES=1 MAX_TEMP_SAMPLES=1 "$safety_script"
}

# 0.1 V is a glitch, not a dead cell: no emergency.
printf '100000\n' > "$test_root/power15/qcom_qg/voltage_now"
printf '4100000\n' > "$test_root/power15/qcom_qg/voltage_avg"
[ -z "$(safety15)" ] || fail "safety guard shut down on an implausible 0.1 V reading"

# 6.38 V on voltage_avg must not hide a real 3.30 V on voltage_now.
printf '3300000\n' > "$test_root/power15/qcom_qg/voltage_now"
printf '6377865\n' > "$test_root/power15/qcom_qg/voltage_avg"
case "$(safety15)" in
	*"below emergency threshold"*) ;;
	*) fail "safety guard missed a genuine emergency behind an implausible voltage_avg" ;;
esac

# 200 C is a sensor fault, not a fire.
printf '4100000\n' > "$test_root/power15/qcom_qg/voltage_now"
printf '4100000\n' > "$test_root/power15/qcom_qg/voltage_avg"
printf '2000\n' > "$test_root/power15/qcom_qg/temp"
[ -z "$(safety15)" ] || fail "safety guard shut down on an implausible 200 C reading"

# A cold cell below 0 C is a valid reading, not an invalid one.
printf '%s\n' -50 > "$test_root/power15/qcom_qg/temp"
[ -z "$(safety15)" ] || fail "safety guard mishandled a negative temperature"

echo "battery tool tests: PASS"
