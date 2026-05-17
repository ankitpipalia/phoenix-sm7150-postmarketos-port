#!/bin/sh
# phoenix-usb-host-wake: software-equivalent of "unplug + replug the hub"
# after a cold boot.
#
# On phoenix the dwc3 USB controller doesn't probe the xHCI host stack at
# cold boot when a Type-C hub is already attached at power-on — there is
# no CC-line rising-edge for the qcom-pmic-typec stack to fire, and the
# usb_role_switch stays in whatever role the bootloader left it in.
# Result: /sys/class/net/eth0 never appears unless the user physically
# unplugs and replugs the hub, which is impossible during an unattended
# power-outage recovery on a home server.
#
# The kernel exposes /sys/class/usb_role/<usb-ctrl>-role-switch/role for
# exactly this. Writing "device" tears down the host stack; writing
# "host" re-runs the dwc3 probe chain, which enumerates the hub and its
# downstream USB-Ethernet adapter, registering eth0 again.
#
# This service waits a generous settle window (default 45 s) for eth0 to
# appear naturally — the good case where typec did fire correctly. Only
# if eth0 is still missing does it perform the device→host toggle.
# Idempotent and cheap; safe to leave WantedBy=multi-user.target.
set -eu

ROLE_FILE=/sys/class/usb_role/a600000.usb-role-switch/role
IFNAME=eth0
SETTLE_SEC=45
RECHECK_SEC=20
NM_CONNECTION="Ethernet via Hub"

[ -e /etc/phoenix-usb-host-wake.conf ] && . /etc/phoenix-usb-host-wake.conf

# Bail cleanly if the role switch doesn't exist (different kernel / device).
[ -w "$ROLE_FILE" ] || { logger -t phoenix-usb-host-wake "role file not writable, exiting"; exit 0; }

# Phase 1: settle wait — give the kernel/NM a chance to bring eth0 up
# without our intervention.
i=0
while [ $i -lt $SETTLE_SEC ]; do
    if [ -e /sys/class/net/$IFNAME ]; then
        logger -t phoenix-usb-host-wake "$IFNAME present after ${i}s settle — no toggle needed"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

# Phase 2: force a role switch round-trip
logger -t phoenix-usb-host-wake "$IFNAME missing after ${SETTLE_SEC}s, toggling usb_role_switch"
echo device > "$ROLE_FILE" 2>/dev/null || true
sleep 3
echo host > "$ROLE_FILE" 2>/dev/null || true

# Phase 3: wait for eth0 to re-appear (xHCI probe + hub enum + cdc_ether bind)
i=0
while [ $i -lt $RECHECK_SEC ]; do
    if [ -e /sys/class/net/$IFNAME ]; then
        logger -t phoenix-usb-host-wake "$IFNAME up after role toggle (took ${i}s)"
        # Nudge NM in case its initial scan finished before the device
        # appeared. nmcli is a no-op if the connection is already active.
        nmcli connection up "$NM_CONNECTION" >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

logger -t phoenix-usb-host-wake "FAILED: $IFNAME still missing after role toggle — check hub / cable"
exit 0
