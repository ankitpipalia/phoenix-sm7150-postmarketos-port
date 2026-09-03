# Phoenix postmarketOS findings and fixes

This document consolidates the repository review, the live audit of the Phoenix
device at `192.168.1.101`, and the battery/charging safety review performed on
the `feat/phoenix-battery-charging-safety` work before it was merged to `main`.

The live inspection was read-only. Values below are observations from the test
device or the existing telemetry, not guarantees for every Phoenix device,
battery, charger, cable, or USB-C hub.

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
work correctly: neither cutoff was exercised, and the pinned SMB5 driver reads
the wrong register for software over-voltage reporting. The current system
should not yet be described as a production-safe unattended 24/7 charger.

The highest-priority risks are:

1. The charge limiter suspends USB input instead of inhibiting battery charging,
   making the server run from and repeatedly cycle the battery.
2. There is no orderly low-voltage shutdown; telemetry recorded about 81 minutes
   below the 3.4 V design minimum and a reported minimum of 2.532 V.
3. SMB5 over-voltage reporting uses the wrong status register.
4. The running phone is behind the repository and does not contain the newest
   charging-safety kernel patches.
5. The device's nftables policy breaks k3s pod-to-API traffic.

## System architecture

The repository is a postmarketOS device port, not a standalone application. It
contains:

- `device-xiaomi-phoenix/`: device package, policies, services, and optional
  headless/server helpers.
- `firmware-xiaomi-phoenix/`: packaging recipe for proprietary firmware that is
  deliberately not committed.
- `kernel-patches/`: Phoenix device-tree, display, Wi-Fi/Bluetooth, charger, and
  TCPM patches for `sm7150-mainline/linux`.
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

Observed during the September 2026 audit:

| Item | Observation |
| --- | --- |
| OS | postmarketOS edge |
| Kernel | `7.1.0-rc3-sm7150` |
| CPU/RAM | 8 cores, 5.4 GiB RAM |
| Storage | 118 GB UFS; root 16.3/104.9 GB used |
| Network | Ethernet `192.168.1.101`; USB gadget `172.16.42.1` |
| Temperatures | battery 33 C; SoC zones roughly 39-43 C |
| Battery | 62%, about 4.03 V, about -50 mA at inspection |
| Type-C | local port acting as a 5 V/3 A source; SMB charger offline |
| Device package | `device-xiaomi-phoenix-1-r10` |
| Repository package | `device-xiaomi-phoenix-1-r19` |
| Containers | Docker monitor and Cloudflare tunnel running |
| Kubernetes | node Ready, but all three core pods unhealthy |

The running kernel was built in May 2026, before the August TCPM/SMB5 safety
work. The telemetry and most server helpers were installed manually under
`/etc/systemd/system` and `/usr/libexec`; this does not mean the matching kernel
patches are running.

### Fix: eliminate device/repository drift

1. Build and flash a fresh image from current `main`, or upgrade the kernel and
   `device-xiaomi-phoenix` package together.
2. Verify the installed package release and kernel build after boot.
3. Inventory and remove obsolete manual `/etc/systemd/system/phoenix-*` units
   after preserving any local configuration. Files in `/etc` override packaged
   units in `/usr/lib/systemd/system`.
4. Remove the stale `phoenix-eth0-autoup.service`; that approach was removed from
   the repository.
5. Run the complete charging/source transition matrix near the end of this
   document before enabling unattended operation.

## Prioritized remediation plan

| Priority | Change |
| --- | --- |
| **P0** | Replace USB-input suspension with true battery-charge inhibition |
| **P0** | Add an independent unattended low-voltage shutdown service |
| **P0** | Read SMB5 battery over-voltage from `BATTERY_CHARGER_STATUS_2` |
| **P0** | Repair nftables handling for k3s `cni0`/Flannel traffic |
| **P1** | Port/rebase the August 20, 2026 v4 SMB5 corrections |
| **P1** | Correct SMB5 charge-state decoding and V/I measurement scaling |
| **P1** | Add a TCPM power-supply notifier and periodic fallback validation |
| **P1** | Remove or validate the cached input-current-limit optimization |
| **P1** | Treat the QGauge level as voltage-derived, not true SOC |
| **P1** | Integrate telemetry by monotonic uptime and boot ID |
| **P1** | Rebuild/flash the current package and kernel as one tested image |
| **P1** | Harden privileged access and exposed network services |
| **P2** | Add sustained thresholds and minimum charge/inhibit dwell times |
| **P2** | Clearly report learned FCC and SOH as unavailable |
| **P2** | Improve QGauge SOC/FCC support |
| **P2** | Add automated charger/source-transition and policy tests |
| **P2** | Resolve or explicitly mask the harmless `qbootctl` failure |

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

Consequently, the existing settings:

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

#### Fix

Until QGauge has a real SOC estimator, describe and configure this feature as
voltage-based storage control. Prefer names such as:

```text
START_VOLTAGE_UV=4000000
STOP_VOLTAGE_UV=4100000
```

Use `voltage_avg` for the sustained control threshold, with `voltage_now` as an
independent guard. Do not expose the value as laboratory-accurate SOC.

### 3. The current limiter disconnects the input power path

`phoenix-charge-cap.sh` pauses charging by writing `Unknown` to the charger's
`status` property. The driver maps the false/zero status value to
`USBIN_SUSPEND_BIT`. The script confirms this by requiring `charger/online=0`
after a successful pause.

Therefore the present behavior is:

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

#### Fix: expose true charge inhibition

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

The register separation strongly supports this design, but the actual
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

### 4. SMB5 over-voltage status uses the wrong register

The branch fixes one bug by masking the register value rather than the register
address. It does not fix the SMB5 register selection: the old code uses
`BATTERY_CHARGER_STATUS_7` for over-voltage.

Qualcomm's SM7150 downstream implementation reads over-voltage bit 1 from
`BATTERY_CHARGER_STATUS_2`; status 7 holds hot/cold thermal bits. The August 20,
2026 v4 SMB5 patch likewise moves SMB5 OV handling to status 2. See the
[Qualcomm downstream SM7150 BMS code](https://android.googlesource.com/kernel/msm.git/+/0bdc64f155814eb6a109d0ec9e3965c821da5853/drivers/power/supply/google/sm7150_bms.c)
and the [SMB5 v4 patch](https://lkml.iu.edu/2608.2/07902.html).

#### Fix

Read both SMB2 and SMB5 over-voltage status from
`BATTERY_CHARGER_STATUS_2`, selecting the generation-specific mask. Continue to
use status 7 for SMB5 too-cold, too-hot, cool, and warm indications.

The hardware is expected to stop charging autonomously on battery OV. The bug
means Linux observation/reporting is wrong; it does not by itself prove that the
hardware cutoff is absent. Until fixed and tested, `health=Good` cannot validate
the OV detector.

### 5. The pinned SMB5 state mapping and telemetry scaling are outdated

The August 2026 v4 SMB5 series separates SMB2 and SMB5 charger-state encodings
and corrects SMB5 input voltage and PM8150B current conversion. The old driver
uses common state values and applies an extra SMB5 voltage multiplication even
though the IIO reading is already prescaled.

#### Fix

Port or rebase onto the v4 corrections before further tuning. Until then:

- Prefer QGauge `voltage_now`, `voltage_avg`, `current_now`, `current_avg`, and
  temperature for battery observations.
- Prefer TCPM voltage/current for the negotiated source capability.
- Treat `pm8150b-charger/voltage_now` and `current_now` cautiously.
- Do not assume old `Charging`, `Full`, `Not charging`, and `Unknown` mappings
  exactly represent SMB5 hardware state.

### 6. The TCPM fallback policy is conservative but incompletely monitored

Good properties of the current patch:

- starts from the safe 500 mA default;
- requires a 4.75-5.50 V TCPM source with at least 1.5 A capability;
- caps the request at 1.5 A and the hardware maximum;
- requires real PD before overriding a completed SDP result;
- retains AICL and suspend-on-collapse;
- caps fast-charge current by DTS battery data instead of always requesting
  1.95 A.

The missing piece is notification after a source has been selected. The DTS
power-supply reference does not itself schedule `qcom_smbx` work whenever TCPM
properties change. A PD contract can disappear without a physical disconnect,
leaving a stale 1.5 A override until another charger event happens.

#### Fix

Register a `power_supply_reg_notifier()` and immediately reschedule policy work
when the referenced TCPM supply reports `PSY_EVENT_PROP_CHANGED`. While the
active source is the TCPM fallback, revalidate every 10-30 seconds as a safety
net. On any missing/invalid capability, immediately restore the safe/default
limit. AICL protects against electrical collapse but does not replace USB
protocol current compliance.

### 7. Cached ICL can become stale

The patch skips programming when `requested_icl_ua` and `icl_source` match the
cached policy. However, `CURRENT_MAX` remains writable and can change the
hardware register without updating that policy cache. Later work can therefore
believe 1.5 A is active while hardware contains a different value.

#### Fix

Prefer making `CURRENT_MAX` read-only on this device unless userspace ICL control
is required. Otherwise read back the real ICL and override state before taking
the early return. Removing the optimization entirely is reasonable: correctness
is more important than avoiding an occasional PMIC register write.

### 8. Deep-discharge protection is missing

On August 23, external input was unavailable and the logger recorded about 81
minutes below the 3.4 V design minimum, reaching a reported 2.532 V before
logging stopped. QGauge clamps its displayed level to 0% but does not shut the
system down.

The 2.532 V value is a software/gauge observation and should not be presented as
a calibrated direct cell-terminal measurement. It is nevertheless a serious
operational warning. The OS should stop well before a battery protection board
has to disconnect the cell.

#### Fix: dedicated battery-safety service

Implement a continuously running service separate from the charge-cap timer.
It should monitor `voltage_avg`, `voltage_now`, battery current, temperature, and
actual input/TCPM presence every roughly five seconds.

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

Tune these starting thresholds only after controlled testing with the actual
replacement battery and server load. Log every state transition and make the
service fail safe when required sensor values are unavailable.

### 9. Telemetry collection is good; integration uses the wrong clock

The five-second TSV collector records battery, charger, TCPM, Type-C, epoch,
ISO-8601, and monotonic uptime data. It leaves unavailable values empty and the
report correctly uses trapezoidal mAh/mWh integration and rejects long gaps.

The report nevertheless calculates `dt` from wall-clock epoch. RTC correction or
NTP steps can corrupt totals even though monotonic uptime is already recorded.

#### Fix

1. Add `/proc/sys/kernel/random/boot_id` to every telemetry row.
2. Use `uptime_s` for integration deltas.
3. Integrate only when the boot ID is unchanged and
   `0 < current_uptime - previous_uptime <= MAX_GAP_SECONDS`.
4. Start a new segment on boot-ID change or uptime reset.
5. Keep epoch/ISO time for human correlation only.
6. Rename SMB fields to `usb_input_voltage_uv`, `usb_input_current_ua`, and
   `usb_input_current_limit_ua` so they cannot be confused with battery current.

The report should continue integrating QGauge battery current, not charger input
current.

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

### 13. k3s core networking is blocked by nftables

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

#### Fix

Add explicit, least-privilege nftables rules for the k3s pod CIDR and interfaces.
At minimum, permit pod traffic from `cni0` to the host Kubernetes API after DNAT
and permit required forwarding from the pod network. Include Flannel rules only
if multi-node/VXLAN traffic is intended.

Do not broadly trust all CNI traffic without reviewing which host services pods
may reach. After changing the policy, require:

```text
kubectl get pods -A -> all core pods Ready
pod -> 10.43.0.1:443 succeeds
pod DNS resolution succeeds
pod egress succeeds
host and LAN firewall behavior remains restricted as intended
```

### 14. `qbootctl.service` causes degraded system state

The only failed system unit was `qbootctl.service`:

```text
No slots found, is this an A/B device?
```

The port boots through U-Boot/systemd-boot from userdata rather than using the
Android A/B boot-success flow, so this appears non-fatal.

#### Fix

Confirm that no supported update path relies on qbootctl, then mask/disable the
unit for Phoenix or remove the unnecessary package dependency. Document the
decision so a future boot/update change does not silently lose slot handling.

### 15. The EFI filesystem was not cleanly unmounted

The kernel reported that the FAT volume mounted at `/boot` was not properly
unmounted and recommended `fsck`.

#### Fix

Back up the ESP, boot into a maintenance environment or otherwise ensure it is
not mounted read/write, then run the appropriate FAT filesystem check. Investigate
power-loss shutdowns and complete the low-voltage shutdown work so this does not
recur. Do not repair a mounted FAT filesystem in place.

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

#### Fix

Treat these as separate tracked workstreams. Do not remove
`adsp-disable-recovery.service` until the sensor PD firmware/registry failure is
actually fixed. Re-test Wi-Fi/Bluetooth in an intentionally enabled state before
claiming the live server image has them operational.

### 17. Type-C/hub power state needs operational monitoring

At inspection the TCPM source supply was online at 5 V/3 A while the SMB charger
was offline and battery current was negative. The phone was powering the hub,
not receiving charger power. The existing rescue service does not intervene
until the voltage-derived level falls below its configured 30 threshold.

#### Fix

Expose an alert whenever the intended always-powered server is in source role,
the charger is offline, and battery current remains negative. Keep the Type-C
recovery mechanism, but do not rely on a late 30% threshold as the primary
unattended protection; the low-voltage shutdown service remains mandatory.

## Security findings

### 18. Development convenience creates a large trust boundary

The image installs general passwordless sudo/doas for the default user and uses
a simple SSH password. The LAN-facing device also exposed:

- SSH on 22
- the device monitor on 7070
- Kubernetes API on 6443
- kubelet on 10250
- a Cloudflare-related listener on 20241

The package also broadly trusts `eth*` input traffic. A compromise of the user
account is effectively a root compromise.

#### Fix

1. Install an SSH key and disable password authentication after recovery access
   is verified.
2. Replace general passwordless privilege with narrowly scoped commands or
   require authentication.
3. Bind Kubernetes/kubelet endpoints only where needed and restrict them by
   firewall and authentication policy.
4. Replace blanket `eth*` trust with explicit service/port rules.
5. Review the Cloudflare tunnel configuration and container restart history.
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
conditions were not approached, and Linux currently observes SMB5 over-voltage
through the wrong register. Continue using the battery with monitoring, but
complete the P0 fixes before treating the device as a finished unattended
always-powered server.

## External references

- [Linux power-supply sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-power)
- [August 20, 2026 SMB5 v4 patch](https://lkml.iu.edu/2608.2/07902.html)
- [Qualcomm downstream SM7150 BMS implementation](https://android.googlesource.com/kernel/msm.git/+/0bdc64f155814eb6a109d0ec9e3965c821da5853/drivers/power/supply/google/sm7150_bms.c)
- [Qualcomm downstream QGauge-related history](https://android.googlesource.com/kernel/msm/+/9bc512676061161105fa95ccf40532f625c05b7e%5E2..9bc512676061161105fa95ccf40532f625c05b7e/)
