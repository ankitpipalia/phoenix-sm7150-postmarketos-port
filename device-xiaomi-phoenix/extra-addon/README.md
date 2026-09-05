# device-xiaomi-phoenix / extra-addon

Server-mode add-ons shipped by `device-xiaomi-phoenix`. Battery policy helpers
remain opt-in, while the panel blanker and cold-boot USB-host recovery are
enabled by default for this project's SSH-managed deployment. Files in this
directory map 1:1 into `/usr/lib/systemd/system/`, `/usr/libexec/`, and `/etc/`
at install time — see the parent `APKBUILD`'s `package()` for the exact mapping.

| Add-on | Purpose | Enable | Tune |
|---|---|---|---|
| `phoenix-charge-cap.{sh,service,timer,conf}` + `phoenix-charge-cap-reset.service` | Voltage-based hysteresis limiter using `charge_behaviour=inhibit-charge`; USB input stays online while battery charging is inhibited. Requires kernel patch 0010. | Enable with `systemctl enable --now phoenix-charge-cap.timer`. Safely disable with `systemctl disable --now phoenix-charge-cap.timer && systemctl start phoenix-charge-cap-reset.service`; reset only releases inhibition owned by this limiter. | `/etc/phoenix-charge-cap.conf` (`START_VOLTAGE_UV=`, `STOP_VOLTAGE_UV=`) |
| `phoenix-battery-safety.{sh,service,conf}` | Independent low-voltage and high-temperature orderly-shutdown guard. Validate thresholds in dry-run mode before enabling it on a replacement battery. | `systemctl enable --now phoenix-battery-safety.service` | `/etc/phoenix-battery-safety.conf` |
| `phoenix-battery-telemetry.{sh,service,conf}` + `phoenix-battery-report.sh` | Raw five-second battery/charger/TCPM TSV logger. Reports use monotonic uptime and boot-ID segmentation for gap-safe mAh/mWh integration. | `systemctl enable --now phoenix-battery-telemetry.service` | `/etc/phoenix-battery-telemetry.conf`; run `phoenix-battery-report` for totals |
| `phoenix-screen-off.service` | Drives panel backlight to 0 + `bl_power=4` at boot. The ROM defaults to `multi-user.target`; `greetd` is disabled. | Enabled by default. | n/a |
| `phoenix-typec-recover.{sh,service,timer,conf}` | Detects "stuck as source" Type-C state after charger removal with a non-PD hub (`pd_revision=0.0`) and forces a `power_role=sink` swap. Voltage is the primary urgency signal; the voltage-derived level is used when voltage attributes are missing or invalid. | `systemctl enable --now phoenix-typec-recover.timer` | `/etc/phoenix-typec-recover.conf` (`VOLTAGE_THRESHOLD_UV=`, `CAP_THRESHOLD=`) |
| `phoenix-usb-host-wake.{sh,service}` | Cold-boot USB host wake. If `eth0` doesn't appear within 45s of `multi-user.target` (because the hub was already attached at power-on and qcom-pmic-typec never fired an attach event, leaving dwc3 unprobed), forces a `usb_role_switch` device→host toggle. Software equivalent of "unplug and replug the hub". Essential for unattended recovery after a power outage on a phone-as-server install. | Enabled by default. | n/a (45s settle, 20s recheck) |

## Why these are opt-in (and not in `90-phoenix-wlan-mac.preset`)

The charge cap, battery shutdown guard, telemetry logger, and Type-C sink
recovery remain policy choices and therefore stay disabled until explicitly
enabled. The display blanker and dock host recovery are different: this ROM is
specifically built as a headless server, so they are enabled by default.

## Why a separate directory

Two reasons:
1. `extra-addon/` flags the opt-in status at the filesystem level so a future maintainer can't accidentally drop one of these into `90-phoenix-wlan-mac.preset` without realising it's a behavioural toggle.
2. `device-xiaomi-phoenix/extra-addon/` is a clean place to grow with new server-mode tooling (e.g. a `phoenix-portfolio.service` Docker compose unit, a watchdog, etc.) without expanding the main package source listing.

`abuild` resolves `extra-addon/<file>` paths in `source=` relative to `$startdir`, and the resulting fetched file lands at `$srcdir/<basename>` — so the rest of the build (install commands, `sha512sums`) treats them as flat names with no special handling.
