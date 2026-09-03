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

echo "battery tool tests: PASS"
