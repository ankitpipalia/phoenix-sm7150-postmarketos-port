#!/bin/sh
# Characterise a USB-C adapter/cable/dock path on Phoenix.
#
# The figure of merit for an always-powered server is not "how fast does it
# charge" -- that depends on how full the cell already is -- but how much
# current the path can deliver before its voltage collapses.  So the primary
# result here is a load-line fit: open-circuit voltage and series resistance
# between the source and the PMIC's USBIN sense point.  That number is a
# property of the adapter, cable and connectors alone, and is directly
# comparable between runs taken at different battery levels.
set -eu

LABEL=""
IDLE_SECONDS=${IDLE_SECONDS:-45}
LOAD_SECONDS=${LOAD_SECONDS:-20}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-2}
LOAD_WORKERS=${LOAD_WORKERS:-2}
ABORT_TEMP_C=${ABORT_TEMP_C:-85}
COOL_TEMP_C=${COOL_TEMP_C:-60}
COOL_WAIT_S=${COOL_WAIT_S:-180}
DELAY_SECONDS=${DELAY_SECONDS:-0}
RESULT_DIR=${RESULT_DIR:-/var/log/phoenix-adapter-tests}
POWER_SUPPLY_ROOT=${POWER_SUPPLY_ROOT:-/sys/class/power_supply}
TYPEC_ROOT=${TYPEC_ROOT:-/sys/class/typec}
THERMAL_ROOT=${THERMAL_ROOT:-/sys/class/thermal}

usage() {
	cat <<'EOF'
usage: phoenix-adapter-test.sh --label NAME [--idle N] [--load N]
                              [--workers N] [--delay N] [--no-load]
       phoenix-adapter-test.sh --compare
       phoenix-adapter-test.sh --list

Run once per adapter/cable/dock combination, then --compare.

--delay N waits N seconds before starting.  Use it when the adapter under test
replaces the dock that carries your SSH session: launch detached, swap while it
waits, and read the result after reconnecting.

  nohup phoenix-adapter-test.sh --delay 60 --label pd-direct >/dev/null 2>&1 &

Key results:
  Voc / R       source open-circuit voltage and series resistance.  R below
                about 0.3 ohm is a healthy path; around 1 ohm means a thin or
                damaged cable, a dirty connector, or a lossy dock.
  max input W   most power the path actually delivered before collapsing.
  battery mA    net cell current; positive means the adapter covered the whole
                system load and had headroom left over.
EOF
}

no_load=0
compare=0
list=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--label) LABEL=${2:-}; shift 2 ;;
		--idle) IDLE_SECONDS=${2:-}; shift 2 ;;
		--load) LOAD_SECONDS=${2:-}; shift 2 ;;
		--workers) LOAD_WORKERS=${2:-}; shift 2 ;;
		--delay) DELAY_SECONDS=${2:-}; shift 2 ;;
		--no-load) no_load=1; shift ;;
		--compare) compare=1; shift ;;
		--list) list=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

charger="$POWER_SUPPLY_ROOT/pm8150b-charger"
gauge="$POWER_SUPPLY_ROOT/qcom_qg"
behaviour="$charger/charge_behaviour"

valid_uint() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

read_first() {
	cat "$1" 2>/dev/null | head -1 || true
}

selected() {
	# "auto [inhibit-charge]" -> inhibit-charge; plain values pass through.
	_raw=$(read_first "$1")
	case "$_raw" in
		*"["*"]"*) printf '%s\n' "${_raw#*[}" | sed 's/].*//' ;;
		*) printf '%s\n' "$_raw" ;;
	esac
}

hottest_c() {
	_max=0
	for _z in "$THERMAL_ROOT"/thermal_zone*/temp; do
		[ -r "$_z" ] || continue
		_t=$(read_first "$_z")
		valid_uint "$_t" || continue
		_t=$((_t / 1000))
		[ "$_t" -gt "$_max" ] && _max=$_t
	done
	printf '%s\n' "$_max"
}

summarise() {
	# stdin: phase<TAB>vin_uv<TAB>iin_ua<TAB>icl_ua<TAB>ibat_ua<TAB>vbat_uv<TAB>temp_c
	# $1 = reference open-circuit voltage in volts, for the pinned-ICL estimate.
	awk -F'\t' -v vref="$1" '
	{
		ph=$1; vin=$2/1e6; iin=$3/1e6; icl=$4/1000; ibat=$5/1000
		n[ph]++
		pin[ph]+=vin*iin; bat[ph]+=ibat; tsum[ph]+=$7
		if (vin*iin > pmax[ph]) pmax[ph]=vin*iin
		if (icl<=50) floor[ph]++
		steps[ph","icl]=1
		# load-line accumulators over every sample, both phases
		N++; SX+=iin; SY+=vin; SXX+=iin*iin; SXY+=iin*vin
		if (iin>imax) imax=iin
		if (N==1 || iin<imin) imin=iin
		# Single-point estimate; valid for ranking cables on one adapter.
		if (iin > 0.15) { RE += (vref - vin)/iin; REN++ }
	}
	END {
		split("idle load", order, " ")
		for (o=1; o<=2; o++) {
			ph=order[o]
			if (!(ph in n)) continue
			c=0; for (k in steps) { split(k,a,","); if (a[1]==ph) c++ }
			printf "PHASE\t%s\t%d\t%.3f\t%.3f\t%+.1f\t%.0f\t%.0f\t%d\n",
				ph, n[ph], pin[ph]/n[ph], pmax[ph], bat[ph]/n[ph],
				100*floor[ph]/n[ph], tsum[ph]/n[ph], c
		}
		den = N*SXX - SX*SX
		spread = imax - imin
		rest = (REN >= 3) ? sprintf("%.3f", RE/REN) : "NA"
		if (N >= 4 && den > 1e-9 && spread >= 0.05) {
			slope = (N*SXY - SX*SY)/den
			icept = (SY - slope*SX)/N
			printf "FIT\t%.3f\t%.3f\t%.3f\t%d\t%s\n", icept, -slope, spread, N, rest
		} else {
			printf "FIT\tNA\tNA\t%.3f\t%d\t%s\n", spread, N, rest
		}
	}'
}

if [ "$list" -eq 1 ] || [ "$compare" -eq 1 ]; then
	if [ ! -d "$RESULT_DIR" ] || [ -z "$(ls -A "$RESULT_DIR" 2>/dev/null)" ]; then
		echo "no adapter results recorded yet in $RESULT_DIR"
		exit 0
	fi
	if [ "$list" -eq 1 ]; then
		ls -1 "$RESULT_DIR"/*.result 2>/dev/null | sed 's|.*/||; s|\.result$||'
		exit 0
	fi
	printf '%-22s %-9s %-7s %-7s %-8s %-8s %-9s %s\n' \
		LABEL SOURCE 'Voc(V)' 'R(ohm)' 'maxW' 'idle_mA' 'load_mA' VERDICT
	for _f in "$RESULT_DIR"/*.result; do
		[ -f "$_f" ] || continue
		# shellcheck disable=SC1090
		. "$_f"
		printf '%-22s %-9s %-7s %-7s %-8s %-8s %-9s %s\n' \
			"$R_LABEL" "$R_SOURCE" "$R_VOC" "$R_RES" "$R_MAXW" \
			"$R_IDLE_MA" "$R_LOAD_MA" "$R_VERDICT${R_RES_KIND:+ ($R_RES_KIND)}"
	done
	exit 0
fi

[ -n "$LABEL" ] || { echo "--label is required (name the adapter/cable)" >&2; exit 2; }
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "--label: use only A-Za-z0-9._-" >&2; exit 2 ;; esac
for _v in "$IDLE_SECONDS" "$LOAD_SECONDS" "$SAMPLE_SECONDS" "$LOAD_WORKERS" "$DELAY_SECONDS"; do
	valid_uint "$_v" || { echo "numeric options must be unsigned integers" >&2; exit 2; }
done
[ "$SAMPLE_SECONDS" -ge 1 ] || { echo "--sample must be >= 1" >&2; exit 2; }

if [ "$DELAY_SECONDS" -gt 0 ]; then
	echo "waiting ${DELAY_SECONDS}s before starting -- swap the adapter now"
	sleep "$DELAY_SECONDS"
fi

if [ "$(read_first "$charger/online")" != "1" ]; then
	echo "charger reports offline -- plug the adapter in first" >&2
	exit 1
fi

# The charger must be free to draw, or the path never gets loaded and the fit
# has no spread.  Pause the limiter for the duration and always restore it.
timer_was_active=0
if command -v systemctl >/dev/null 2>&1 &&
   systemctl is-active --quiet phoenix-charge-cap.timer 2>/dev/null; then
	timer_was_active=1
fi

cleanup() {
	trap - EXIT HUP INT TERM
	kill $load_pids 2>/dev/null || true
	wait 2>/dev/null || true
	if [ "$timer_was_active" -eq 1 ]; then
		systemctl start phoenix-charge-cap.timer 2>/dev/null || true
	fi
}
load_pids=""
trap 'cleanup' EXIT HUP INT TERM

if [ "$timer_was_active" -eq 1 ]; then
	systemctl stop phoenix-charge-cap.timer 2>/dev/null || true
fi
if [ "$(selected "$behaviour")" = "inhibit-charge" ]; then
	printf '%s\n' auto > "$behaviour" 2>/dev/null || true
	rm -f /run/phoenix-charge-cap.inhibited /run/phoenix-charge-cap.deficit \
		/run/phoenix-charge-cap.lockout 2>/dev/null || true
	sleep 2
fi
if [ "$(selected "$behaviour")" != "auto" ]; then
	echo "could not put the charger in auto; run as root" >&2
	exit 1
fi

mkdir -p "$RESULT_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
raw="$RESULT_DIR/$stamp-$LABEL.tsv"
: > "$raw"

# Static source description, captured once.
tcpm=""
for _t in "$POWER_SUPPLY_ROOT"/tcpm-source-psy-*; do
	[ -d "$_t" ] && { tcpm=$_t; break; }
done
usb_type=$(selected "$charger/usb_type")
pd_rev=$(read_first "$TYPEC_ROOT/port0-partner/usb_power_delivery_revision")
[ -n "$pd_rev" ] || pd_rev="none"
tcpm_v=$(read_first "$tcpm/voltage_now")
tcpm_i=$(read_first "$tcpm/current_max")
valid_uint "$tcpm_v" || tcpm_v=0
valid_uint "$tcpm_i" || tcpm_i=0
vbat_start=$(read_first "$gauge/voltage_avg")
temp_start=$(hottest_c)

valid_uint "$vbat_start" || vbat_start=0

if [ "$tcpm_v" -gt 5500000 ]; then
	source_desc="PD$((tcpm_v / 1000000))V"
elif [ "$pd_rev" != "none" ] && [ "$pd_rev" != "0.0" ]; then
	source_desc="PD5V"
else
	source_desc="$usb_type"
fi
# APSD can fail to classify a source (usb_type reads empty); say so rather than
# leaving a blank column in the comparison table.
[ -n "$source_desc" ] || source_desc=unresolved

echo "Adapter test: $LABEL"
echo "  source     : $source_desc  (usb_type=$usb_type pd_revision=$pd_rev)"
echo "  TCPM offer : $((tcpm_v / 1000)) mV x $((tcpm_i / 1000)) mA"
echo "  battery    : $((vbat_start / 1000)) mV at start"
echo "  phases     : ${IDLE_SECONDS}s idle + $([ "$no_load" -eq 1 ] && echo "no load" || echo "${LOAD_SECONDS}s load (${LOAD_WORKERS} workers)")"
echo

sample_phase() {
	_phase=$1; _dur=$2; _end=$(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) + _dur ))
	while [ "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)" -lt "$_end" ]; do
		_t=$(hottest_c)
		if [ "$_phase" = load ] && [ "$_t" -ge "$ABORT_TEMP_C" ]; then
			echo "  ..  load phase stopped early at ${_t} C (expected on this SoC; the input ceiling is already resolved)"
			return 1
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_phase" \
			"$(read_first "$charger/voltage_now")" \
			"$(read_first "$charger/current_now")" \
			"$(read_first "$charger/current_max")" \
			"$(read_first "$gauge/current_now")" \
			"$(read_first "$gauge/voltage_avg")" \
			"$_t" >> "$raw"
		sleep "$SAMPLE_SECONDS"
	done
	return 0
}

echo "  [1/2] idle  ${IDLE_SECONDS}s ..."
sample_phase idle "$IDLE_SECONDS" || true

if [ "$no_load" -eq 0 ]; then
	_t=$(hottest_c)
	if [ "$_t" -ge "$COOL_TEMP_C" ]; then
		echo "  ...  cooling from ${_t} C to below ${COOL_TEMP_C} C (max ${COOL_WAIT_S}s)"
		_deadline=$(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) + COOL_WAIT_S ))
		while [ "$(hottest_c)" -ge "$COOL_TEMP_C" ] &&
		      [ "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)" -lt "$_deadline" ]; do
			sleep 5
		done
		echo "  ...  starting load at $(hottest_c) C"
	fi
	echo "  [2/2] load  ${LOAD_SECONDS}s ..."
	_i=0
	while [ "$_i" -lt "$LOAD_WORKERS" ]; do
		dd if=/dev/zero of=/dev/null bs=1M >/dev/null 2>&1 &
		load_pids="$load_pids $!"
		_i=$((_i + 1))
	done
	sample_phase load "$LOAD_SECONDS" || true
	kill $load_pids 2>/dev/null || true
	wait 2>/dev/null || true
	load_pids=""
fi

# Drop any row with a missing or physically impossible field before analysis.
# Bounds admit 5-12 V PD input and a 3.4-4.4 V cell; anything outside is a
# QGauge/ADC glitch and one 6.38 V row would wreck the least-squares fit.
vref=$(awk -v v="$tcpm_v" 'BEGIN{ printf "%.3f", (v>=4000000 ? v/1e6 : 5.0) }')
rows_total=$(wc -l < "$raw" | tr -d ' ')
analysis=$(awk -F'\t' 'NF==7 && $2!="" && $3!="" && $4!="" && $5!="" && $6!="" && $7!="" &&
	$2>=3000000 && $2<=13000000 && $3>=0 && $3<=5000000 &&
	$5>=-3000000 && $5<=3000000 && $6>=2500000 && $6<=4800000' "$raw" | tee "$raw.clean" | summarise "$vref")
rows_used=$(wc -l < "$raw.clean" | tr -d ' '); rm -f "$raw.clean"
[ "$rows_used" -eq "$rows_total" ] ||
	echo "  note      : dropped $((rows_total - rows_used)) of $rows_total samples as implausible" 

idle_ma=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="PHASE" && $2=="idle"{print $6}')
load_ma=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="PHASE" && $2=="load"{print $6}')
maxw=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="PHASE"{if($5>m)m=$5}END{printf "%.2f", m}')
voc=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="FIT"{print $2}')
res=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="FIT"{print $3}')
res_est=$(printf '%s\n' "$analysis" | awk -F'\t' '$1=="FIT"{print $6}')
# A pinned ICL leaves no spread to fit, but the single-point estimate still
# ranks cables on the same adapter, so fall back to it and mark it as such.
res_kind=fit
if [ "$res" = "NA" ] && [ "${res_est:-NA}" != "NA" ]; then
	res=$res_est
	res_kind=est
fi
[ -n "$idle_ma" ] || idle_ma="NA"
[ -n "$load_ma" ] || load_ma="NA"

printf '%s\n' "$analysis" | awk -F'\t' '
$1=="PHASE"{printf "  %-5s n=%-3d  mean in %.3f W  peak %.3f W  battery %+.1f mA  at 50mA floor %s%%  ICL steps %d  %s C\n", $2,$3,$4,$5,$6,$7,$9,$8}
$1=="FIT" && $2!="NA"{printf "\n  load line : Voc %.3f V   R %.3f ohm   (current spread %.3f A, n=%d)\n", $2,$3,$4,$5}
$1=="FIT" && $2=="NA" && $6!="NA"{printf "\n  load line : ICL pinned, no spread to fit (%.3f A over %d samples)\n              R ~ %s ohm estimated against a %s V nominal source\n", $4,$5,$6,vr}
$1=="FIT" && $2=="NA" && $6=="NA"{printf "\n  load line : not resolvable (current spread only %.3f A over %d samples)\n", $4,$5}' vr="$vref"

verdict="UNKNOWN"
case "$res" in
	NA|"") verdict="NO-FIT" ;;
	*) verdict=$(awk -v r="$res" -v l="$load_ma" 'BEGIN{
		if (r+0 <= 0) { print "NO-FIT"; exit }
		if (r < 0.30) q="GOOD"; else if (r < 0.60) q="FAIR"; else q="POOR";
		if (l != "NA" && l+0 < -20) q=q"/DEFICIT";
		print q }') ;;
esac

cat > "$RESULT_DIR/$stamp-$LABEL.result" <<EOF
R_LABEL='$LABEL'
R_STAMP='$stamp'
R_SOURCE='$source_desc'
R_USB_TYPE='$usb_type'
R_PD_REV='$pd_rev'
R_VOC='${voc:-NA}'
R_RES='${res:-NA}'
R_RES_KIND='$res_kind'
R_MAXW='$maxw'
R_IDLE_MA='$idle_ma'
R_LOAD_MA='$load_ma'
R_VBAT_START='$vbat_start'
R_TEMP_START='$temp_start'
R_VERDICT='$verdict'
EOF

echo
echo "  verdict   : $verdict"
echo "  raw       : $raw"
echo
echo "Compare all recorded adapters with: phoenix-adapter-test.sh --compare"
