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

case "$STOP:$START" in
    *[!0-9:]*|:*|*:) logger -p daemon.err -t phoenix-charge-cap "invalid STOP/START configuration"; exit 1 ;;
esac
if [ "$STOP" -gt 100 ] || [ "$START" -gt "$STOP" ]; then
    logger -p daemon.err -t phoenix-charge-cap \
        "invalid thresholds: require 0 <= START <= STOP <= 100"
    exit 1
fi

charger=/sys/class/power_supply/pm8150b-charger
gauge=/sys/class/power_supply/qcom_qg
state=/run/phoenix-charge-cap.paused

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
    if ! printf '%s\n' Unknown > "$charger/status" 2>/dev/null; then
        logger -p daemon.err -t phoenix-charge-cap \
            "FAILED to request pause at ${cap}% (stop=${STOP})"
        exit 1
    fi

    # A successful USBIN suspend makes the SMB power path report offline.
    online=$(cat "$charger/online" 2>/dev/null || echo 1)
    if [ "$online" != "0" ]; then
        logger -p daemon.err -t phoenix-charge-cap \
            "pause write did not suspend USB input at ${cap}% (online=${online})"
        exit 1
    fi

    : > "$state"
    logger -t phoenix-charge-cap \
        "paused charging at ${cap}% (stop=${STOP}, verified online=0)"
elif [ "$cap" -le "$START" ] && [ "$status" != "Charging" ]; then
    # Resume a pause created by us. Also recover a pre-upgrade pause for which
    # /run has no state file, but only when TCPM still proves a source is present
    # and the SMB input is offline.
    online=$(cat "$charger/online" 2>/dev/null || echo 1)
    [ -e "$state" ] || [ "$online" = "0" ] || exit 0

    if ! printf '%s\n' Charging > "$charger/status" 2>/dev/null; then
        logger -p daemon.err -t phoenix-charge-cap \
            "FAILED to request resume at ${cap}% (start=${START})"
        exit 1
    fi

    online=$(cat "$charger/online" 2>/dev/null || echo 0)
    new_status=$(cat "$charger/status" 2>/dev/null || echo Unknown)
    if [ "$online" != "1" ]; then
        logger -p daemon.err -t phoenix-charge-cap \
            "resume write did not restore USB input at ${cap}% (status=${new_status})"
        exit 1
    fi

    rm -f "$state"
    logger -t phoenix-charge-cap \
        "resumed charging at ${cap}% (start=${START}, verified online=1, status=${new_status})"
fi
