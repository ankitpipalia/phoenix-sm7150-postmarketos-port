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

Patches 0007 through 0009 add an optional TCPM power-supply reference and a
guarded USB input-current fallback to `qcom_smbx`.

Normal BC1.2 APSD results remain authoritative for CDP and DCP. The driver keeps
the 500 mA safe default unless all relevant fallback checks pass:

- USB input is physically online.
- TCPM reports the local port online, which means the local role is a sink.
- TCPM reports Type-C/PD at approximately 5 V (4.75 to 5.5 V).
- The advertised current is at least 1.5 A.
- Charger health is `Good`.
- The request is capped to the smallest of TCPM current, 1.5 A and the hardware
  maximum.

If APSD has completed as SDP, only a negotiated PD contract may supersede the
500 mA SDP ceiling. A plain Type-C advertisement cannot override a completed
SDP result, so an ordinary computer/data port remains limited to 500 mA.

The fallback programs high-current mode and `ICL_OVERRIDE_AFTER_APSD`, following
the downstream SMB5 mechanism. It deliberately leaves hardware AICL and
suspend-on-collapse enabled. Disconnect, loss of TCPM capability or a normal
APSD result clears the override and returns control to the safe/default path.

The same driver patch also:

- fixes the over-voltage status test to mask the register value, not its address;
- caps fast-charge current by battery DTS data, limiting Phoenix to 1.5 A rather
  than applying the driver's previous unconditional 1.95 A request;
- logs whether an ICL came from the safe default, APSD or TCPM fallback.

It does not enable QC/PD voltage escalation, SMB1390, a charge pump, 3 A input or
Xiaomi's downstream 5.5 A fast-charge configuration.

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

## Charge limiter

`phoenix-charge-cap.sh` implements 60-70% hysteresis by suspending the SMB USB
input at the stop threshold and resuming at the start threshold. The revised
script validates its configuration and reads back the charger online state
before logging success. Failed writes are errors; they are no longer silently
reported as successful transitions.

Because current SOC is voltage-derived, this limiter should be understood as a
useful voltage-correlated longevity guard, not a laboratory-accurate true-SOC
controller.

## Telemetry and capacity measurement

Enable continuous five-second raw logging:

```sh
sudo systemctl enable --now phoenix-battery-telemetry.service
```

Logs are TSV files in `/var/log/phoenix-battery/`. They include raw battery
voltage/current/temperature, reported SOC, SMB charger state, effective input
limit, TCPM contract and Type-C power role. Retention and sample interval are
configured in `/etc/phoenix-battery-telemetry.conf`.

Summarize the latest file, or a named file:

```sh
phoenix-battery-report
phoenix-battery-report /var/log/phoenix-battery/telemetry-YYYY-MM-DD.tsv
```

The report uses trapezoidal integration for mAh and mWh and rejects time gaps
over 30 seconds. A real replacement-battery capacity result requires a later
controlled full-to-low discharge test; the short validation window is not a
capacity measurement.

## Rollback

For a packaged kernel, remove patches 0007-0009 to return to the original
charger behavior. On the test device, the original DTB was preserved as
`sm7150-xiaomi-phoenix.pre-tcpm.dtb` and a `postmarketOS (pre-TCPM charger DT)`
loader entry was added before testing.

Do not copy Xiaomi's downstream 3 A USB ICL or 5.5 A FCC values into this port.
Those values depend on profile selection, thermal policy, six-pin sensing,
protocol negotiation and secondary charge-pump support that this mainline port
does not implement.
