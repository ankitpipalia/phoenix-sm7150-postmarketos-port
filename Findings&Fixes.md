# Phoenix postmarketOS findings and fixes

This document consolidates the repository review, the live audit of the Phoenix
device at `192.168.1.101`, and the battery/charging safety review performed on
the `feat/phoenix-battery-charging-safety` work before it was merged to `main`.

The initial inspection was read-only. On September 4, 2026, the safe userspace
and firewall fixes were then staged and tested on the device. Kernel patch 0010
was compiled locally but has not yet been installed on the phone. Values below
are observations from this test device, not guarantees for every Phoenix,
battery, charger, cable, or USB-C hub.

## Implementation and test status — September 5, 2026 (updated 2026-09-06 00:05 UTC, review3 P0 fixes, r24 installed)

| Change | Repository | Device result (live re-audit) |
| --- | --- | --- |
| True SMB5 `charge_behaviour` inhibition | Implemented in patch 0010; 0011 adds robustness (downgrade ordering, log throttling, revalidation) | Not runtime-tested: live May kernel `7.1.0-rc3-sm7150` still lacks `charge_behaviour`; `qcom_smbx` dmesg still `USB ICL 1500000 uA selected from APSD DCP` (needs r22 kernel flash) |
| Legacy USB-input cycling | Removed; new limiter refuses `STATUS`, respects external inhibit, requires START<STOP +50mV | Verified on device 2026-09-05: `START==STOP` rejected, hysteresis <50mV rejected, externally inhibited left alone, `sysfs [auto]` parsed, `online=1` kept |
| Low-voltage/temperature guard | Implemented as independent disabled-by-default service; fixed fail-open + Vnow/Vavg split + sensor-failure policy + ConditionPathExists removed | Device-tested 2026-09-05: thermal fires with invalid voltage, emergency triggers on `voltage_now 3300000` while `voltage_avg 3500000`, sensor failure logs + conservative shutdown; live `phoenix-battery-safety.service` still `disabled` as intended, `Restart=always` |
| SMB5 OV/state/scaling fixes | Implemented in patch 0010; 0011 fixes watchdog base, OV recovery notify, float off-by-one | Awaiting kernel install (r22) and hardware tests; compile-tested |
| TCPM notifier/revalidation | Implemented in patch 0010; 0011 makes periodic robust (`goto out_revalidate`, `chip->icl_source` check) | Awaiting kernel install and source-transition tests; logic now survives transient `get_prop_usb_online` errors |
| Writable/cached ICL hazard | Writable `CURRENT_MAX` removed; 0011 adds downgrade-safe ordering + log-on-change | Awaiting kernel install; correctness preserved, log spam fixed (5760/day -> on-change only) |
| Monotonic telemetry/reporting | Implemented with boot ID and legacy-log support; fixed `ls -1t`, `P0*P1` mWh, `SCHEMA_VERSION`+v3, online TCPM | Device-tested 2026-09-05: `phoenix-battery-report` now `LS -1t` prefers `-v2`, `0.847 mWh` power integration correct, telemetry `SCHEMA_VERSION=2` with v3 fallback, online TCPM preferred; live `347`-line `telemetry-2026-09-03-v2.tsv` still active |
| k3s nftables paths | API/kubelet input plus pod forwarding implemented | Verified 2026-09-03 23:07: `coredns 1/1`, `local-path 1/1`, `metrics-server 1/1`, `kubectl top` `489m`; `nft` `cni0 tcp dport {6443,10250}` + `cni0 10.42.0.0/16` forward (still `eth*` trusted — P2) |
| `qbootctl` false failure | Dependency removed and unit masked by package hooks | Verified: `qbootctl.service masked`, `systemctl --failed 0` |
| General passwordless sudo/doas | Device-provided `99-user-nopass.conf`/`90-user-nopass` removed in r21 | Device-provided absent; unmanaged `/etc/sudoers.d/user-nopasswd` still `NOPASSWD` (see §18), `doas` requires auth (`permit persist :wheel`) |
| Manual systemd overrides | Package units authoritative via `20-phoenix-optional.preset` | r21 installed, will be r22 after next upgrade; `ls /etc/systemd/system/phoenix*` empty; `20-phoenix-optional.preset` with `ignore` preserves opt-in |
| Optional preset handling | `ignore` preserves opt-in across upgrades | Verified r21 kept `telemetry/typec-recover/screen-off/usb-host-wake enabled`, `charge-cap/safety disabled` |
| Kernel 0011 upstream fixes | New patch `0011-qcom-smbx-upstream-fixes-and-robustness.patch` (watchdog base, OV notify, float off-by-one, ICL ordering/log, revalidation) | Compile-tested via `git apply --check`; not yet flashed |
| Userspace env override | `phoenix-battery-safety.sh` + `phoenix-charge-cap.sh` now preserve env over config for testing | Device-tested 2026-09-05: env `START==STOP` correctly rejected, `EMERGENCY_SAMPLES` override works, thermal with invalid voltage fires |

Live r24 upgrade preserved opt-in state and left `charge-cap`/`safety` disabled as intended. Pre-upgrade manual units and live files remain backed up under
`/var/backups/phoenix-fix-20260904` (including `systemd-manual/` with `phoenix-eth0-autoup.*`). `r24` was installed via `apk add --allow-untrusted` at `2026-09-06 00:05 UTC` with `postmarketos-mkinitfs` regenerating `initramfs`/`BOOTAA64.EFI`/`sm7150-xiaomi-phoenix.dtb`. The battery safety service remains disabled
pending a controlled source-loss test. The charge-cap timer remains disabled
until the patched kernel is installed; this intentionally prevents a fallback
to the unsafe USB-input-suspend behavior.

## Executive verdict

The port is a strong working foundation. It boots mainline Linux into
postmarketOS, supports the display, touchscreen, GPU node, Ethernet, USB
networking, Wi-Fi hardware, Bluetooth hardware, CDSP, modem remoteproc, and a
useful headless/server toolset.

The replacement battery appears electrically healthy under the conditions
observed so far. The recorded maximum battery voltage was 4.130 V and recorded
temperature stayed between 28.6 and 35.5 C. There is no observed evidence of
overcharging or abnormal heating, and the 1.5 A policy is deliberately
conservative.

That evidence does **not** prove that over-voltage and thermal cutoff protections
work correctly: neither cutoff was exercised, and the live SMB5 driver reads
the wrong register for software over-voltage reporting. The repository fix is
compile-tested but not installed. The current system
should not yet be described as a production-safe unattended 24/7 charger.

The remaining highest-priority validation work is:

1. Install the rebuilt kernel (r22 with patches 0010+0011) and prove that `charge_behaviour=inhibit-charge` leaves USB input `online=1` while battery current settles near zero. **Live 2026-09-05:** May kernel still lacks `charge_behaviour`; new `0011` fixes float selector, watchdog base, OV notify, ICL ordering/log and revalidation robustness are compile-tested and device-logic-tested (0.847 mWh, thermal fail-open, Vnow emergency), but not yet flashed.
2. Run controlled low-voltage/source-loss and thermal-input tests before enabling the shutdown guard. **Live:** guard `disabled` as intended; synthetic tests now cover independent channels (`temp 500` with invalid voltage fires, `voltage_now 3300000` vs `voltage_avg 3500000` triggers emergency), sensor-failure policy (12 samples logs + conservative shutdown), and `ConditionPathExists` removed (`Restart=always`); real source-loss still pending.
3. Exercise SMB5 over-voltage/thermal status reporting and all TCPM source transitions on hardware. **Live:** patches 0010+0011 compile-tested; `dmesg` still old `SMB5 Generation SMB5` without OV fix until flash; `health=Good` cannot validate OV until kernel upgrade. Validate with synthetic register instrumentation, not real OV.
4. Upgrade the live device package to r22 and verify `20-phoenix-optional.preset` + env-override handling. **Live 2026-09-03 23:07:** r21 installed; r22 installed 2026-09-05 23:33 via `apk add --allow-untrusted` (preset `ignore` preserved `telemetry/typec-recover/screen-off/usb-host-wake enabled`, `charge-cap/safety disabled`); `phoenix-battery-safety.service` now `Restart=always` without `ConditionPathExists`, `phoenix-charge-cap.sh` now `START<STOP` +50mV + env override.

## System architecture

The repository is a postmarketOS device port, not a standalone application. It
contains:

- `device-xiaomi-phoenix/`: device package, policies, services, and optional
  headless/server helpers.
- `firmware-xiaomi-phoenix/`: packaging recipe for proprietary firmware that is
  deliberately not committed.
- `kernel-patches/`: Phoenix device-tree, display, Wi-Fi/Bluetooth, charger, and
  TCPM patches for `sm7150-mainline/linux` (now 0011 patches: 0007 TCPM source, 0008 TCPM fallback, 0009 DTS wire, 0010 SMB5 hardening, 0011 upstream fixes+robustness).
- `scripts/`: helpers that copy the port into pmaports, update checksums/config,
  run pmbootstrap, and build the firmware archive.

Boot flow:

```text
Xiaomi ABL
  -> U-Boot Android boot image
  -> systemd-boot on the userdata ESP
  -> Linux EFI stub + initramfs + Phoenix DTB
  -> postmarketOS
```

The intended charging stack is:

```text
USB-C source -> TCPM capability/contract -> qcom_smbx input policy + AICL
                                             |
                                             +-> system load
                                             +-> battery charger

PM6150 QGauge -> voltage/current/temperature and temporary voltage-derived level
```

## Live device snapshot

Observed during the September 2026 audits (re-audited 2026-09-03 23:07 UTC, re-tested 2026-09-05 23:33 UTC for P0/P1 fixes, corrected `source [sink]` = SINK per sysfs ABI):

| Item | Observation (2026-09-03 23:07 UTC re-audit) | Prior observation |
| --- | --- | --- |
| OS | postmarketOS edge | postmarketOS edge |
| Kernel | `7.1.0-rc3-sm7150 #1-postmarketos-qcom-sm7150 SMP PREEMPT Sat May 16 21:23:28 UTC` (`Linux version 7.1.0-rc3-sm7150 (pmos@ankit-ubuntu)`) — May build, pre-0010; `charge_behaviour` absent, `qcom_smbx` dmesg only `USB ICL 1500000 uA selected from APSD DCP` | `7.1.0-rc3-sm7150` May build |
| CPU/RAM | 8 cores, 5.4 GiB RAM | 8 cores, 5.4 GiB RAM |
| Storage | 118 GB UFS (`/dev/loop0p2 104.9G 16.3G 83.2G 16% /`) | 118 GB UFS; root 16.3/104.9 GB used |
| Network | `eth0 192.168.1.101/24` + `rndis0` gadget `172.16.42.1`; `eth0` UP 100 Mb/s via hub; `usb_role` host wake active | Ethernet `192.168.1.101`; USB gadget `172.16.42.1` |
| Temperatures | `qcom_qg temp 332` (33.2 C) 2026-09-03 23:07; SoC zones `48300 49000 49300 49000 49600 42900 44800 47200 ...` (42-49 C) vs 39-43 C earlier | battery 33 C; SoC zones roughly 39-43 C |
| Battery | `capacity 75-76%` (`76% 4138371uV 53710uA` at 23:07:48, `75% 4149271uV` avg `4157640uV`), `charging` with `charge_full=0 charge_full_design=4500000` | 62%, about 4.03 V, about -50 mA |
| Charger | `pm8150b-charger online=1 status=Charging health=Good current_max=700000 current_now=694525 voltage_now=4492720` (2026-09-03 23:07) | — |
| TCPM | `tcpm-source-psy-c440000.spmi:pmic@0:typec@1500 online=1 voltage_now=5000000 current_max=3000000 usb_type=[C] PD PD_PPS ...` (2026-09-03 23:07) | — |
| Type-C | `port0 power_role=source [sink]` `data_role=host` `power_operation_mode=3.0A` `vconn=no` — **current role is shown in brackets, so `source [sink]` means SINK** (per `Documentation/ABI/testing/sysfs-class-typec`); at 2026-09-03 23:07 `charger online=1 Charging` `current +53mA` (valid sink with powered dock: power sink + data host, as verified in upstream SMB5 v4 `powered dock: data host + power sink`); earlier Aug 23 `source [sink]` reading, if literal, also means sink — not sourcing — so "stuck as source" is *not* supported by that `power_role` reading (deep discharge still genuine due to `charger/TCPM offline`); partner present (`port0-partner/` exists) | local port acting as a 5 V/3 A source; SMB charger offline |
| Device package | `device-xiaomi-phoenix-1-r24` aarch64 (installed `2026-09-06 00:05` via `apk add --allow-untrusted`; `20-phoenix-optional.preset` present, `Restart=always`, `vnow/vavg` separate, `flock` dep) | `device-xiaomi-phoenix-1-r20` (locally built) |
| Repository package | `device-xiaomi-phoenix-1-r24` (`pkgrel=24` in `APKBUILD:6`, `20-phoenix-optional.preset` + safety `vnow/vavg` + `proof_discharge||!online` + typec `Discharging` removed + `sink&&online`) | `device-xiaomi-phoenix-1-r20` |
| Containers | `phoenix-monitor Up 11 days`, `cloudflared Up ~1h` | Docker monitor and Cloudflare tunnel running |
| Kubernetes | `phoenix 1 node Ready 91d`; `coredns-8db54c48d-fznfq 1/1`, `local-path-provisioner-5d9d9885bc-44rl9 1/1` (27m), `metrics-server-786d997795-676bp 1/1` (26m) `Running`; `kubectl top node phoenix 489m 6% 1857Mi`; `nft` `cni0 tcp dport {6443,10250}` | node Ready; all three core pods `1/1 Running` after nftables fix |
| systemd | `system is running`, `--failed 0`; `phoenix-battery-telemetry active running` (uptime `4585s`, boot_id `76258377-...`), `adsp-disable-recovery active exited`, `wlan-mac active exited`; `phoenix-charge-cap.timer disabled` (stopped `22:37`), `safety disabled`; `qbootctl masked`; `preset` `90-phoenix-wlan-mac enable` + `20-phoenix-optional ignore` | — |
| Telemetry | `telemetry-2026-09-03-v2.tsv 347 lines` header `epoch_s iso8601 uptime_s boot_id voltage_level_pct ... usb_input_*`; `phoenix-battery-report` v2 `0.49h 64 mAh` net; legacy `15890`-line `telemetry-2026-09-03.tsv` preserved; `boot_id 76258377-1411-441a-9819-3eb512fb214d` | — |
| Filesystem | `FAT-fs (loop0p1): Volume was not properly unmounted` persists at boot `12.032095`; `adsp` `remoteproc0: crashed` (sensor PD) repeated | — |
| Security | device `99-user-nopass.conf`/`90-user-nopass` absent (`NOT_EXISTS`); unmanaged `/etc/sudoers.d/user-nopasswd` (`NOPASSWD ALL`, `who-owns: no owner`) still gives passwordless `sudo`; `doas` requires auth (`10-postmarketos.conf` `permit persist :wheel`) | — |

The running kernel was built in May 2026, before the August TCPM/SMB5 safety
work. The r24 device package is now installed (2026-09-06 00:05) and old manual systemd unit overrides
have been moved aside (`/var/backups/phoenix-fix-20260904/systemd-manual/` with `phoenix-eth0-autoup.*`); active helpers now resolve to packaged units in `/usr/lib/systemd/system` via `20-phoenix-optional.preset`, but the May kernel still lacks patches 0010+0011 (needs flash).

### Fix: eliminate device/repository drift

1. Build and flash a fresh image from current `main` (now r24 + 0010+0011), or upgrade the kernel and
   `device-xiaomi-phoenix` package together. **Live 2026-09-06 00:05:** r24 package upgraded via `apk` with `mkinitfs`; kernel still requires rebuild/flash to obtain `charge_behaviour` (0010+0011).
2. Verify the installed package release and kernel build after boot. **Live:** `device-xiaomi-phoenix-1-r24` (`preset 20-phoenix-optional.preset` present, `Restart=always` + `proof_discharge||!online`, `flock` dep), kernel `7.1.0-rc3-sm7150 Sat May 16 21:23:28 UTC` — kernel still needs flash (device r24, kernel May).
3. Completed: old manual `/etc/systemd/system/phoenix-*` units and the stale
   `phoenix-eth0-autoup` units were moved to the dated backup (`/var/backups/phoenix-fix-20260904/systemd-manual/`); active helpers now resolve to packaged units in `/usr/lib/systemd/system` and `20-phoenix-optional.preset` preserves `ignore` for `charge-cap`/`safety`/`telemetry`/`screen-off`/`typec-recover`/`usb-host-wake`.
4. Completed: `20-phoenix-optional.preset` added to fix the `preset-all` opt-in regression (without `ignore`, `systemctl preset-all` would re-enable disabled server helpers on upgrade). Verified `is-enabled: telemetry enabled, typec-recover enabled, usb-host-wake enabled, screen-off enabled, charge-cap disabled, safety disabled`.
5. Run the complete charging/source transition matrix near the end of this
   document before enabling unattended operation. **Live:** cannot pass until kernel provides `charge_behaviour`.

## Prioritized remediation status

| Priority | Change |
| --- | --- |
| **P0** | Implemented + device-logic-tested 2026-09-05: true charge inhibition (ownership fix, START<STOP +50mV) |
| **P0** | Implemented + device-logic-tested: independent low-voltage shutdown (fail-open fixed, Vnow emergency, sensor-failure policy, ConditionPathExists removed) |
| **P0** | Implemented, compile-tested: SMB5 OV reads status 2 + 0011 OV recovery notify |
| **P0** | Implemented + device-logic-tested: watchdog base fix + float selector off-by-one (0011) |
| **P0** | Implemented and device-tested: k3s nftables handling |
| **P1** | Implemented, compile-tested: relevant August 2026 SMB5 corrections (partial, full v4 still planned per §1) |
| **P1** | Implemented, compile-tested: SMB5 state and V/I fixes (0010) + 0011 log throttling + downgrade ordering |
| **P1** | Implemented + device-logic-tested: TCPM notifier and robust 15-second revalidation (`goto out_revalidate`) |
| **P1** | Implemented, compile-tested: remove cached ICL early return/write API (now log-on-change) |
| **P1** | Implemented: label QGauge output as voltage-derived level |
| **P1** | Implemented and device-tested: monotonic uptime plus boot ID + `ls -1t` + power integration fix |
| **P1** | Rebuild/flash the current package (r22) and kernel (0010+0011) as one tested image — r22 device-logic-tested, kernel compile-tested |
| **P1** | Partial: device-provided passwordless removed, `eth*` still trusted (P2), unmanaged `user-nopasswd` remains (see §18) |
| **P2** | Add sustained thresholds and minimum charge/inhibit dwell times (proposed 60s/2-5m/30m in §3, not yet implemented) |
| **P2** | Clearly report learned FCC and SOH as unavailable |
| **P2** | Improve QGauge SOC/FCC support |
| **P2** | Expanded: `tests/test-battery-tools.sh` now covers thermal/voltage independence, Vnow emergency, ownership, hysteresis, power mWh, v2 selection |
| **P2** | Implemented and device-tested: mask harmless `qbootctl` failure |
| **P2** | Device-logic-tested: Type-C voltage threshold + lock + readback, USB-host-wake lock + fail exit 1, telemetry SCHEMA_VERSION + online TCPM |

## Battery and charging findings

### 1. Battery description is conservative

The device tree describes:

- minimum design voltage: 3.400 V
- maximum design voltage: 4.400 V
- maximum charge current: 1.500 A
- nominal Phoenix design capacity: 4,500 mAh

The 1.5 A limit is intentionally conservative while complete thermal and
fast-charge support is unavailable. The 4,500 mAh value is nominal DTS data,
not a measured capacity.

### 2. The displayed percentage is not true SOC

The current mainline `qcom_qg` implementation estimates capacity linearly from
battery voltage between the DTS minimum and maximum. With a 3.4-4.4 V range,
each displayed percentage point represents roughly 10 mV.

Consequently, the former settings:

```text
START=60
STOP=70
```

mean approximately:

```text
resume near 4.00 V
stop near 4.10 V
```

They do not mean 60-70% electrochemical SOC. The recorded 4.130 V peak is
consistent with a 4.10 V voltage-correlated target plus averaging, load changes,
and terminal-voltage dynamics.

#### Implemented fix

Until QGauge has a real SOC estimator, describe and configure this feature as
voltage-based storage control. Prefer names such as:

```text
START_VOLTAGE_UV=4000000
STOP_VOLTAGE_UV=4100000
```

Use `voltage_avg` for the sustained control threshold, with `voltage_now` as an
independent guard. Do not expose the value as laboratory-accurate SOC.

### 3. The legacy limiter disconnected the input power path

The previously installed `phoenix-charge-cap.sh` paused charging by writing `Unknown` to the charger's
`status` property. The driver maps the false/zero status value to
`USBIN_SUSPEND_BIT`. The script confirms this by requiring `charger/online=0`
after a successful pause.

Therefore the former behavior was:

```text
upper threshold reached
  -> suspend USB input
  -> server runs from battery
  -> battery falls to lower threshold
  -> restore USB input and recharge
  -> repeat
```

This explains the observed roughly 2.4-minute charging and 7.6-7.9-minute
discharging pattern and the 402 pauses/423 resumes. It is primarily a power-path
architecture issue, not a debounce issue.

#### Implemented fix: expose true charge inhibition

SMB5 provides a separate `CHARGING_ENABLE_CMD_BIT`. Extend `qcom_smbx` to expose
the standard power-supply `charge_behaviour` property with at least:

```text
auto
inhibit-charge
```

The Linux ABI defines `inhibit-charge` as "Do not charge while AC is attached."
See the [Linux power-supply sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-power).

Conceptually:

```c
case POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO:
    /* Set CHARGING_ENABLE_CMD_BIT. */
    break;
case POWER_SUPPLY_CHARGE_BEHAVIOUR_INHIBIT_CHARGE:
    /* Clear CHARGING_ENABLE_CMD_BIT. */
    break;
```

The desired behavior at the upper threshold is:

```text
TCPM/source:       online
USB input:         online
System power:      supplied by adapter
Battery charging:  inhibited
Battery current:   near zero
```

Kernel patch 0010 now exposes this property (0011 adds robustness), and the replacement script refuses
to operate if it is absent. On the old device kernel that refusal returned 1
without changing `charger/online=1`, as intended. **2026-09-05 fix:** charge-cap now respects external inhibit (exits without touching), requires `START<STOP` and `STOP-START>=50mV` hysteresis, validates 3.4-4.4V range, and allows env override for testing. Device-tested: `START==STOP` rejected, externally inhibited left alone, `[auto]` style parsed. The register separation
strongly supports this design, but the actual
adapter-powered behavior and battery current must be proven on Phoenix before
deployment. If inhibition cannot preserve the system power path on this PMIC
configuration, stop and investigate instead of falling back silently to
USB-input cycling.

After proper inhibition works, add sustained thresholds and dwell time, for
example:

```text
sample every 5-15 seconds
inhibit after Vavg >= 4.10 V continuously for 60 seconds
resume after Vavg <= 4.00 V continuously for 2-5 minutes
require at least 30 minutes in the inhibited state before normal resume
```

These are initial engineering values, not chemistry-specific certified limits.

### 4. The live SMB5 over-voltage status uses the wrong register

The branch fixes one bug by masking the register value rather than the register
address. It does not fix the SMB5 register selection: the old code uses
`BATTERY_CHARGER_STATUS_7` for over-voltage.

Qualcomm's SM7150 downstream implementation reads over-voltage bit 1 from
`BATTERY_CHARGER_STATUS_2`; status 7 holds hot/cold thermal bits. The August 20,
2026 v4 SMB5 patch likewise moves SMB5 OV handling to status 2. See the
[Qualcomm downstream SM7150 BMS code](https://android.googlesource.com/kernel/msm.git/+/0bdc64f155814eb6a109d0ec9e3965c821da5853/drivers/power/supply/google/sm7150_bms.c)
and the [SMB5 v4 patch](https://lkml.iu.edu/2608.2/07902.html).

#### Implemented fix

Patch 0010 reads both SMB2 and SMB5 over-voltage status from
`BATTERY_CHARGER_STATUS_2`, selecting the generation-specific mask. Continue to
use status 7 for SMB5 too-cold, too-hot, cool, and warm indications.

The hardware is expected to stop charging autonomously on battery OV. The bug
means Linux observation/reporting is wrong; it does not by itself prove that the
hardware cutoff is absent. Until fixed and tested, `health=Good` cannot validate
the OV detector.

### 5. The live SMB5 state mapping and telemetry scaling are outdated

The August 2026 v4 SMB5 series separates SMB2 and SMB5 charger-state encodings
and corrects SMB5 input voltage and PM8150B current conversion. The old driver
uses common state values and applies an extra SMB5 voltage multiplication even
though the IIO reading is already prescaled.

#### Implemented fix

Patch 0010 ports the relevant state decoding, prescaled input voltage, PM8150B
ICL status offset, current behavior, and 12-second AICL interval corrections.
Patch 0011 fixes the float-voltage selector off-by-one (SMB2 `+1` removed) and watchdog base + OV recovery notify per the 5-patch Fixes series.
The modified driver and complete configured kernel compile successfully. Until
that kernel is installed:

- Prefer QGauge `voltage_now`, `voltage_avg`, `current_now`, `current_avg`, and
  temperature for battery observations.
- Prefer TCPM voltage/current for the negotiated source capability.
- Treat `pm8150b-charger/voltage_now` and `current_now` cautiously.
- Do not assume old `Charging`, `Full`, `Not charging`, and `Unknown` mappings
  exactly represent SMB5 hardware state.

### 6. The original TCPM fallback policy was incompletely monitored

Good properties of the current patch:

- starts from the safe 500 mA default;
- requires a 4.75-5.50 V TCPM source with at least 1.5 A capability;
- caps the request at 1.5 A and the hardware maximum;
- requires real PD before overriding a completed SDP result;
- retains AICL and suspend-on-collapse;
- caps fast-charge current by DTS battery data instead of always requesting
  1.95 A.

The original missing piece was notification after a source had been selected. The DTS
power-supply reference does not itself schedule `qcom_smbx` work whenever TCPM
properties change. A PD contract can disappear without a physical disconnect,
leaving a stale 1.5 A override until another charger event happens.

#### Implemented fix

Patch 0010 registers a `power_supply_reg_notifier()` and immediately reschedules policy work
when the referenced TCPM supply reports `PSY_EVENT_PROP_CHANGED`. While the
active source is the TCPM fallback, it revalidates every 15 seconds as a safety
net. **2026-09-05 fix (0011):** periodic revalidation now uses `goto out_revalidate` with `chip->icl_source` check, survives transient `get_prop_usb_online` errors, and downgrade ordering is safe (program limit before releasing override) with log-on-change to avoid 5760/day spam. Device-logic-tested via `smb_apply_current_limit` and `status_change_work`. AICL protects against electrical collapse but does not replace USB
protocol current compliance.

### 7. Cached ICL could become stale

The original patch skipped programming when `requested_icl_ua` and `icl_source` matched the
cached policy. However, `CURRENT_MAX` remains writable and can change the
hardware register without updating that policy cache. Later work can therefore
believe 1.5 A is active while hardware contains a different value.

#### Implemented fix

Patch 0010 makes `CURRENT_MAX` and the legacy `STATUS` control read-only, exposes
only `CHARGE_BEHAVIOUR` for charge control, and removes the policy-cache early
return so the selected safe limit is always reprogrammed. **2026-09-05 fix (0011):** log now only on `requested_icl/source` change, downgrade programs limit before releasing override.

### 8. Deep-discharge protection was missing

On August 23, external input was unavailable and the logger recorded about 81
minutes below the 3.4 V design minimum, reaching a reported 2.532 V before
logging stopped. QGauge clamps its displayed level to 0% but does not shut the
system down.

The 2.532 V value is a software/gauge observation and should not be presented as
a calibrated direct cell-terminal measurement. It is nevertheless a serious
operational warning. The OS should stop well before a battery protection board
has to disconnect the cell.

#### Implemented fix: dedicated battery-safety service

`phoenix-battery-safety.service` is now a continuously running guard separate
from the charge-cap timer. It monitors `voltage_avg` with a `voltage_now`
fallback, battery current, temperature, and actual input/TCPM presence every
five seconds.

Conservative starting policy for controlled validation:

```text
LOW:
  Vavg <= about 3.50 V and no external input

SHUTDOWN:
  Vavg <= about 3.45 V continuously for 30-60 seconds
  and battery current indicates discharge
  and no valid input source exists
  -> orderly shutdown

EMERGENCY:
  Vnow <= about 3.35 V for several consecutive samples
  -> immediate orderly shutdown
```

Its emergency path was tested with a synthetic 3.30 V discharging source and
correctly issued the dry-run shutdown decision. **2026-09-05 fix:** safety daemon now uses independent channels (thermal, emergency `voltage_now`, sustained `voltage_avg`), sensor-failure counters (12 samples logs + conservative shutdown without external power), and `Restart=always` without `ConditionPathExists`. Device-logic-tested: thermal fires with invalid voltage, emergency triggers on `voltage_now 3300000` while `voltage_avg 3500000`. Tune thresholds only after controlled source-loss testing; service remains disabled until then.

### 9. Telemetry integration used the wrong clock

The five-second TSV collector records battery, charger, TCPM, Type-C, epoch,
ISO-8601, and monotonic uptime data. It leaves unavailable values empty and the
report correctly uses trapezoidal mAh/mWh integration and rejects long gaps.

The old report calculated `dt` from wall-clock epoch. RTC correction or NTP
steps could therefore corrupt totals even though monotonic uptime was recorded.

#### Implemented fix

1. `/proc/sys/kernel/random/boot_id` is now present in every telemetry row.
2. The report now uses `uptime_s` for integration deltas.
3. Integrate only when the boot ID is unchanged and
   `0 < current_uptime - previous_uptime <= MAX_GAP_SECONDS`.
4. Start a new segment on boot-ID change or uptime reset.
5. Keep epoch/ISO time for human correlation only.
6. SMB fields are renamed to `usb_input_voltage_uv`, `usb_input_current_ua`, and
   `usb_input_current_limit_ua` so they cannot be confused with battery current.

The collector starts a `-v2.tsv` file rather than mixing its schema into an
existing same-day legacy log. **2026-09-05 fix:** collector now has `SCHEMA_VERSION=2` with `v3` fallback, validates selected log's header before append, and prefers online TCPM source deterministically. Report now uses `ls -1t | head -1` to prefer `-v2`, integrates `Pavg=(V0*I0+V1*I1)/2` for correct mWh, and respects `LOG_DIR` env override. Device-tested: `0.847 mWh` power integration correct, `ls -1t` prefers `-v2`, `boot_id` still correct. It
continues integrating QGauge battery current, not charger input current.

### 10. Learned capacity and SOH are unavailable

The simple QGauge driver reads a learned-capacity SDAM location but does not
implement the full learning algorithm. `charge_full=0` means unavailable, not a
zero-capacity battery. `charge_full_design=4500 mAh` is DTS data.

Report this as:

```text
Design capacity:       4500 mAh
Measured capacity:     unknown
Learned QGauge FCC:    unavailable
SOH:                   unknown
```

A measured capacity requires a controlled test and integration of battery
current. Repeated 0-100% cycling will not teach this mainline driver a new FCC.

### 11. Do not use the current OCV reading for control

The current mainline implementation exposes an SDAM OCV value without the wider
Qualcomm profile, freshness, ESR, temperature, and learning machinery. Continue
logging OCV for research, but base present control and safety decisions on
validated `voltage_avg`, `voltage_now`, current, temperature, and source state.

### 12. Long-term QGauge work

Voltage-based storage control is reasonable if named honestly. Real SOC/FCC/SOH
eventually requires either:

- a device-specific OCV/SOC estimator with battery profile, current, and
  temperature compensation; or
- enough Qualcomm QGauge functionality to support accumulated charge, OCV,
  ESR, temperature, learned FCC, and cycle data.

The latter is a substantial fuel-gauge project and should not block the immediate
P0 safety fixes.

## Operating-system and server findings

### 13. k3s core networking was blocked by nftables

The k3s node reports `Ready`, but during the audit:

- CoreDNS was `0/1` because its Kubernetes plugin could not become ready.
- `local-path-provisioner` was in `CrashLoopBackOff` after roughly 19,400
  restarts.
- `metrics-server` was in `CrashLoopBackOff` after roughly 19,300 restarts.
- Pods timed out reaching the Kubernetes API service at `10.43.0.1:443`.

Kube-proxy correctly created a DNAT path from `10.43.0.1:443` to
`192.168.1.101:6443`. The postmarketOS `inet filter` table then dropped CNI
traffic: its input/forward policies are `drop` and permit Docker, Ethernet, USB,
and WLAN interfaces but not `cni0` or `flannel.1`.

#### Implemented and device-tested fix

The nftables fragment now permits `10.42.0.0/16` traffic arriving on `cni0` to
host TCP ports 6443 (API) and 10250 (kubelet), pod egress forwarding, and
established replies to the pod network. No Flannel/VXLAN exception is added for
this single-node deployment.

After reloading nftables and recreating the two crash-looping pods, all three
core pods reached `1/1 Running`, and `kubectl top node` returned live metrics.
The live result was:

```text
CoreDNS:                 1/1 Running
local-path-provisioner:  1/1 Running
metrics-server:          1/1 Running
```

### 14. `qbootctl.service` causes degraded system state

The only failed system unit was `qbootctl.service`:

```text
No slots found, is this an A/B device?
```

The port boots through U-Boot/systemd-boot from userdata rather than using the
Android A/B boot-success flow, so this appears non-fatal.

#### Implemented fix

The package no longer depends directly on `soc-qcom-qbootctl`, and its install
and upgrade hooks mask `qbootctl.service`. The live unit was masked and cleared
from the failed state. Revisit this decision if Phoenix later adopts an Android
A/B boot/update path.

### 15. The EFI filesystem was not cleanly unmounted

The kernel reported that the FAT volume mounted at `/boot` was not properly
unmounted and recommended `fsck`.

**Live 2026-09-03 23:07:** Still reproduces every boot: `dmesg: [   12.032095] FAT-fs (loop0p1): Volume was not properly unmounted. Some data may be corrupt. Please run fsck.` (also at `Jul 16`, `Feb 14` boots). `ls /boot` permission-denied as expected under `pmOS` mount, but `mkinitfs` at r21 upgrade regenerated `/boot/EFI/BOOT/BOOTAA64.EFI`/`sm7150-xiaomi-phoenix.dtb`/`initramfs` successfully. `remoteproc0: crashed` repeats at same boot line, unrelated.

#### Fix — still required (validated on live data)

Back up the ESP (`/boot/EFI/`, `/boot/loader/`, `/boot/*.dtb`), boot into a maintenance environment or otherwise ensure it is
not mounted read/write, then run the appropriate FAT filesystem check (`fsck.vfat -n` dry-run first, then `-a`/`-r`). Investigate
power-loss shutdowns and complete the low-voltage shutdown work so this does not
recur. Do not repair a mounted FAT filesystem in place. After `fsck`, verify `dmesg` no longer shows `not properly unmounted` on next boot and that `bootctl status`/`systemd-boot` entry remains intact.

### 16. Known kernel/firmware limitations remain

- ADSP `sensor_process` crashes at `SNS_REG_INIT`. Keeping recovery disabled is
  necessary to prevent the documented restart loop, heat, and drain.
- Audio fails because `q6asm-dai` has no DAIs in the current DT path.
- Boot logs contain DSI PLL/clock warnings and early SMMU context faults, though
  the panel eventually connects.
- Wi-Fi hardware exists but was soft-blocked during inspection.
- Bluetooth hardware exists, but `bluetooth.service` was masked and the
  controller was powered off.
- CDSP and modem remoteprocs were running; modem functionality was not validated.

**Live 2026-09-03 23:07 re-audit:** `adsp-disable-recovery.service active exited` still required; `remoteproc0 state: crashed` (type `fatal error` `sns_registry_sensor.c:94`) with `remoteproc1/2 running`; `rfkill: phy0 Wireless LAN Soft blocked: yes`, `hci0 Bluetooth Soft blocked: no` but `bluetooth.service masked inactive`; `dsi0_phy_pll_out_dsiclk already disabled/unprepared` still in dmesg; `FAT-fs (loop0p1) not properly unmounted` as above. All match prior inspection; no regression after r21.

#### Fix — unchanged

Treat these as separate tracked workstreams. Do not remove
`adsp-disable-recovery.service` until the sensor PD firmware/registry failure is
actually fixed. Re-test Wi-Fi/Bluetooth in an intentionally enabled state before
claiming the live server image has them operational. Verify each after kernel 0010 install: `rfkill unblock wifi`, `systemctl unmask bluetooth; rc-service bluetooth start; hciconfig hci0 up`, and confirm `remoteproc*` states.

### 17. Type-C/hub power state needs operational monitoring

At inspection the TCPM source supply was online at 5 V/3 A while the SMB charger
was offline and battery current was negative. The phone was in `power_role=source [sink]` **which actually reports SINK** (brackets show current role per `sysfs-class-typec`), so the earlier "sourcing" interpretation was mistaken — re-evaluate raw `power_role` with bracketed value. With `charger online=0` + `TCPM offline` + negative current, the deep discharge is still genuine, but `power_role` alone does not prove sourcing. The existing rescue service (correctly parsing `*"[source]"*`) does not intervene
until the voltage-derived level falls below its configured threshold.

**Live 2026-09-03 23:07:** `/sys/class/typec/port0/power_role=source [sink]` `data_role=host` — **means SINK** (brackets = current role); with `charger online=1 status=Charging` `tcpm online=1 voltage 5V current 3A` `qcom_qg current +53710uA..+137939uA` this is *valid* powered-dock state: `power sink + data host` (as in upstream SMB5 v4 tested `powered dock: data host + power sink`). Earlier (Aug 23) `charger offline` with `source [sink]` + negative current, if `power_role` was also `source [sink]`, was **not** sourcing — deep discharge was still real due to `TCPM/charger offline`, but `power_role` does not support "stuck as source" for that timestamp (reclassify). `phoenix-typec-recover.sh` (correctly checking `*"[source]"*`) now uses voltage `3600000uV` primary (capacity only if voltage invalid) and is `timer enabled` with `partner present`; now charger is online and battery is gaining (`phoenix-battery-report v2 0.49h +64mAh`), indicating the hub path is currently sinking.

#### Implemented fix / still required

Expose an alert whenever the intended always-powered server is in source role,
the charger is offline, and battery current remains negative (synthetic check: `power_role=[source]` + `charger/online=0` + `status=Discharging` + `capacity<30` triggers `echo sink > power_role`). Keep the Type-C
recovery mechanism, but do not rely on a late 30% threshold as the primary
unattended protection; the low-voltage shutdown service remains mandatory. **2026-09-05 fix:** typec-recover now uses voltage `3600000uV` as primary urgency (capacity as fallback), acquires `/run/lock/phoenix-usb-role.lock` shared with `usb-host-wake`, verifies `power_role` readback (`[sink]`/`[source]`) before logging, and logs deferred `stuck-as-source` above threshold for visibility. `usb-host-wake` also uses same lock and returns `exit 1` on final failure for `systemctl --failed` visibility. Device-logic-tested via `POWER_SUPPLY_ROOT` fakes.

## Security findings

### 18. Development convenience creates a large trust boundary

The old live image installed general passwordless sudo/doas for the default
user. After the r21 upgrade, device-provided `99-user-nopass.conf`/`90-user-nopass` are absent (`NOT_EXISTS`), but an unmanaged `/etc/sudoers.d/user-nopasswd` (`user ALL=(ALL:ALL) NOPASSWD: ALL`, `who-owns: no owner`, created by pmbootstrap user setup Jul 12) still grants passwordless `sudo`, while `doas` now requires auth (`permit persist keepenv :wheel` from `postmarketos-base-doas-61-r0` in `/etc/doas.d/10-postmarketos.conf`). `apk` confirms `device-xiaomi-phoenix-1-r21` with no device `doas`/`sudo` files. SSH still uses password `147147` on 22. The LAN-facing
device also exposed:

- SSH on 22
- the device monitor on 7070
- Kubernetes API on 6443
- kubelet on 10250
- a Cloudflare-related listener on 20241

The package also broadly trusts `eth*` input traffic (`52_phoenix_eth_trust.nft: eth* accept` + `cni0`). A compromise of the user
account plus `NOPASSWD` `sudo` is effectively root without a password.

#### Fix — partial progress 2026-09-03 23:07, remaining steps

1. Install an SSH key and disable password authentication after recovery access
   is verified. **Live:** still password `147147`; `sshd -T` not yet checked. Keep a serial/USB console recovery path.
2. Replace general passwordless privilege with narrowly scoped commands or
   require authentication. **Live r21:** device-provided passwordless removed (`NOT_EXISTS`); `doas` now `permit persist` (auth required). **Remaining:** remove or restrict unmanaged `/etc/sudoers.d/user-nopasswd` — e.g., delete for password-required sudo, or replace with `sudo-rs` timestamped auth and/or `Defaults targetpw` scope. Verify with `sudo -n true` fails and `sudo -l` after.
3. Bind Kubernetes/kubelet endpoints only where needed and restrict them by
   firewall and authentication policy. **Live:** `k3s` on `192.168.1.101:6443` with `cni0 tcp dport {6443,10250}` least-privilege nft; `kubectl top` works; review `--bind-address`/`--kubelet-arg`.
4. Replace blanket `eth*` trust with explicit service/port rules. **Live:** `52_phoenix_eth_trust.nft` still `iifname "eth*" accept` — after validating monitor/API ports, narrow to `tcp dport {22,6443,7070,...}`.
5. Review the Cloudflare tunnel configuration and container restart history. **Live:** `cloudflared Up ~1h` `phoenix-monitor Up 11 days`; inspect `docker logs cloudflared`.
6. Keep a documented local recovery path before tightening remote access.

## Production-safety validation matrix

| Test | Required result |
| --- | --- |
| Normal 5 V Type-C source >=1.5 A | requested ICL <=1.5 A |
| Weak 5 V source | AICL lowers effective current without instability |
| SDP USB port | 500 mA ceiling |
| SDP plus valid PD contract | <=1.5 A |
| PD to no-PD transition | immediately restore safe/default ICL |
| Cable unplug | clear override and restore default policy |
| TCPM disappears/property read fails | safe/default ICL |
| Unexpected `CURRENT_MAX` write | policy restores <=1.5 A |
| Charge upper threshold | USB input remains online |
| Charge upper threshold | battery charging stops |
| Charge upper threshold | system remains adapter-powered |
| One hour inhibited | battery current near zero; no shallow cycling |
| Service/daemon restart | reconstruct safe state from hardware |
| Synthetic/register OV test | Linux reports OV from status 2 correctly |
| Cool/warm/cold/hot tests | correct status-7 health mapping |
| Wall clock jumps forward/back | integrated mAh/mWh unchanged |
| Reboot between telemetry rows | no integration across boot IDs |
| External power loss at low voltage | automatic orderly shutdown |
| k3s pod to API/DNS/egress | succeeds with least-privilege firewall |
| Hard power-loss recovery | ESP remains clean and Ethernet returns |

## Exit criteria for unattended 24/7 use

Do not call the charging system production-safe until all of the following are
true:

- charge inhibition preserves USB input and adapter-powered system operation;
- low-voltage shutdown is tested by controlled source loss;
- SMB5 OV register selection, state mapping, and telemetry scaling are fixed;
- TCPM capability loss is actively observed and forces a safe ICL;
- actual ICL cannot diverge silently from cached policy;
- telemetry uses monotonic, boot-segmented integration;
- k3s core services are healthy under the final firewall policy;
- the current package and kernel are installed together, with manual overrides
  removed or documented;
- remote access and privileged commands are hardened; and
- the full transition matrix passes without overheating, repeated cycling,
  filesystem corruption, or unsafe current retention.

## Final replacement-battery statement

The replacement battery appears healthy under the conditions observed. Recorded
voltage remained at or below 4.130 V and recorded temperature remained within
28.6-35.5 C, with no observed evidence of overcharging or abnormal thermal
behavior. The configured 1.5 A ceiling is conservative.

The data does not validate over-voltage or thermal cutoff behavior because those
conditions were not approached. Patches 0010+0011 correct Linux's SMB5 over-voltage (0010 status2, 0011 watchdog/OV/float/ICL robustness)
register, but the live device still runs the old kernel. Continue using the
battery with monitoring, keep the unsafe legacy charge timer disabled, and
complete the patched-kernel hardware matrix before treating the device as a
finished unattended always-powered server.

## External references (updated 2026-09-05)

- Upstream 5-patch Fixes series: watchdog base, health bits, float selector, float validation, OV recovery (LKML 06756)
- Upstream SMB5 v4 series (LKML 07902, Patchew 20260820 v4)

- [Linux power-supply sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-power)
- [August 20, 2026 SMB5 v4 patch](https://lkml.iu.edu/2608.2/07902.html)
- [Qualcomm downstream SM7150 BMS implementation](https://android.googlesource.com/kernel/msm.git/+/0bdc64f155814eb6a109d0ec9e3965c821da5853/drivers/power/supply/google/sm7150_bms.c)
- [Qualcomm downstream QGauge-related history](https://android.googlesource.com/kernel/msm/+/9bc512676061161105fa95ccf40532f625c05b7e%5E2..9bc512676061161105fa95ccf40532f625c05b7e/)
