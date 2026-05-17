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
# Guarded by capacity threshold (default 30%) so the normal in-band 60-70%
# charge-cap cycle never triggers this. It is purely a low-battery rescue.
set -eu

CAP_THRESHOLD=30
[ -r /etc/phoenix-typec-recover.conf ] && . /etc/phoenix-typec-recover.conf

charger=/sys/class/power_supply/pm8150b-charger
qg=/sys/class/power_supply/qcom_qg
typec=/sys/class/typec/port0

[ -e "$typec/power_role" ] || exit 0
[ -e "$charger/online" ] || exit 0
[ -e "$charger/status" ] || exit 0
[ -e "$qg/capacity" ] || exit 0
[ -d "/sys/class/typec/port0-partner" ] || exit 0

# Capacity gate: never run during normal charge-cap operation.
cap=$(cat "$qg/capacity" 2>/dev/null || echo 100)
case "$cap" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$cap" -lt "$CAP_THRESHOLD" ] || exit 0

# Only act when we are actually stuck-as-source.
pr=$(cat "$typec/power_role" 2>/dev/null || echo "")
case "$pr" in
    *"[source]"*) ;;
    *) exit 0 ;;
esac

[ "$(cat $charger/online 2>/dev/null)" = "0" ] || exit 0
[ "$(cat $charger/status 2>/dev/null)" = "Discharging" ] || exit 0

# Attempt: swap to sink and observe.
echo sink > "$typec/power_role" 2>/dev/null || exit 0
sleep 3

new_online=$(cat $charger/online 2>/dev/null || echo 0)
new_status=$(cat $charger/status 2>/dev/null || echo Unknown)
if [ "$new_online" = "1" ] || [ "$new_status" = "Charging" ]; then
    logger -t phoenix-typec-recover \
        "recovered to sink at ${cap}% (external power detected after manual swap)"
    exit 0
fi

# No external power on the other side — restore source so the hub keeps VBUS.
echo source > "$typec/power_role" 2>/dev/null || true
logger -t phoenix-typec-recover \
    "no external power at ${cap}% — reverted to source (hub still attached)"
