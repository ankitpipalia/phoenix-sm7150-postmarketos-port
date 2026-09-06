# device-xiaomi-phoenix / extra-addon

Server-mode add-ons shipped by `device-xiaomi-phoenix`. Battery policy helpers
remain opt-in, while the panel blanker and cold-boot USB-host recovery are
enabled by default for this project's SSH-managed deployment. Files in this
directory map 1:1 into `/usr/lib/systemd/system/`, `/usr/libexec/`, and `/etc/`
at install time — see the parent `APKBUILD`'s `package()` for the exact mapping.

| Add-on | Purpose | Enable | Tune |
|---|---|---|---|
| `phoenix-charge-cap.{sh,service,timer,conf}` + `phoenix-charge-cap-reset.service` | Keeps the cell off its maximum resting voltage so the battery acts as a UPS, not a cycling store. **Float mode (preferred, kernel patch 0018):** programs `STOP_VOLTAGE_UV` as the charger's float ceiling; charging stays enabled, the charger keeps regulating, and the adapter carries the system. **Fallback (patch 0010):** `charge_behaviour=inhibit-charge` with hysteresis, used only when `constant_charge_voltage` is not writable -- on this PMIC inhibiting at a high cell voltage lets the battery feed the system, so an adapter-deficit guard releases the inhibit and logs rather than draining the cell silently. | Enable with `systemctl enable --now phoenix-charge-cap.timer`. Safely disable with `systemctl disable --now phoenix-charge-cap.timer && systemctl start phoenix-charge-cap-reset.service`; reset restores the float ceiling and only releases inhibition owned by this limiter. Check with `phoenix-charge-cap status`. | `/etc/phoenix-charge-cap.conf` (`START_VOLTAGE_UV=`, `STOP_VOLTAGE_UV=`, `DEFICIT_*`) |
| `phoenix-adapter-test.sh` | Characterises an adapter/cable/dock path: fits the source load line (open-circuit voltage and series resistance to USBIN), records the input-power ceiling, and reports net battery current at idle and under load. `R` is a property of the hardware path alone, so results taken at different battery levels stay comparable. | Run per adapter: `phoenix-adapter-test.sh --label NAME`, then `--compare`. Needs root; pauses and restores `phoenix-charge-cap.timer` for the duration. | `--idle`/`--load`/`--workers`; results in `/var/log/phoenix-adapter-tests/` |
| `phoenix-power-path-verify.sh` | Walks a matrix of load levels against charge behaviours and reports, per condition, whether the cell was idle (adapter powering the SoC directly), supplying, or charging. Settles before each measurement and cools between load steps, so results are not distorted by residual heat. | `phoenix-power-path-verify.sh --label NAME` (root; `--quick` skips the 2-core rows). Restores charge behaviour and the charge-cap timer on exit. | `--measure`/`--settle`; `IDLE_BAND_UA` sets the idle verdict band |
| `phoenix-battery-safety.{sh,service,conf}` | Independent low-voltage and high-temperature orderly-shutdown guard. Validate thresholds in dry-run mode before enabling it on a replacement battery. | `systemctl enable --now phoenix-battery-safety.service` | `/etc/phoenix-battery-safety.conf` |
| `phoenix-battery-telemetry.{sh,service,conf}` + `phoenix-battery-report.sh` | Raw five-second battery/charger/TCPM TSV logger. Reports use monotonic uptime and boot-ID segmentation for gap-safe mAh/mWh integration. | `systemctl enable --now phoenix-battery-telemetry.service` | `/etc/phoenix-battery-telemetry.conf`; run `phoenix-battery-report` for totals |
| `phoenix-screen-off.service` | Drives panel backlight to 0 + `bl_power=4` at boot. The ROM defaults to `multi-user.target`; `greetd` is disabled. | Enabled by default. | n/a |
| `phoenix-typec-recover.{sh,service,timer,conf}` | Detects "stuck as source" Type-C state after charger removal with a non-PD hub (`pd_revision=0.0`) and forces a `power_role=sink` swap. Voltage is the primary urgency signal; the voltage-derived level is used when voltage attributes are missing or invalid. | `systemctl enable --now phoenix-typec-recover.timer` | `/etc/phoenix-typec-recover.conf` (`VOLTAGE_THRESHOLD_UV=`, `CAP_THRESHOLD=`) |
| `phoenix-usb-host-wake.{sh,service}` | Cold-boot USB host wake. If `eth0` doesn't appear within 45s of `multi-user.target` (because the hub was already attached at power-on and qcom-pmic-typec never fired an attach event, leaving dwc3 unprobed), forces a `usb_role_switch` device→host toggle. Software equivalent of "unplug and replug the hub". Essential for unattended recovery after a power outage on a phone-as-server install. | Enabled by default. | n/a (45s settle, 20s recheck) |
| `phoenix-llm-manager.{py,service,conf,html,css,js}` | **Phoenix Console** on port 7070: a generic device dashboard (overview, power path with adapter/cable test results, processes with stop/kill for the console's own user, systemd services and timers, network interfaces/throughput/listening ports, storage, thermal zones + cpufreq + cooling state, system journal) plus the single llama.cpp runtime it owns (profiles, chat smoke test, runtime log). Charts are one-measure-per-canvas with a crosshair tooltip, range/smooth controls and a validated three-slot series palette. Stdlib Python + vanilla JS, no CDN. | Enabled by default; the runtime needs the custom `LLAMA_SERVER` binary before a model can start. | `/etc/phoenix-llm-manager.conf`; **set `API_TOKEN` on untrusted networks** — every mutation (runtime start/stop, process signals) is otherwise open to the LAN |

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
