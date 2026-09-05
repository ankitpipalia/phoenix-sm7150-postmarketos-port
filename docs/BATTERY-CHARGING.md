# Phoenix battery and charging notes

This document records the implementation and live results for the replacement
battery installed in the Phoenix test device. It distinguishes charging safety,
capacity measurement and SOC reporting; they are separate problems on the
current mainline kernel.

## Current limitations

- The mainline `qcom_qg` driver does not expose a learned FCC, charge counter,
  cycle count or calibration state machine on this device.
- Its reported percentage is primarily voltage-derived. Load-induced voltage
  sag and recovery can therefore make percentage move without an equivalent
  change in stored charge.
- `charge_full=0` means learned capacity is unavailable. It must not be shown as
  zero-capacity or 0% state of health.
- The Phoenix DTS supplies the 4500 mAh design value, voltage bounds and a 1.5 A
  constant-charge-current limit, but not Xiaomi's battery-specific SOC/OCV and
  temperature/impedance tables.

Repeated 0-to-100% cycles cannot teach this driver a new capacity. Actual
capacity must be measured by integrating current over a controlled test.

## Charger driver changes

Patches 0007 through 0017 add an optional TCPM power-supply reference, a guarded
USB input-current fallback, hardened SMB5 control and upstream Fixes robustness
to `qcom_smbx` (0011: watchdog base, OV recovery, float off-by-one, ICL
ordering/log and revalidation; 0012: explicit 5-12 V PD acceptance with 1.5 A
and 15 W caps; 0013: corrected SMB5 override offset and AICL rerun; 0015:
trusted DCP/CDP override; 0016: continuous 5-12 V adapter allowance; 0017:
bounded retry after a transient offline status). Patch 0014 is the separate
Phoenix PS_HOLD reboot fix.

Normal BC1.2 APSD results remain authoritative for CDP and DCP. The driver keeps
the 500 mA safe default unless all relevant fallback checks pass:

- USB input is physically online.
- TCPM reports the local port online, which means the local role is a sink.
- Plain Type-C is approximately 5 V (4.75 to 5.5 V); an explicit PD contract
  may be 5-12 V, matching the connector sink PDO.
- The advertised current is at least 1.5 A.
- Charger health is `Good`.
- The request is capped to the smallest of TCPM current, 1.5 A, 15 W and the
  hardware maximum.

If APSD has completed as SDP, only a negotiated PD contract may supersede the
500 mA SDP ceiling. A plain Type-C advertisement cannot override a completed
SDP result, so an ordinary computer/data port remains limited to 500 mA.

The fallback programs high-current mode and `ICL_OVERRIDE_AFTER_APSD`, following
the downstream SMB5 mechanism. It deliberately leaves hardware AICL and
suspend-on-collapse enabled. Disconnect, loss of TCPM capability or a normal
APSD result clears the override and returns control to the safe/default path.

The driver patches also:

- read SMB5 over-voltage from status register 2 and keep status 7 for thermal
  health;
- decode the distinct SMB2 and SMB5 charge states correctly;
- correct SMB5 ICL status and prescaled input-voltage handling;
- caps fast-charge current by battery DTS data, limiting Phoenix to 1.5 A rather
  than applying the driver's previous unconditional 1.95 A request;
- logs whether an ICL came from the safe default, APSD or TCPM fallback;
- revalidate TCPM fallback policy on power-supply notifications and every 15
  seconds while active;
- make legacy `STATUS` and `CURRENT_MAX` writes read-only and always reprogram
  the policy-selected ICL; and
- expose standard `charge_behaviour=auto|inhibit-charge` without suspending the
  USB input path.

It does not itself request QC/PD voltage escalation, enable SMB1390 or a charge
pump, allow 3 A input, or use Xiaomi's downstream 5.5 A fast-charge
configuration. It only accepts an already negotiated TCPM PD contract within
the connector's declared limits.

On the September 5 dock test, firmware's discrete adapter allowance (`0x07`)
classified the dock's measured ~8.9 V passthrough as `USBIN_OV` and paused
charging. Patch 0016 programs the continuous 5-12 V allowance (`0x0c`). Live
module testing cleared `USBIN_OV`, changed the charger to full-on charging and
made battery current positive. The 1.5 A ceiling, hardware AICL, and
suspend-on-collapse remained enabled; AICL is still free to settle lower when
the dock/cable path or system load requires it.

## Live result: 2026-08-21

Test path:

```text
PD power -> powered USB-C hub -> Phoenix
                              -> USB Ethernet/storage
```

At boot, APSD initially detected DCP and requested 1.5 A. The existing
`phoenix-usb-host-wake` role toggle then brought up the hub and Ethernet; APSD
reclassified the data path as SDP and the old logic returned to 500 mA. At the
same time TCPM reported an online sink with a negotiated 5 V/2 A PD contract.

With the PD-gated SDP override loaded live:

| Observation | Result |
|---|---:|
| Driver requested ceiling | 1.5 A |
| Hardware AICL effective ceiling | 850 mA |
| Observed USB input current | about 842-845 mA |
| Observed VBUS under load | about 4.09-4.12 V |
| Battery temperature | 34.1-34.6 C |
| Battery current | mostly +97 to +171 mA, with brief -80 to -69 mA samples |
| Charger health | `Good` |

AICL reducing the request from 1.5 A to 850 mA is expected and is evidence that
electrical-path protection remains active. The battery generally gained charge,
but brief net discharge remained possible while the full hub, networking and
container load was running. No thermal rise was observed during the initial
sample window.

This validates this specific hub/charger combination only. Direct SDP, CDP,
DCP, 5 V Type-C, different PD supplies, cable collapse, disconnect/reconnect and
thermal conditions still require separate testing.

## Longer-term recheck: 2026-09-03

The replacement battery and charger were rechecked after roughly two weeks.
The logger contained 79,078 usable samples between August 20 and September 3,
with an eight-day recording gap after the device powered down on August 23.

Observed safety range:

| Observation | Result |
|---|---:|
| Battery voltage | 2.532-4.130 V |
| Samples above 4.2 V | 0 |
| Samples above 4.4 V | 0 |
| Battery temperature | 28.6-35.5 C |
| Samples at or above 40 C | 0 |
| Verified limiter failures | 0 |

The upper-voltage and thermal results show no evidence of overcharging or
overheating. At the recheck the charger reported `Good`, detected DCP and drew
about 695 mA with AICL setting an effective 700 mA ceiling. Battery current was
positive at about 95-103 mA and temperature was 33.3-33.4 C.

Two limitations became clear over the longer sample. Both now have implemented
fixes, but their hardware validation is tracked separately:

1. The voltage-derived SOC causes frequent limiter transitions. Journald held
   402 verified pauses and 423 verified resumes. On September 2 and 3, typical
   charging dwell was about 2.4 minutes and suspended dwell about 7.6-7.9
   minutes. This is shallow cycling rather than overcharging, but a future
   limiter should add minimum dwell/debounce logic instead of treating every
   instantaneous voltage-derived percentage as stable SOC.
2. On August 23 the external TCPM/charger source was offline. The device spent
   about 81 minutes below 3.4 V and reached a reported 2.532 V before logging
   stopped. This was a deep-discharge event while input power was unavailable,
   not a charging-limit or over-voltage event. Unattended installations need an
   orderly low-voltage shutdown policy in addition to the upper charge cap.

The report now integrates by monotonic uptime, segments by boot ID, and supports
both old and new headers. None of these observations is a measured battery SOH
or full capacity; that still requires a controlled charge/discharge experiment.

## Charge limiter

`phoenix-charge-cap.sh` implements voltage hysteresis at 4.00-4.10 V by writing
`auto` or `inhibit-charge` to the SMB `charge_behaviour` property. It verifies
that inhibition sticks and that USB input remains online. It refuses to run on
an old kernel instead of falling back to `STATUS`/`USBIN_SUSPEND`.

Because current SOC is voltage-derived, this limiter should be understood as a
useful voltage-correlated longevity guard, not a laboratory-accurate true-SOC
controller.

The timer remains disabled by default. Do not enable it until patch 0010 is
installed and a live upper-threshold test proves that the adapter continues to
power the system while battery current approaches zero.

## Low-voltage and temperature guard

`phoenix-battery-safety.service` independently checks voltage, discharge
current, source presence, and temperature every five seconds. Conservative
defaults request an orderly shutdown after sustained discharge at or below
3.45 V without input, after a shorter emergency condition at or below 3.35 V,
or after sustained battery temperature at or above 45 C.

The service is disabled by default. Its decision path passed a synthetic 3.30 V
dry-run test on the phone; enable it only after a controlled real source-loss
test validates thresholds and shutdown/recovery behavior.

## Telemetry and capacity measurement

Enable continuous five-second raw logging:

```sh
sudo systemctl enable --now phoenix-battery-telemetry.service
```

Logs are TSV files in `/var/log/phoenix-battery/`. They include raw battery
voltage/current/temperature, voltage-derived level, SMB charger state, effective input
limit, TCPM contract and Type-C power role. Retention and sample interval are
configured in `/etc/phoenix-battery-telemetry.conf`.

Summarize the latest file, or a named file:

```sh
phoenix-battery-report
phoenix-battery-report /var/log/phoenix-battery/telemetry-YYYY-MM-DD.tsv
```

The report uses trapezoidal integration for mAh and mWh, monotonic uptime deltas,
and boot-ID segmentation, and rejects time gaps over 30 seconds. When a legacy
same-day file exists, the collector starts a `-v2.tsv` file instead of mixing
schemas. A real replacement-battery capacity result requires a later controlled
full-to-low discharge test; the short validation window is not a capacity
measurement.

## Rollback

For a packaged kernel, remove patches 0007-0010 to return to the original
charger behavior. On the test device, the original DTB was preserved as
`sm7150-xiaomi-phoenix.pre-tcpm.dtb` and a `postmarketOS (pre-TCPM charger DT)`
loader entry was added before testing.

Do not copy Xiaomi's downstream 3 A USB ICL or 5.5 A FCC values into this port.
Those values depend on profile selection, thermal policy, six-pin sensing,
protocol negotiation and secondary charge-pump support that this mainline port
does not implement.
