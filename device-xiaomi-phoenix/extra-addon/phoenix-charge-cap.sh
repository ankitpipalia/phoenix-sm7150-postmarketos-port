#!/bin/sh
# phoenix-charge-cap: hysteresis-based charge limiter for 24/7 server use.
#
# Pauses charging (USBIN_SUSPEND_BIT) when battery reaches STOP threshold,
# resumes when it falls below START threshold. Run periodically by a
# systemd timer; idempotent and cheap.
#
# Plugged-in detection uses the Type-C source psy's `online`, not the SMB
# charger's `online`. Writing USBIN_SUSPEND_BIT (via status=Unknown) flips
# the charger's online flag to 0, so checking charger.online would
# self-lock the cap in "paused" state forever once it triggered.
#
# Config file: /etc/phoenix-charge-cap.conf  (optional)
#   STOP=70
#   START=60
set -eu

STOP=70
START=60
[ -r /etc/phoenix-charge-cap.conf ] && . /etc/phoenix-charge-cap.conf
[ -r /etc/default/phoenix-charge-cap ] && . /etc/default/phoenix-charge-cap

charger=/sys/class/power_supply/pm8150b-charger
gauge=/sys/class/power_supply/qcom_qg

[ -e "$charger/status" ] || exit 0
[ -e "$gauge/capacity" ] || exit 0

cap=$(cat "$gauge/capacity" 2>/dev/null || echo "")
status=$(cat "$charger/status" 2>/dev/null || echo Unknown)

case "$cap" in
  ''|*[!0-9]*) exit 0 ;;
esac

# A USB-PD source is connected iff the typec source psy reports online=1.
# Fall back to "any tcpm-source-psy with online=1" so we don't hard-code
# the c440000.spmi:pmic@0:typec@1500 path.
plugged=0
for f in /sys/class/power_supply/tcpm-source-psy-*/online; do
    [ -r "$f" ] || continue
    [ "$(cat "$f")" = "1" ] && { plugged=1; break; }
done
# Belt-and-braces: if any IIO ADC reports VBUS above 4 V, treat as plugged.
if [ "$plugged" = "0" ]; then
    for f in /sys/bus/iio/devices/iio:device*/in_voltage_usb_in_v_div_16_input; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null || echo 0)
        [ "$v" -gt 4000000 ] 2>/dev/null && { plugged=1; break; }
    done
fi

[ "$plugged" = "1" ] || exit 0

# Hysteresis. "Unknown" status write -> USBIN_SUSPEND_BIT set ("paused").
# "Charging" -> USBIN_SUSPEND_BIT cleared.
if [ "$cap" -ge "$STOP" ] && [ "$status" = "Charging" ]; then
    echo Unknown > "$charger/status" 2>/dev/null || true
    logger -t phoenix-charge-cap "paused charging at ${cap}% (stop=${STOP})"
elif [ "$cap" -le "$START" ] && [ "$status" != "Charging" ]; then
    echo Charging > "$charger/status" 2>/dev/null || true
    logger -t phoenix-charge-cap "resumed charging at ${cap}% (start=${START})"
fi
