# device-xiaomi-phoenix / extra-addon

Optional server-mode add-ons shipped by `device-xiaomi-phoenix` but **not enabled by default**. Each one targets a specific 24/7 / headless / phone-as-server use case. Files in this directory map 1:1 into `/usr/lib/systemd/system/`, `/usr/libexec/`, and `/etc/` at install time — see the parent `APKBUILD`'s `package()` for the exact mapping. Defaults are tuned for "charger always plugged via Type-C hub, Ethernet from the hub, screen off, no phosh".

| Add-on | Purpose | Enable | Tune |
|---|---|---|---|
| `phoenix-charge-cap.{sh,service,timer,conf}` | Hysteresis charge limiter: pauses charging at 70 %, resumes at 60 %. Pauses via `USBIN_SUSPEND_BIT` so USB data path stays alive. | `systemctl enable --now phoenix-charge-cap.timer` | `/etc/phoenix-charge-cap.conf` (`STOP=`, `START=`) |
| `phoenix-screen-off.service` | Drives panel backlight to 0 + `bl_power=4` at boot. For `multi-user.target` installs (no phosh) where the framebuffer console keeps the panel lit otherwise. | `systemctl enable --now phoenix-screen-off.service` | n/a |
| `phoenix-typec-recover.{sh,service,timer,conf}` | Detects "stuck as source" typec state after charger removal with a non-PD hub (`pd_revision=0.0`), forces a `power_role=sink` swap. Only fires when `capacity < 30 %` so it never trips during normal charge-cap operation. | `systemctl enable --now phoenix-typec-recover.timer` | `/etc/phoenix-typec-recover.conf` (`CAP_THRESHOLD=`) |
| `phoenix-usb-host-wake.{sh,service}` | Cold-boot USB host wake. If `eth0` doesn't appear within 45s of `multi-user.target` (because the hub was already attached at power-on and qcom-pmic-typec never fired an attach event, leaving dwc3 unprobed), forces a `usb_role_switch` device→host toggle. Software equivalent of "unplug and replug the hub". Essential for unattended recovery after a power outage on a phone-as-server install. | `systemctl enable phoenix-usb-host-wake.service` | n/a (45s settle, 20s recheck — edit script if you really need to change) |

## Why these are opt-in (and not in `90-phoenix-wlan-mac.preset`)

`adsp-disable-recovery.service` and `phoenix-wlan-mac.service` (in the package's main directory) are enabled via preset because their absence breaks daily-driver use too. The add-ons here are **policy choices** — capping charging shortens runtime if the device is treated as a phone, blanking the screen is wrong if phosh is wanted, and forcing typec sink would surprise someone using the phone to charge another device. Default-off keeps the device package honest as a daily-driver port; opting in is a one-line `systemctl enable` for the server use case.

## Why a separate directory

Two reasons:
1. `extra-addon/` flags the opt-in status at the filesystem level so a future maintainer can't accidentally drop one of these into `90-phoenix-wlan-mac.preset` without realising it's a behavioural toggle.
2. `device-xiaomi-phoenix/extra-addon/` is a clean place to grow with new server-mode tooling (e.g. a `phoenix-portfolio.service` Docker compose unit, a watchdog, etc.) without expanding the main package source listing.

`abuild` resolves `extra-addon/<file>` paths in `source=` relative to `$startdir`, and the resulting fetched file lands at `$srcdir/<basename>` — so the rest of the build (install commands, `sha512sums`) treats them as flat names with no special handling.
