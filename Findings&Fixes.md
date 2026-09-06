# Phoenix postmarketOS findings and fixes

This document consolidates the repository review, the live audit of the Phoenix
device initially at `192.168.1.101` and later at `192.168.1.117`, and the battery/charging safety review performed on
the `feat/phoenix-battery-charging-safety` work before it was merged to `main`.

The initial inspection was read-only. On September 4, 2026, the safe userspace
and firewall fixes were staged and tested on the device. On September 5, 2026,
patches 0010+0011 and the r25 userspace package were built into a complete
postmarketOS image in an ARM64 Docker Desktop Linux VM and flashed successfully.
The post-flash results and the subsequent r26/r5/patch-0012 work are recorded
first below; older audit sections remain as chronology and may describe a
superseded state. Values are observations from this test device, not guarantees
for every Phoenix, battery, charger, cable, or USB-C hub.

## Implementation and test status — September 5, 2026

### Live headless-server and dock-charging validation — September 5–6, 2026

The device is now configured and verified as an SSH-managed headless server.
Its default boot target is `multi-user.target`, `greetd` is stopped and
disabled, and `phoenix-screen-off.service` is enabled. Live sysfs verification
showed backlight brightness `0` and panel power `0`, while `sshd` remained
active, `eth0` remained up at `192.168.1.117`, charging continued, and
`systemctl --failed` was empty. Device package r27 makes those choices the ROM
defaults; the GUI packages may remain installed but are not started.

The cold-boot dock recovery is also hardware-verified. On the current boot,
`phoenix-usb-host-wake.service` waited 45 seconds, found `eth0` absent, toggled
the DWC3 role switch, and logged that Ethernet appeared two seconds later. The
next image enables this service by default so an already-attached dock no
longer requires a physical replug after boot.

The apparent failure to charge during the following ten-hour interval was not
a charger fault: the user confirmed that neither the charger nor the Type-C
dock was connected during that period. Once reconnected, TCPM established an
explicit 9 V / 2.45 A PD contract and charging resumed. A temporary
`phoenix-charge-to-full` monitor now keeps CPU frequency control on `schedutil`
to reduce idle load and restores `performance` automatically when the
voltage-derived capacity reaches 100% or the charger reports `Full`.

Additional live SMB5 investigation produced and validated patches 0013–0017:

- 0013 corrects `USBIN_LOAD_CFG` from the wrong `0x65` offset to SMB5's
  `0x365` offset and reruns AICL when entering or increasing a software
  override;
- 0014 adds Phoenix's Qualcomm PS_HOLD restart device and orders the
  `msm-poweroff` restart handler ahead of PSCI. The handler binds on hardware;
  a complete unattended restart still needs a long-duration test because
  modem/GLINK shutdown timeouts delay the final restart by several minutes;
- 0015 applies the high-current software override to trusted APSD CDP/DCP
  sources as well as the guarded TCPM fallback. Live register `0x1365` changed
  from `0xa5` to `0xb5`, proving the override bit was applied;
- 0016 programs the documented continuous 5–12 V SMB5 adapter allowance. The
  dock supplied about 8.9 V while firmware's discrete allowance asserted
  `USBIN_OV`. With 0016, register `0x1360` became `0x0c`, `USBIN_OV` cleared,
  charge state changed from `PAUSE_CHARGE` to full-on charging, and battery
  current became positive without disabling AICL or raising the 1.5 A policy
  ceiling;
- 0017 adds four bounded 15-second rechecks after a transient offline/error
  power-path reading. This fixes the observed case where a live module/package
  replacement selected the 500 mA safe default before the attached dock had
  settled and then waited hours for another TCPM notification. A genuinely
  unplugged phone is not polled indefinitely.

The complete 0012–0017 kernel package was built successfully and installed on
the device. The installed `qcom_smbx.ko.zst` SHA-256 is
`20e4a851f55c87c8e7ae443da289f2eb2185a39aff3e92ed7b49ac8ea890736b`.
Temperature during the live 9 V test remained normal (roughly 31–36 C). AICL
may settle below the programmed 1.5 A ceiling when the hub/cable path or system
load requires it; this is expected protection behavior and must not be bypassed.
Patch 0017 compiled and loaded cleanly; the final re-probe immediately selected
the 1.5 A TCPM policy, so its bounded retry path was not artificially forced.

The matching headless r27 ROM was then built successfully:

```text
/Users/ankitpipalia/Git/phoenix-sm7150-postmarketos-port/artifacts/xiaomi-phoenix-20260906-r27-headless.img
size:   3,897,556,992 bytes
sha256: ae782df0389895f83a064e6f1e460dd3c8989cdd0fb9c1225f3d9546e7ed4e31
```

The image uses 4096-byte logical sectors. Both primary and backup GPT headers
are present at the correct locations. Read-only `fsck.fat -n` found 23 files
and no errors; `e2fsck -fn` completed all five passes cleanly. Read-only mounted
inspection confirmed device package `1-r27`, the final kernel module hash,
`default.target -> multi-user.target`, `greetd` disabled by preset, and enabled
`phoenix-screen-off` and `phoenix-usb-host-wake` wants links. This image has not
been flashed yet.

### Post-flash hardware validation and follow-up fixes

The r25 image boots the intended Xiaomi POCO X2 device tree on
`7.1.0-rc3-sm7150` (build timestamp September 5, 2026). The expanded 106.6 GiB
root filesystem is clean, the system reached the running state with no failed
units, and the standard SMB5 `charge_behaviour` control works on hardware.
Writing `inhibit-charge` changed charger status to `Not charging` while the USB
input remained online; writing `auto` restored normal behavior. This validates
the central architectural fix in patch 0010: charge inhibition no longer
disconnects external system power.

The currently attached Type-C dock and Apple PD supply negotiated an explicit
9 V, 2.45 A PD contract (about 22 W capability), but qcom_smbx retained its
500 mA safe-default ICL. This was not evidence of a weak charger or a nominal
100 W dock-path problem. It exposed an internal policy contradiction: the
Phoenix connector advertises a 5-12 V, 15 W sink, while the guarded fallback
accepted only 4.75-5.5 V. New patch 0012 keeps non-PD Type-C restricted to the
5 V range, accepts only explicit PD contracts up to the advertised 12 V, and
caps the request to the minimum of source capability, 1.5 A, hardware maximum,
and 15 W. At the observed 9 V contract the requested ceiling remains 1.5 A;
at 12 V the 15 W cap reduces it to 1.25 A. Hardware AICL and
suspend-on-collapse remain enabled. Patch 0012 applies cleanly and the complete
kernel package compiles and verifies, but its 9 V behavior still requires the
planned reversible module test and subsequent flash.

Wi-Fi did not initially create `wlan0`. The live device had the required
`qcom,snoc-host-cap-8bit-quirk`, but lacked the `rmtfs` service and had only a
Davinci entry in `board-2.bin`; its actual QMI identity was chip `0x30214`,
board `0xff`. Installing and enabling `rmtfs`, retaining patch 0006's non-fatal
host-capability handling, and supplying Xiaomi Phoenix's stock
`NON-HLOS.bin:/image/bdwlan.bin` allowed initialization to pass the board-file
lookup. The packaged blob is 19,152 bytes with SHA-256
`b740afea00b3b6c63049c599b80dd9bd50306b1c63708c9636a80908e4a2a667`.
Repeated driver rebinding then returned QMI error 90
(`QMI_ERR_INCOMPATIBLE_STATE`) at MSA info, which is consistent with retrying
that one-time handshake after firmware state had already advanced; it is not a
sound reason to ignore the error in the driver. A clean-boot WLAN result remains
pending because the already-attached dock did not re-enumerate Ethernet after
the software reboot. The r26 device package now depends on `rmtfs` and
`rmtfs-systemd`; the r5 firmware builder requires and packages the exact Phoenix
`board.bin`. `pd-mapper` is deliberately not added: it found no PD maps and
crash-looped during the live experiment.

The dock's HDMI output remains unsupported in this configuration. The Type-C
class exposed no alternate modes, USB enumerated only the dock's USB 2.0 hub and
Ethernet function, and DRM exposed no external DP/HDMI connector. Passive dock
HDMI requires DisplayPort Alt Mode; dock power rating and PD passthrough do not
create that display path. The SoC can support optional USB-C DisplayPort, but
Phoenix board wiring and a complete Type-C/DRM alt-mode description are still
unverified, so no speculative HDMI DT change has been made.

The installed disk is usable but reports that its backup GPT header remains at
the original image boundary after rootfs expansion. The filesystem itself is
clean. Repair must back up the current table and move only the secondary GPT
header to the physical end of `/dev/loop0`, followed by `sgdisk -v`; this live
maintenance remains pending device reconnection.

The updated kernel, firmware, and device APKs all built successfully in the
existing ARM64 Docker builder. Package inspection confirms that firmware r5
contains the exact board calibration and device r26 declares both rmtfs
dependencies. Repository battery and synchronization tests pass. A fresh
combined image was then installed end-to-end and exported as
`/Users/ankitpipalia/Git/artifacts/xiaomi-phoenix-20260905-r26.img`
(3,897,556,992 bytes; SHA-256
`5a7264dea5aac5c6b35a36d32e552d3775aa9989d1a0e794bbcaad31e03dc248`).
Read-only `fsck.fat -n` reports 23 files with no error, and `e2fsck -fn`
completed all five passes cleanly. This r26 image has not yet been flashed.

### Read-only repository and connectivity audit — 2026-09-05 01:44 IST

The repository was re-audited without modifying the worktree or the device.
`main` was clean at `d96d336`, exactly matched `origin/main`, and was the only
local or remote branch. The device package was `pkgrel=24`; its 33 APKBUILD
source names matched its 33 checksum-entry names. All shell scripts parsed with
their declared interpreter. Commits `0aade85`, `fa61de3`, and `d96d336` passed
`git show --check`; the earlier kernel-patch commits `ac29288` and `5bf00e5`
still contain non-functional whitespace warnings inside patch text.

The audit found four open implementation defects that must be fixed and tested:

1. The pmaports sync helper uses the combined old/current patch list for both
   removal and insertion. It can re-add stale patches to `source=` and can append
   `dummy` checksum records to `sha512sums`.
2. `phoenix-charge-cap.sh reset` validates QGauge voltage before processing the
   reset request, so missing/invalid gauge data can leave an owned
   `inhibit-charge` state active. The oneshot unit also has no `ExecStop` or
   separate reset unit wired to timer shutdown.
3. The telemetry log selector is capped at `-v4`. If base, v2, v3, and v4 all
   have incompatible headers, a current-schema row is appended to the existing
   incompatible v4 file.
4. Type-C recovery falls back to capacity only when a readable voltage file
   contains invalid data. It does not use capacity when both voltage files are
   absent or unreadable.

USB and LAN connectivity were also checked read-only. Neither
`172.16.42.1:22` nor `192.168.1.101:22` was reachable. No USB network or serial
gadget enumerated on the workstation, the candidate USB Ethernet interfaces
were inactive, and `172.16.42.1` followed the normal LAN default route instead
of a USB subnet route. SSH did not reach authentication, so no device-side
claims below were revalidated during this audit.

The earlier live notes contain timestamps through `2026-09-06 00:05 UTC`, which
are later than this workstation audit clock. They are retained below as prior
device-recorded observations, not as independently verified chronology. Compare
workstation UTC, device UTC, uptime, and boot ID at the next successful login.

### Review4 fixes and completed image build — repository r25

All four implementation defects found by the read-only audit are fixed locally:

- charge-cap reset is processed before threshold and QGauge validation;
  `phoenix-charge-cap-reset.service` provides a packaged reset path that only
  releases inhibition owned by the limiter;
- telemetry now walks unbounded `-vN` filenames until it finds an empty file or
  matching header and never appends across schemas;
- Type-C recovery now checks capacity when voltage attributes are absent,
  unreadable, or invalid;
- pmaports synchronization now has separate removal/insertion inputs, never
  emits dummy checksums, preserves unrelated patch checksums, and is idempotent.

`tests/test-battery-tools.sh` and `tests/test-sync-phoenix-port.sh` pass. The
device APKBUILD source/checksum names and all file hashes validate, and the
package release is now r25.

The flashable ROM is now **built and filesystem-checked**. Docker Desktop
29.7.2 supplied an ARM64 Linux 7.0.12 VM on the Apple Silicon host. The builder
must be privileged so pmbootstrap can use mounts and loop devices, and its
`.pmbootstrap` work directory must live on a native Docker volume. Keeping the
chroot on the macOS VirtioFS bind mount caused GNU tar to fail while unpacking
the Linux tree (`Directory renamed before its status could be extracted`). The
native volume removed that failure. Docker's LinuxKit kernel also has
`loop.max_part=0`, so a short build-host watcher had to create
`/dev/loop0p1`/`loop0p2` from the dynamic major/minor values exposed in sysfs
after `partprobe`.

Apple Container 1.3.1 was also started successfully. A persistent
`phoenix-builder` Alpine machine with 6 CPUs and 6 GiB RAM can see the host home
directory and, when commands run with `container machine run --root`, has
working tmpfs mounts and loop devices. It is a viable backup Linux builder;
Docker was retained for the active build to avoid restarting the completed
work.

The proprietary package was reconstructed from authoritative matching inputs:

- Xiaomi Firmware Updater's exact 84.9 MB V13.0.6.0 SGHCNXM firmware package
  supplied `NON-HLOS.bin`; its downloaded MD5 was the published
  `eb25b9fe1b838b4bacb763f5e83d2d6f`.
- ADSP, CDSP, modem, Venus and WLAN images came from that `NON-HLOS.bin`.
- Phoenix `a615_zap` and `ipa_fws` segments came from the
  `xiaomi-sm6150/proprietary_vendor_xiaomi_phoenix` lineage-23.0 tree, whose
  relevant commit states that it was pulled from 13.0.6.0 stable.
- The Novatek FW01 binary was converted from the matching LineageOS Phoenix
  kernel's Intel HEX firmware.

`scripts/build-firmware-tarball.sh` accepted all eight required blobs and
created a deterministic 46 MiB archive. `firmware-xiaomi-phoenix` is now r4 and
pins SHA-512
`4adf923758500caab261f19fc9d3dd020a37cd06e36fb8d68714d8ed24779ff691ec010b3b4b57cfec0eb7050530be7f67ffdab86e2ae1233aa37d09c47658b0`.
The kernel, firmware and device packages all completed through pmbootstrap,
followed by a successful Phosh/systemd image install for user `user`.

Build artifact:

```text
/Users/ankitpipalia/Git/artifacts/xiaomi-phoenix-20260905.img
size:   3,896,508,416 bytes
sha256: b9ce18f09c046904075f12096d1e236c4a8fb4ed5a47bb5c948dad3aff16af18
```

Read-only `fsck.fat -n` found a valid boot filesystem with 23 files, and
`e2fsck -fn` completed all five passes on `pmOS_root` without errors. The staged
rootfs contains `sm7150-xiaomi-phoenix.dtb`, the Phoenix Adreno and Novatek
firmware, and `phoenix-charge-cap-reset.service`.

Matching later-flash artifacts are also prepared under
`/Users/ankitpipalia/Git/artifacts/`:

| Artifact | SHA-256 |
| --- | --- |
| `u-boot-sm7150-xiaomi-davinci-samsung.img` | `a18bf172a03dd8532da85775600c36813cd0128552ca83ac58000f5c787ecd36` |
| `vbmeta.img` | `627cbb821516c3e90184ff8d9193436dbfc5ded5d683a8c6761130c1df952f0f` |
| `vbmeta_system.img` | `590ea129afb32c8b8a4292012ec1ed8799a4c901951c8f8f1015c6f8d2d47875` |

The stock fastboot archive itself matched Xiaomi's published MD5
`edf8a2c9f63046c2a32c0028b57f0f61`. No device was flashed during this build.

### Prior review3 implementation snapshot

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
| Charge-cap reset lifecycle | Fixed in r25: reset precedes gauge/threshold checks; dedicated reset unit packaged | Local regression test passes with QGauge absent and invalid thresholds; hardware test pending |
| Telemetry schema rollover | Fixed in r25: unbounded version selection chooses only an empty or matching-schema file | Local base-through-v4 mismatch test creates v5 and leaves v4 unchanged |
| Type-C capacity fallback | Fixed in r25: missing/unreadable/invalid voltage all reach capacity fallback | Local missing-voltage/low-capacity test reaches the guarded sink attempt |
| pmaports patch-manifest cleanup | Fixed in r25: removal and insertion sets separated; AWK membership no longer deletes unrelated patch checksums | Two-run fixture is idempotent, removes stale entries, preserves unrelated entries, and emits only valid SHA-512 records |
| llama.cpp inference | CPU is feasible; Turnip/Vulkan is the best first accelerator candidate; OpenCL and Hexagon are later research | **Not runtime-verified:** prior audit saw `/dev/dri/card0` and `renderD128`, but Vulkan enumeration, package availability on the configured repositories, performance, stability, memory pressure, and thermals remain untested |

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

1. Install the rebuilt kernel containing patches 0010+0011 and prove that `charge_behaviour=inhibit-charge` leaves USB input `online=1` while battery current settles near zero. **Prior live note:** the May kernel still lacked `charge_behaviour`; new `0011` fixes float selector, watchdog base, OV notify, ICL ordering/log and revalidation robustness are compile-tested and device-logic-tested (0.847 mWh, thermal fail-open, Vnow emergency), but not yet flashed.
2. Run controlled low-voltage/source-loss and thermal-input tests before treating the shutdown guard as production-validated. **Live 2026-09-06:** the user requested activation after the charge-inhibition test, so the guard is now `enabled` and `active` with `DRY_RUN=0`. Synthetic tests cover independent channels (`temp 500` with invalid voltage fires, `voltage_now 3300000` vs `voltage_avg 3500000` triggers emergency), sensor-failure policy (12 samples logs + conservative shutdown), and `ConditionPathExists` removed (`Restart=always`); real source-loss at the configured threshold is still pending.
3. Exercise SMB5 over-voltage/thermal status reporting and all TCPM source transitions on hardware. **Live:** patches 0010+0011 compile-tested; `dmesg` still old `SMB5 Generation SMB5` without OV fix until flash; `health=Good` cannot validate OV until kernel upgrade. Validate with synthetic register instrumentation, not real OV.
4. Revalidate the installed r24 device package, `20-phoenix-optional.preset`, and env-override handling after connectivity is restored. **Prior live notes:** r21 and then r22 were installed and preset `ignore` preserved the opt-in state; a later note reports r24 installed. These observations were not rechecked in the 2026-09-05 read-only audit because neither SSH path was reachable.

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
| Repository package | `device-xiaomi-phoenix-1-r25` (`pkgrel=25`; review4 reset, telemetry rollover, Type-C fallback and sync fixes included) | `device-xiaomi-phoenix-1-r20` |
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

1. Build and flash a fresh image from current `main` (now r25 + 0010+0011), or upgrade the kernel and
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
| **P1** | Rebuild/flash the current r25 package and kernel (0010+0011) as one tested image; userspace is logic-tested and the kernel is compile-tested, but the combination is not hardware-validated |
| **P1** | Implemented and locally tested in r25: charge-cap reset is independent of QGauge/threshold validity; dedicated reset unit documents the safe disable path |
| **P1** | Implemented and locally tested: pmaports sync separates stale removal from current insertion and preserves unrelated patch checksums |
| **P1** | Implemented and locally tested: telemetry rollover selects an unbounded safe version without modifying mismatched files |
| **P1** | Implemented and locally tested: Type-C capacity fallback handles absent/unreadable/invalid voltage attributes |
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

#### Reset-lifecycle defect fixed in r25

The script formerly checked `qcom_qg/voltage_now` and parsed a valid voltage
before handling `reset`, which could leave an owned inhibit active. Reset now
runs immediately after locating the writable `charge_behaviour` attribute and
does not depend on voltage, source state, or normal threshold validity. A
dedicated `phoenix-charge-cap-reset.service` is packaged because `ExecStop` on
the recurring oneshot would not provide correct timer semantics. Safely disable
and release the limiter with:

```sh
systemctl disable --now phoenix-charge-cap.timer
systemctl start phoenix-charge-cap-reset.service
```

The ownership marker remains authoritative: reset with no marker leaves an
external controller's inhibit untouched. Both cases and missing-QGauge reset
are covered by the local regression suite; hardware validation remains pending.

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

#### Schema-rollover defect fixed in r25

Schema rollover was hard-coded through `-v4`, allowing a new-format row to be
appended to an incompatible v4 file. The collector now loops through unbounded
`-vN` candidates and selects only a matching non-empty file or a new/empty file.
The regression test creates incompatible base, v2, v3 and v4 files, verifies v4
is unchanged, and verifies that v5 receives exactly one header and one sample.

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

#### Missing-voltage fallback defect fixed in r25

The capacity fallback was nested inside the condition that at least one voltage
attribute was readable. Voltage selection now tries average and instantaneous
attributes independently, accepts the first valid value, and checks capacity
whenever neither produces a valid sample. Missing-voltage plus low-capacity is
covered by a local regression test. Invalid or unavailable capacity still fails
closed without changing the Type-C role.

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

## Repository tooling finding

### 19. The pmaports sync helper conflates removal and insertion sets

The sync script correctly saves the previous Phoenix patch manifest, but then
combines old and current names and passes that combined file to
`update_source_block()`. That function uses every input entry both as a removal
target and as an entry to append. A patch removed from the current repository
can therefore be inserted back into the destination APKBUILD. The checksum path
has the same structural problem: `dummy  <old-patch>` records are added to the
list consumed by `update_sha512_entries()`, which appends every list record.

#### Implemented fix in r25

The helper now uses two explicit inputs for both transformations:

- removal set: previous manifest plus current manifest;
- insertion set: current patch names/checksums only.

Removal-only checksums are no longer represented as appendable dummy records.
The AWK membership check was also corrected so probing a name does not create an
empty array entry and subsequently remove every unrelated `.patch` checksum.
The integration fixture contains an unrelated upstream patch, a stale Phoenix
patch, and the current Phoenix patch set. Two consecutive sync runs are
idempotent; the unrelated patch remains, the stale patch is absent, and every
appended checksum is a real 128-hex-character SHA-512 value.

## llama.cpp feasibility and maximum-performance plan

### 20. Corrected feasibility verdict

The POCO X2 hardware is capable of running llama.cpp, but acceleration must be
proved on this port rather than inferred from the Android product
specification.

| Backend | Assessment for this device |
| --- | --- |
| CPU | **Proven.** An ARMv8.2 + dot-product + FP16-vector build of the XHToken Spark fork loads Spark-X2.5-1.7B Q8_0 with a 131,072-token Q8 KV cache and generates valid output. |
| Vulkan/Turnip | **Enumeration proven; Spark inference blocked.** Mesa Turnip and llama.cpp enumerate Adreno 618, but the Spark-enabled Vulkan backend rejects it because the device does not expose 16-bit storage. CPU-only mode must explicitly use `--device none`. |
| OpenCL | **Experimental follow-up.** Qualcomm advertises OpenCL for the SoC, but that describes the platform/proprietary stack. It does not prove a usable OpenCL compute implementation under mainline Linux and Mesa on this phone. |
| Hexagon/HTP | **Not a practical current target.** The SoC has Hexagon 688 and the port starts CDSP, but current llama.cpp HTP artifacts are documented for newer v73/v75/v79/v81 targets, not this generation. Firmware, FastRPC and a running remoteproc alone do not establish backend compatibility. |

Qualcomm documents the Snapdragon 730G as an eight-core Kryo 470 design with
two performance and six efficiency cores, up to 2.2 GHz, an Adreno 618 GPU,
Hexagon 688, Vulkan 1.1 and OpenCL 2.0 FP. Those are SoC capabilities, not a
guarantee that every mainline driver/API path is operational. See the
[Snapdragon 730G product brief](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/qualcomm-snapdragon-730g-mobile-platform-product-brief.pdf).

Mesa documents Turnip as a Vulkan 1.3 driver for Adreno 6xx and documents
Adreno as unified-memory hardware. The GPU therefore has no separate pool of
VRAM: model weights, KV cache, Vulkan buffers, the OS, k3s, containers and file
cache all compete for the same physical RAM. See the
[Mesa Freedreno/Turnip documentation](https://docs.mesa3d.org/drivers/freedreno.html).

The repository-specific prerequisites are encouraging but incomplete:

- the device tree enables `&gpu` and selects
  `qcom/sm7150/phoenix/a615_zap.mbn`;
- the firmware package also depends on the common Adreno A630 firmware;
- the prior live snapshot reports `/dev/dri/card0` and `/dev/dri/renderD128`,
  but the project README correctly labels 3D acceleration as untested;
- `vulkaninfo` now enumerates `Turnip Adreno (TM) 618`, Vulkan API 1.3.354,
  Mesa/Turnip 26.1.6, and the unprivileged account can use `renderD128`;
- packaged llama.cpp 0.2.0 lists both OpenBLAS and Vulkan, with the Vulkan
  device reporting 4096 MiB total and 3686 MiB free;
- Spark-X2.5 GPU inference is nevertheless unavailable: the Spark-enabled
  backend reports `device Vulkan0 does not support 16-bit storage` and fails
  model loading with `Unsupported device`.

### 21. Package claims verified, with an important repository caveat

Alpine edge currently publishes `mesa-vulkan-freedreno` for aarch64, providing
the Turnip Vulkan library. Its aarch64 llama.cpp package family includes
`llama.cpp-libs` and a `llama.cpp-vulkan` subpackage, and `vulkan-tools` provides
`vulkaninfo`. See the
[Alpine Freedreno Vulkan package](https://pkgs.alpinelinux.org/package/edge/main/aarch64/mesa-vulkan-freedreno),
[Alpine aarch64 llama.cpp libraries](https://pkgs.alpinelinux.org/package/edge/community/aarch64/llama.cpp-libs),
and [Alpine aarch64 Vulkan tools](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/vulkan-tools).

Do not assume those exact packages are installable until the device reports its
configured branch and enabled `community` repository. Package versions and
subpackage layout can change on edge. Run discovery first:

```sh
cat /etc/alpine-release
sed -n '1,120p' /etc/apk/repositories
apk policy mesa-vulkan-freedreno vulkan-loader vulkan-tools \
  llama.cpp llama.cpp-cpu llama.cpp-vulkan
```

If all candidates resolve for aarch64, the initial packaged installation is:

```sh
sudo apk add mesa-vulkan-freedreno vulkan-loader vulkan-tools \
  llama.cpp llama.cpp-vulkan
```

Use the distribution build for the first reproducible comparison. A custom
native build may be tested later, but only after preserving the package version
and baseline results. Upstream documents Vulkan builds with
`-DGGML_VULKAN=ON` and full layer offload with `-ngl 99`; see the
[llama.cpp build documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).

### 22. Required zero-load hardware validation

Before loading a model, record:

```sh
uname -a
uname -m
free -h
grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo

ls -l /dev/dri
ls -l /usr/share/vulkan/icd.d 2>/dev/null
apk info | grep -E 'llama|mesa|freedreno|vulkan'
vulkaninfo --summary 2>&1

dmesg | grep -Ei 'msm|adreno|a6[0-9][0-9]|gmu|gpu|iommu|fault'
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  printf '%s ' "${cpu##*/}"
  cat "$cpu/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo unknown
done
```

Success requires a hardware Adreno/Turnip Vulkan device, not `llvmpipe` or
another software Vulkan implementation. Also confirm that the unprivileged
llama.cpp service account can open `renderD128`; adding broad root privileges is
not an acceptable GPU fix. Check `dmesg` after `vulkaninfo` for GPU/IOMMU faults.

Only then run:

```sh
llama-cli --version
llama-cli --list-devices
llama-bench --help
```

Record exact package versions, llama.cpp build/commit, Mesa version, Vulkan
driver/device names, kernel build, boot ID and model SHA-256 with every result.

### 23. Model and memory policy for 5.4 GiB usable RAM

The earlier device audit reported about 5.4 GiB usable memory. A model file's
size is not its complete runtime footprint: add KV cache, compute buffers,
backend allocations, page tables, the OS, and existing server workloads.
Turnip's unified memory does not create additional VRAM.

| Model class | Approximate Q4 weight range | Recommendation |
| --- | ---: | --- |
| 0.5-1B | 0.4-0.8 GB | Best smoke test and tuning model |
| 1-1.5B | 0.7-1.2 GB | Best likely always-on class |
| 2-3B | 1.3-2.3 GB | Practical candidate after monitoring RAM and thermals |
| 7-8B | 4-5 GB | Not an acceptable always-on target with 5.4 GiB usable RAM and existing services; likely to swap or OOM once runtime buffers and context are included |
| 14B and larger | 8 GB and above | Out of scope |

These are planning ranges, not promises; architecture and quantization change
the exact size. Begin with a 0.5-1.5B instruct GGUF in Q4_0 and Q4_K_M variants,
with one request slot and a 2048-token context. Increase to 3B only after
capturing peak resident memory and `MemAvailable`. Do not use a 7B model merely
because its GGUF can be mapped: reliable service operation needs headroom and
must not depend on compressed swap/zram thrashing.

The Snapdragon Linux example in llama.cpp uses Llama 3.2 3B Q4_0, but that page
is specifically a newer Snapdragon/Hexagon deployment workflow and is not proof
that Phoenix's Hexagon 688 is supported. See the
[llama.cpp Snapdragon Linux guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/linux.md).

### 24. Benchmark before choosing CPU or Vulkan

`-ngl 99` requests maximum layer offload; it does not guarantee maximum speed.
An older mobile GPU without modern matrix hardware can lose to CPU because of
kernel efficiency, dispatch overhead, unsupported operations, thermal limits,
or driver behavior. Partial offload can also be worse than either endpoint.

Use the same local model, prompt/generation sizes and cool starting temperature
for every run. Start with this matrix:

```sh
# CPU baseline: discover the best thread count rather than assuming six.
for threads in 1 2 4 6 8; do
  llama-bench -m model.gguf -p 512 -n 128 -r 3 -t "$threads" -ngl 0
done

# Vulkan: compare none, partial and full offload using the best CPU thread count.
for layers in 0 1 8 16 99; do
  llama-bench -m model.gguf -p 512 -n 128 -r 3 -t BEST -ngl "$layers"
done
```

Replace `BEST` with the measured CPU winner. If the model has fewer than 16
layers, choose partial values appropriate to its actual layer count. Run a
second warm pass because Vulkan shader/pipeline cache creation can distort the
first result. Record both prompt-processing and token-generation throughput;
they can favor different backends.

Next sweep conservative batch/microbatch values such as 128/64, 256/128 and
512/256. Do not start at a very large batch on Adreno: excessive allocation can
cause device loss or OOM. Keep context at 2048 until the backend is stable, then
test 4096 while measuring memory. Test CPU affinity only after mapping maximum
frequency per logical CPU; compare the two performance cores, all cores, and
the scheduler default rather than assuming `-t 6` maps to the desirable cores.

For a single-user service, begin with one parallel slot. More slots raise KV
cache and working-set memory and may reduce interactive token rate. A sensible
first server profile after benchmarking is conceptually:

```sh
llama-server -m model.gguf -c 2048 -np 1 -t BEST -ngl BEST_NGL \
  --host 127.0.0.1 --port 8080
```

Bind to loopback initially. If remote access is required, put it behind an
authenticated reverse proxy and explicit firewall rule; do not expose an
unauthenticated inference endpoint merely to gain convenience.

### 25. Optimize for safe sustained performance

Maximum useful performance on a phone is the highest repeatable throughput
after thermal equilibrium, not the first boosted run. Do not disable thermal
zones, cooling devices, kernel throttling, battery guards, or charger safety.
Do not force permanent maximum CPU/GPU clocks until the thermal controls have
been validated under combined CPU/GPU load.

For every candidate configuration, run at least 15-30 minutes while recording:

- prompt and generation tokens/second over time;
- `MemAvailable`, process RSS, swap/zram use and OOM events;
- all available thermal-zone temperatures;
- per-policy CPU frequency and GPU devfreq, where exposed;
- QGauge voltage, current and temperature plus charger/TCPM state;
- GPU faults, hangs, resets and IOMMU errors from the kernel log;
- whether k3s, networking and telemetry remain responsive.

Use active external cooling and an unobstructed enclosure if continuous load is
intended, but keep the battery within the project's validated safety envelope.
Benchmark once with nonessential containers/k3s stopped to establish hardware
potential, then again with the normal service workload. Any service changes
must be deliberate and reversible; the production number is the second result.

### 26. OpenCL and Hexagon are later experiments

The current official llama.cpp OpenCL documentation is aimed first at Qualcomm
Adreno, but its verified list contains much newer GPUs. It warns that A6x phone
drivers/compilers are commonly too old; Phoenix instead uses Mesa, whose Rusticl
exposure and llama.cpp kernel performance would need separate proof. Vulkan is
therefore the cleaner first experiment. See the
[llama.cpp OpenCL backend documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md).

The experimental Hexagon backend currently documents NPU-side libraries for
v73, v75, v79 and v81. It does not document a Hexagon 688/v68 artifact. Do not
install Snapdragon HTP binaries for a mismatched architecture or reinterpret a
running CDSP remoteproc as compatibility. Treat Hexagon support as a separate
porting project requiring a confirmed architecture target, matching SDK/runtime
libraries, FastRPC behavior and upstream backend support. See the
[llama.cpp Hexagon developer documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/developer.md).

### 27. llama.cpp acceptance criteria

Do not call GPU acceleration working until all of these are recorded:

- `vulkaninfo` enumerates hardware Adreno through Turnip without GPU faults;
- llama.cpp lists the Vulkan device and loads a small GGUF successfully;
- generated output matches a CPU sanity run closely enough to detect backend
  corruption;
- repeated CPU, partial-offload and full-offload benchmarks identify the actual
  throughput winner;
- a 30-minute run reaches stable temperature without hangs, resets, OOM or
  unsafe battery behavior;
- peak memory leaves sufficient headroom for the normal server workload;
- the final service is unprivileged, authenticated if network-accessible, and
  constrained to the tested model/context/concurrency configuration.

### 28. Live Spark-X2.5 Q8_0 result — 2026-09-06

The requested Spark-X2.5-1.7B Q8_0 model is installed and its full 128K context
allocation has been proven on the POCO X2. This model uses the new `spark2_5`
architecture, which Alpine's packaged llama.cpp build does not contain. At the
time of testing, upstream Spark support was still an open llama.cpp change, so
the XHToken fork was built for Alpine aarch64 in a Docker container on the Mac
instead of compiling it continuously on the phone.

Installed artifacts:

```text
Runtime:       /home/user/opt/llama-spark
Source:        XHToken/llama.cpp
Source commit: 4a3635c32fc9f044c2bde9ebeabf50c7e1ec5991
Model:         /home/user/models/Spark-X2.5-1.7B-Q8_0.gguf
Model bytes:   1820112736
Model SHA-256: d9ac5d7374b07568fdcb3317cf6eff2b9afd2be6221f87347d12c11455eb5c4c
```

The runtime was compiled in an Alpine edge `linux/arm64` container with
OpenBLAS, Vulkan, and the target-safe CPU architecture
`armv8.2-a+dotprod+fp16+crypto+crc`. Building natively was abandoned after the
phone reached roughly 90-92°C even at reduced parallelism. The packaged
llama.cpp installation remains untouched as a fallback.

The validated 128K CPU command profile is:

```sh
LD_LIBRARY_PATH=/home/user/opt/llama-spark \
  /home/user/opt/llama-spark/llama-cli \
  -m /home/user/models/Spark-X2.5-1.7B-Q8_0.gguf \
  --device none -ngl 0 \
  -c 131072 -ctk q8_0 -ctv q8_0 \
  -t 8 -tb 8 -b 512 -ub 128 \
  --reasoning off -st --simple-io
```

Measured results from a short single-turn run:

```text
Context allocation:      131072 tokens
Model quantization:      Q8_0
K/V cache quantization:  Q8_0 / Q8_0
Maximum resident set:    4603932 KiB (~4.39 GiB)
Swap used by test:       0
Prompt processing:       ~21-22 tokens/s
Token generation:        ~5 tokens/s
Output sanity check:     Spark 128K ready
```

This proves that 128K can be allocated, but it leaves only a narrow memory
margin on a device with about 5.4 GiB usable RAM. Run only one inference slot,
keep K/V cache at Q8_0 or smaller, and do not combine this profile with another
large memory workload. The advertised 1M context is not practical here.

Vulkan offload is not currently viable for this model on Adreno 618. Both
automatic and requested GPU offload fail before inference because the Turnip
device reports no 16-bit storage support. `--device none` is required; `-ngl 0`
alone is insufficient because the runtime's automatic memory-fitting probe may
still attempt the Vulkan device.

Thermals, rather than raw compute, are the production blocker. A short
two-thread `llama-bench` pass measured 29.22 prompt tokens/s and 6.07 generation
tokens/s, but the hottest SoC zone rapidly reached about 89.9°C while both CPU
policies were using the `performance` governor. The wider benchmark was stopped.
Do not create an always-on service with these clock/governor settings until a
longer actively cooled test establishes a safe sustained profile. Maximum
production performance must be selected after thermal equilibrium, likely with
a dynamic governor and explicit concurrency of one.

### 29. TurboQuant Turbo4 and Phoenix LLM manager — 2026-09-06

Turbo4 is now implemented and live-tested for Spark-X2.5. This is **true
TurboQuant K/V-cache compression**, not an alias for llama.cpp's ordinary
`q4_0` cache and not a re-quantization of the model weights. The model remains
the requested Q8_0 GGUF. The runtime combines:

```text
TheTom/llama-cpp-turboquant  4a54c52074e6b1a0c585ebd7ee98cb0555ef060d
XHToken Spark2.5 support     6498507f5 through ae75169ae
combined build identity      b10723-1698a2f5e
target                       Alpine aarch64, ARMv8.2 dotprod/FP16, OpenBLAS
```

The reproducible Docker builder is
`scripts/build-llama-spark-turboquant.sh`. It keeps the distribution llama.cpp
and the earlier XHToken-only build untouched and installs the combined runtime
alongside them under `/home/user/opt/llama-spark-turboquant/bin`.

The Vulkan backend is deliberately disabled in this build. TurboQuant's fork
does contain evolving Vulkan kernels, but the phone's prior Spark validation
already proved that Adreno 618/Turnip lacks the 16-bit-storage feature required
by this runtime. Upstream llama.cpp also has open/closed reports of Turbo4
`SET_ROWS` failures in experimental Vulkan TurboQuant forks. CPU Turbo4 is the
validated path; labelling this profile as GPU accelerated would be incorrect.

#### Live Turbo4 results

| Test | Result |
| --- | --- |
| 2K direct CLI smoke test | Spark loaded with `-ctk turbo4 -ctv turbo4` and generated coherent reasoning/output |
| Full-context allocation | 131,072-token Turbo4 K/V profile reached `/health` ready |
| Full-context runtime RSS | 4,188,774,400 bytes (~3.90 GiB) immediately after load |
| Available RAM after load | ~2.47 GiB reported; no swap used |
| Manager chat prompt | 24 tokens at 19.81 tokens/s |
| Manager chat generation | 32 reasoning tokens at 5.28 tokens/s |
| Post-smoke hottest zone | ~54.5 C after the direct run; ~49 C after full-context load |
| Clean stop | Passed; process exited and available RAM returned to ~4.7 GiB |

Turbo4 did not create a dramatic end-to-end RSS reduction compared with the
earlier Q8-cache build because the 1.7 GiB Q8 model weights, runtime arenas,
prompt cache and other buffers dominate this measurement. Its expected benefit
grows with cache occupancy; allocation success alone is not a 128K-token needle
or quality test. A real long-prompt quality/perplexity comparison against Q8 K/V
is still required before Turbo4 becomes the default production profile.

#### Reimplemented device-native manager

The useful architecture from `~/Git/local-llm` has been reimplemented for this
Linux phone rather than copying its Apple-only MLX/Metal code. The new
dependency-free Python service owns exactly one heavy runtime and provides:

- validated Q8 128K, experimental Turbo4 128K, and fast 32K profiles;
- executable/model/memory/temperature preflight checks;
- a 128 MiB prompt-cache ceiling instead of the fork's unsafe 8 GiB default;
- readiness polling, persisted PID/command state, graceful process-group stop,
  restart, live logs, and a non-streaming OpenAI-compatible chat smoke test;
- a sustained-critical-temperature guard that stops inference after three
  consecutive 92 C samples;
- total/available/swap memory, process RSS, and every readable thermal zone;
- raw QGauge, SMB5 charger and TCPM attributes with explicit unit conversion;
- design voltage/capacity, voltage/current now and average, temperature, OCV,
  charge status/behaviour, learned capacity, effective ICL, USB type, source
  capability and actual input power;
- five-second voltage/current/temperature history and monotonic mAh/mWh
  integration, plus the existing boot-segmented historical telemetry report;
- explicit truth labels: voltage-derived capacity is not true SOC,
  `charge_full=0` means learned FCC/SOH unavailable, and source capability is
  not actual delivered input power.

The manager is live at `http://192.168.1.101:7070`, while llama-server binds
only to `127.0.0.1:8080`. Package release r28 installs and enables the manager;
the custom runtime remains a separately reproducible build artifact and must be
placed at the configured path in a new image. `API_TOKEN` is currently empty so
the dashboard is convenient on the trusted LAN, and the UI displays a security
warning. It must be set before exposure beyond that LAN.

#### Newly exposed live power-path issue

During the full-context test, TCPM advertised 5 V / 3 A (15 W), but
`pm8150b-charger/current_max` was only **50,000 uA** and measured charger input
power was about **0.23 W**. During inference QGauge briefly reported roughly
-0.33 A battery current despite external input remaining online. This means the
dock/charger has ample advertised capability but the current software state is
not applying it to the SMB5 input limit. The manager now warns whenever the
effective charger limit is below 500 mA despite a stronger TCPM source, and
whenever the battery is materially discharging with input online.

This result reopens the current-limit/source-transition investigation. Do not
run sustained inference from this dock state: the phone is effectively using
the battery for most of the load. Capture privileged `qcom_smbx` boot/status
logs and validate the notifier/revalidation path after the next reconnect or
boot before treating powered inference as unattended-safe.

#### Battery safety stack activated — 2026-09-06 04:17 UTC

After the successful basic charge-inhibition test, all four device safety
helpers were enabled at the user's request:

```text
phoenix-charge-cap.timer          enabled / active
phoenix-battery-safety.service    enabled / active (DRY_RUN=0)
phoenix-battery-telemetry.service enabled / active
phoenix-typec-recover.timer       enabled / active
```

The first charge-cap run saw `voltage_avg` around 4.347 V, wrote
`inhibit-charge`, created its ownership marker, and retained
`charger/online=1` with charger health `Good`. The battery shutdown guard stayed
running normally at approximately 32.5-32.6 C and well above its low-voltage
threshold. Type-C recovery completed as a no-op because the current bracketed
role was sink, and no systemd unit entered the failed state.

Telemetry immediately created `telemetry-2026-09-06.tsv` with five-second,
boot-ID-tagged samples. Its first four samples integrated 0.311 mAh / 1.345 mWh
of discharge. Effective input current limit moved from 50 mA to 300 mA but
remained far below the TCPM-advertised 3 A, and battery current remained
negative. Enabling the safety stack therefore succeeded, but it does not solve
the separate ICL/source-capability problem described above.

### Logic re-audit, boot-glitch fix and SoC configuration — 2026-09-06 16:00 UTC

Every helper in `extra-addon/` was re-read end to end after the adapter work,
and the live journal was checked against them. One finding changed the shape of
the fixes.

#### QGauge averaged channels are garbage for ~70 s after boot

The charge-cap journal for the 15:17 boot reads
`inhibited battery charging at 6377865uV` — 6.38 V, impossible for this cell.
Telemetry for that boot shows the cause exactly: from uptime 13 s to about 70 s,
`voltage_avg` is pinned at **6377865** and `current_avg` at **5000003**
(5.000003 A), while `voltage_now` and `current_now` are correct throughout.
The averaging registers are simply not initialised yet. `capacity` derives from
the same channel and reads 100% for that minute.

Every consumer that preferred the averaged channel was exposed. This one was
harmless (the cell was above the ceiling anyway) but the same class of glitch in
the other direction would count towards the safety guard's shutdown thresholds,
and a single 6.38 V row would wreck the adapter load-line fit. Physical
plausibility bounds are now applied before any reading is acted on:

| consumer | bounds | on implausible |
| --- | --- | --- |
| `phoenix-charge-cap.sh` | 3.0–4.6 V, \|I\| ≤ 3 A | fall back to instantaneous channel; if neither is plausible, log and take no action |
| `phoenix-battery-safety.sh` | 2.0–4.8 V, \|I\| ≤ 3 A, −20…80 °C | treated as a missing sample, feeding the existing sensor-fault counters — never as danger |
| `phoenix-adapter-test.sh` / `phoenix-power-path-verify.sh` | Vin 3–13 V, cell 2.5–4.8 V, \|I\| ≤ 3 A | sample dropped; count reported |
| `phoenix-battery-report.sh` | 2.5–4.8 V, \|I\| ≤ 3 A | row skipped; count reported |
| `phoenix-llm-manager.py` | 2.5–4.8 V | dashboard/integration use `voltage_now` instead |

The safety guard's window is deliberately the widest: a shutdown guard must
never discard a genuine 2.5–3.5 V reading, only values no cell can produce. The
regression suite now covers the recorded glitch values directly, including a
+5 A ghost on `current_avg` failing to mask a real −50 mA on `current_now`, and
a 3.30 V emergency on `voltage_now` still firing behind a 6.38 V `voltage_avg`.

#### Other defects fixed in the same pass

- `phoenix-charge-cap.sh reset` exited at "no owned inhibit" without clearing
  the deficit lockout, so after a guard release a reset left the limiter unable
  to re-arm for up to 30 minutes. Bookkeeping is now cleared unconditionally.
- An external return to `auto` dropped the ownership marker but kept a stale
  deficit count that would have shortened the next inhibit's fuse.
- `phoenix-battery-safety.sh` rejected any temperature below 0 °C as invalid
  (`valid_uint` on a signed deci-Celsius field).
- `phoenix-adapter-test.sh` left the SOURCE column blank when APSD failed to
  classify the source; it now says `unresolved`.
- `phoenix-llm-manager.py`: thermal zones are always millidegrees, so the
  sub-1000 → ÷10 heuristic would have read a 0.95 °C zone as 95 °C and tripped
  the critical guard; `/api/logs` slurped the whole append-only log into memory
  on every dashboard poll; the log had no rotation; and nothing stopped a model
  start on battery. Fixed with a fixed ÷1000 plus a −40…150 °C filter, a
  seek-based tail, an 8 MiB rotate-on-start, and a preflight that refuses to
  start unless the charger is online and the cell is above 3.70 V
  (`REQUIRE_EXTERNAL_POWER`, `MIN_BATTERY_UV` in the conf).

#### SoC configuration audit

The request was to make sure nothing holds the SoC back. Nothing does:

| item | state | note |
| --- | --- | --- |
| CPU governor | `performance`, both clusters | set by `tuned` profile `throughput-performance`, persists across boots |
| CPU frequency | little ×6 at 1.80 GHz, big ×2 at 2.21 GHz | `scaling_max_freq` equals `cpuinfo_max_freq`; no cap |
| GPU devfreq | `simple_ondemand`, 180–700 MHz | correct for a headless box; pinning 700 MHz would only add heat |
| UFS devfreq | `simple_ondemand`, 50–240 MHz | fine |
| cpuidle | `menu` | `teo` is not compiled in (`CONFIG_CPU_IDLE_GOV_TEO` unset); a kernel-config change, marginal gain |
| Energy-aware scheduling | **off** | the kernel disables EAS unless every policy runs `schedutil`; the energy model itself is present (`cpu_capacity` 398/1024) |
| thermal | passive trips 90 °C and 95 °C, critical 110 °C, cooling devices bound | intact; none engaged at idle (40–45 °C) |
| memory | swappiness 10, 8 GiB zram (zstd) | set by tuned |
| tuned verify | only `boost` fails | `cpufreq/boost` does not exist on this platform; everything else applied |

Two consequences worth stating plainly. First, `performance` costs about
0.17 W at idle over `schedutil` and turns EAS off; with adapter 2 carrying the
system that is irrelevant to the battery, and for a server that wants latency
it is the right trade. Second, the kernel does not begin throttling until
90 °C, so the 85 °C abort in the test harnesses is the harness being
conservative, not the SoC being limited. Under two spinning cores the SoC
reaches 85 °C in about twenty seconds from 45 °C; sustained heavy compute needs
active cooling regardless of any configuration.

#### Adapter and cable verdict

Keep **adapter 2 + cable 2**. Measured on it: series resistance 0.36 Ω, input
ceiling 5.05 W, cell at +0.4 mA idle and +5.3 mA under one core with charging
inhibited — the adapter powers the SoC directly and the cell does nothing across
the server's real duty cycle. The only condition it does not cover is sustained
heavy compute with the inhibit active (−58 mA under two `dd` workers), and the
SoC cannot sustain that thermally in any case. A 9 V PD adapter direct to the
phone would add margin but is not required for this deployment.

### Phoenix Console — generic device dashboard — 2026-09-06 17:00 UTC

The LLM manager has been reworked into **Phoenix Console**, a general device
dashboard with the runtime as one section. Same unit, files and port
(`phoenix-llm-manager.service`, `/usr/libexec/phoenix-llm-manager.py`, :7070);
only the product name, the service `Description=` and the UI changed, so the
preset, the enabled state and the package install paths are untouched.

Pages: Overview (device hero, live tiles, four small-multiple sparklines,
adapter-first status, helper units), Power (cell/adapter multiples, limiter
status, safety services, recorded adapter/cable tests, power-path matrices,
gauge/charger/Type-C tables, telemetry report), Runtime (profiles, stop/restart,
TurboQuant and guard tables), Chat, Tasks (per-cluster CPU history, sortable
and filterable process table with stop/kill), Services (Phoenix helper cards,
filterable systemd services, timers), Network (interface cards with live rates,
per-interface throughput chart, listening TCP ports), Storage (mount cards),
Thermal (group cards, three-series history, cpufreq policies, cooling states,
all zones), Logs (journal with unit/priority filter, runtime log), Settings
(token, poll interval, default range, motion, tweening).

New read-only endpoints: `/api/overview`, `/api/system`, `/api/system/history`,
`/api/processes`, `/api/services`, `/api/network`, `/api/storage`,
`/api/thermal`, `/api/journal`, `/api/power`. One mutation was added,
`POST /api/processes/<pid>/signal`, which refuses pid ≤ 1, the console itself,
and any process not owned by the service's own user — it runs unprivileged
under the existing hardened unit, so root daemons are visible but untouchable.
`systemctl`/`journalctl`/`ip` output is cached (5–10 s) so a dashboard polling
every few seconds cannot fork-storm the phone; process CPU% is computed on the
sampler's own 5 s clock so a request never blocks.

Two chart rules were applied deliberately. The old battery chart overlaid
voltage, current and temperature on one canvas with three implicit y-scales;
that is the dual-axis anti-pattern and it is gone — every measure now has its
own canvas (small multiples) with a crosshair tooltip, range presets, smoothing
and a zero-based toggle. Series colours are the first three dark categorical
slots (`#3987e5`, `#d95926`, `#199e70`) validated against this UI's chart
surface `#0d1316` — all-pairs pass for three, fail for four, so no chart
carries more than three series. Status green/amber/red are reserved for state
and never used as a series. Motion follows `prefers-reduced-motion` with an
override in Settings.

The security posture is unchanged and still the main caveat: `API_TOKEN` is
empty, so everything is open to the LAN behind the blanket `eth*` accept.

### Podman + Portainer on the phone — 2026-09-06 17:10 UTC

`podman` 6.1.1 (crun 1.28, netavark 2.1, aardvark-dns, conmon) is installed
from Alpine edge with the `podman-systemd` subpackage, which supplies
`podman.socket`/`podman.service` (socket-activated Docker-compatible REST API on
`/run/podman/podman.sock`), `podman-restart.service`, and the Quadlet generator.
Both `podman.socket` and `podman-restart.service` are enabled at boot.

The web front end is **Portainer CE 2.45** at `https://192.168.1.101:9443`,
run rootful as a Quadlet unit (`/etc/containers/systemd/portainer.container` →
`portainer.service`, `Restart=always`, `WantedBy=multi-user.target`). It uses
**host networking**, mounts the podman socket as `/var/run/docker.sock`, keeps
state in the `portainer_data` volume, has HTTP disabled (HTTPS 9443 only, plus
the 8000 edge-tunnel listener), and its admin account is pre-seeded from a
root-only random password at `/etc/portainer/admin-password`. Login via
`POST /api/auth` was verified. A `podman stop portainer` behind systemd's back
was recovered by systemd within seconds.

#### The shipped kernel cannot run netavark's default firewall

Every bridged container failed with
`netavark: nftables error: "nft" did not return successfully ... Could not
process rule: No such file or directory`. Adding netavark's rule shapes one at
a time isolated two expressions: `fib daddr type local` (needs
`nft_fib_inet`) and `redirect` (needs `nft_redir`). The kernel config has
`CONFIG_NFT_FIB_INET` and `CONFIG_NFT_REDIR` **not set**; masquerade, dnat,
marks and NAT chains all work. netavark 2.x has no iptables driver
(`Must provide a valid firewall backend, got iptables`), so that escape hatch
is gone too.

Two fixes, one durable and one live:

- **Durable (repo):** `sync-phoenix-port-into-pmaports.sh` now enforces
  `CONFIG_NFT_FIB_INET=m` and `CONFIG_NFT_REDIR=m` alongside the panel and
  charger symbols, so the next kernel build is container-ready. CLAUDE.md lists
  them. Because only two modules are added and the rest of the config is
  unchanged, the two `.ko.zst` from that build can be dropped into the running
  kernel's module tree without a reflash.
- **Live (device):** `/etc/containers/containers.conf.d/10-phoenix.conf` sets
  `firewall_driver = "none"`; netavark still creates `podman0`, veth pairs and
  addresses, and NAT/forwarding for `10.88.0.0/16` come from the device
  package's `52_phoenix_eth_trust.nft` (input: DNS to aardvark only; forward:
  egress + established replies; a `phoenix_nat` table with masquerade). A
  bridged `alpine:3.20` container resolves names and reaches the internet.
  Consequence: **published ports on bridged containers do not work** until the
  kernel has the two symbols — anything that must listen uses `Network=host`,
  which is why Portainer does.

One more platform fact learned on the way: Alpine's `crun` is built without
libsystemd, so `cgroup_manager = "systemd"` fails plain `podman run` with
`crun: systemd not supported`. The default `cgroupfs` is required; Quadlet units
are unaffected because they run with `--cgroups=split`.

#### Reboot verification — 2026-09-06 17:09 UTC

A full `systemctl reboot` (boot id `b32ad85d…` → `9dc86f72…`) came back in about
85 s with `eth0` up. At 82 s uptime: `podman.socket` and `podman-restart.service`
active and enabled; `portainer.service` active with `NRestarts=0` and the
container `Up 55 seconds`; nftables active with the `phoenix_nat` masquerade
rule and both `podman0` input rules loaded; console, safety guard and charge-cap
timer active; zero failed units; no ext4 journal recovery (clean shutdown).
Portainer answered on 9443 from the workstation immediately after.

Security note: the podman socket stays `root:root 0660` and was deliberately
**not** widened to the `user` account — access to it is root-equivalent, and the
Phoenix Console still has no API token. Portainer brings its own authentication,
which is why it, rather than a raw TCP API listener, is the "web service".
Podman is installed on the device, not baked into the ROM image; packaging it
into `device-xiaomi-phoenix` is a separate decision.

## Production-safety validation matrix

### Adapter-first operation: subsequent register audit

The requested laptop-style policy is already implemented by the enabled
voltage charge cap: inhibit battery charging at 4.10 V, retain USB input,
and allow charging again at 4.00 V. These are voltage thresholds, not a
calibrated 80% SOC setting. Battery backup remains connected; charge inhibition
does not disable battery discharge during an outage or insufficient input.

A subsequent privileged read corrects the earlier claim that the low sysfs
current limit proves a driver policy failure. The boot log selected
`USB ICL 1500000 uA ... APSD DCP`; register `0x1370=0x1e` programs 1.5 A,
`0x1365=0xb5` retains the high-current override, and `0x1340=0x00` leaves
USB input unsuspended. The SMB5 `current_max` getter reads settled AICL
status, which can differ from the programmed ceiling. Therefore low settled
current alone does not establish a missing notifier or failed policy write.

A controlled A/B test on 2026-09-06 first appeared to isolate the control mode;
the later cable A/B test below refined that conclusion to input-path headroom,
not an inherent failure of the inhibit mechanism or the driver's ICL policy.

First, `pm8150b-charger/current_max` is a *measurement*, not an active limit.
Across the sawtooth it tracks `current_now` quantised to the 50 mA AICL step:

| reported `current_max` | 50 | 100 | 150 | 250 | 350 |
| --- | ---: | ---: | ---: | ---: | ---: |
| measured `current_now` (mA) | 46.9 | 96.7 | 147.3 | 246.1 | 343.5 |

Second, reducing system load does not reduce the drain. Moving both CPU
policies from `performance` to `schedutil` cut the system load 0.739 W -> 0.568 W
(-23%), but mean battery power stayed at -0.175 W / -0.178 W because the input
fell by the same amount (0.564 W -> 0.389 W) and time spent at the 50 mA floor
*rose* from 64% to 78%. A power-budget shortfall would not behave this way.

Third, the decisive test: releasing the inhibit while leaving everything else
identical. With `charge_behaviour=auto`, the same source immediately reported
`Charging`, drew 296-446 mA, and pushed **+32 to +80 mA into the battery** at
4.32 V, with cell voltage climbing 4.313 V -> 4.332 V over 90 seconds. Restoring
the inhibit returned the system to a net discharge.

The immediate conclusion drawn from this was that `inhibit-charge` itself causes
the discharge. **A later cable swap showed that was too strong** -- see the
cable comparison below. The accurate statement is that inhibiting at a high cell
voltage collapses USBIN *when the input path is marginal*: the charger can no
longer hold VSYS above the cell, the input settles near its 50 mA floor, and the
battery supplies most of the load. The mechanism intended to protect the cell
was cycling it instead, on the same trajectory as the August 23 deep discharge,
with the only difference being that the shutdown guard is now armed.

Two consequences follow.

`inhibit-charge` is not a robust laptop-style control across marginal input
paths on this hardware. New kernel patch 0018 exposes `constant_charge_voltage`
(`FLOAT_VOLTAGE_CFG`, 7.5 mV/step from 3.4875 V) as a writable property, with
writes rejected outside `[3487500, voltage_max_design_uv]` so userspace can
lower the ceiling but never raise it above the device tree maximum. Capping the
float voltage leaves `CHARGING_ENABLE_CMD_BIT` set, so the charger keeps
regulating and the cell simply rests at the ceiling with taper current near
zero. `phoenix-charge-cap.sh` now prefers this mode automatically and falls back
to `inhibit-charge` only when the property is absent. Patch 0018 applies cleanly
to the 7.1_rc3 tree with patches 0001-0017 applied; it is **not yet compiled or
hardware-tested**. The userspace policy is lower-only too: if firmware or
another controller already selected a ceiling below its target, it preserves
that safer limit and does not claim ownership.

Until patch 0018 is installed, the fallback path carries an adapter-deficit
guard: a sustained discharge above `DEFICIT_CURRENT_UA` while the charger
reports input online releases the owned inhibit, arms a lockout for
`DEFICIT_LOCKOUT_SECONDS`, and logs at warning level. A missing or unreadable
current channel proves nothing and never releases an inhibit. `phoenix-charge-cap
status` reports the active control mode, the input power, and an explicit
OK/DEFICIT/ON BATTERY verdict.

Note also that the 9 V PD contract observed on 2026-09-05 is gone: the attached
dock now enumerates as a non-PD path (`usb_power_delivery_revision 0.0`,
`usb_type [DCP]`), so the source is limited to 5 V. That reduces available
headroom but, per the A/B test above, is not what caused the discharge.

#### Hardware validation of the deficit guard — 2026-09-06 04:57 UTC

The updated `phoenix-charge-cap.sh` was deployed to `/usr/libexec` on the live
device (r27 package otherwise unchanged; the previous script is preserved at
`/var/backups/phoenix-charge-cap.sh.r27`). The guard behaved as designed:

```text
run 1-4  auto [inhibit-charge]   marker present   deficit count 1..4
run 5    [auto] inhibit-charge   marker gone      lockout armed
journal  adapter cannot carry the system load (battery -39367uA at 4289799uV
         with input online); released inhibit after 5 samples
```

Forty seconds after the release, measured input rose from 941 mW to 1609 mW,
the input current settled at 350 mA instead of the 50 mA floor, battery current
improved from -39 mA to -14 mA, and `phoenix-charge-cap status` changed its
verdict from `DEFICIT` to `OK`. This is direct hardware confirmation that the
inhibit, not the supply path, was starving USBIN.

The float register was also read directly to confirm patch 0018's encoding:
`/sys/kernel/debug/regmap/0-00/registers` reports `1070: 79`, i.e. selector 121
= 3487500 + 121 x 7500 = 4,395,000 uV, matching the value the driver programs at
probe from `voltage-max-design`. `REGMAP_ALLOW_WRITE_DEBUGFS` is not enabled, so
the float ceiling cannot be lowered for a live experiment without building the
kernel; patch 0018 remains compile-and-flash work.

#### Cable comparison isolates the real variable — 2026-09-06 15:00 UTC

Swapping only the cable, same adapter and same dock, changed the result
decisively. `phoenix-adapter-test.sh` records both runs:

| | cable 1 | cable 2 |
| --- | ---: | ---: |
| series resistance to USBIN | 1.031 ohm (least-squares fit) | 0.25-0.41 ohm (estimate) |
| USBIN voltage at ~450 mA | 4.545 V | 4.858 V |
| input power ceiling | 2.47 W | 2.43 W |
| battery current, idle, charging | +35.1 mA | +71.9 mA |
| battery current, under load | -147.3 mA | -109.4 mA |
| **battery current while inhibited** | **-35 mA** | **+1.5 mA** |

The last row is the one that matters. With cable 2 and `charge_behaviour=
inhibit-charge`, a 60-second sample measured +1.5 mA average, with instantaneous
values between -0.15 mA and +0.9 mA, while USBIN carried 220-496 mA at
4.85-5.03 V. That is laptop-style adapter-first operation working as intended on
the existing kernel: the adapter carries the entire system load and the cell is
neither charged nor discharged.

So `inhibit-charge` was never inherently broken. It needs enough path headroom
for the charger to hold VSYS above the cell, and roughly 1 ohm did not provide
it. The earlier A/B test was real but attributed the cause to the mechanism
rather than to the path.

Cable 2 also changed the ICL regime. APSD no longer resolves a charger type
(`usb_type` reads empty, `APSD unresolved` in dmesg), so the driver takes the
guarded TCPM fallback and programs 1.5 A (`0x1370=0x1e`, override `0x1365=0xb5`)
while AICL settles at 500 mA (`0x1108=0x0a`). Since the path holds 4.86 V at
450 mA, the ~2.4 W ceiling is now the dock's own power budget rather than the
cable or the driver. A brief flap between `safe default` and `TCPM fallback`
during re-enumeration settled on its own within 20 seconds and has not recurred.

#### Adapter comparison — 2026-09-06 15:20 UTC

A second adapter was then tested on the same cable 2. `phoenix-adapter-test.sh`
results, plus separate measurements taken with `charge_behaviour=inhibit-charge`:

| | adapter 1 + cable 1 | adapter 1 + cable 2 | **adapter 2 + cable 2** |
| --- | ---: | ---: | ---: |
| series resistance | 1.031 ohm (fit) | 0.25-0.41 ohm (est) | 0.359 ohm (fit) |
| open-circuit voltage | 5.062 V | - | 4.996 V |
| input power ceiling | 2.47 W | 2.43 W | **5.05 W** |
| battery, idle, auto | +35.1 mA | +71.9 mA | **+200.5 mA** |
| battery, load, auto | -147.3 mA | -109.4 mA | **+21.3 mA** |
| battery, idle, inhibited | -35 mA | +1.3 mA | **+0.49 mA** |
| battery, load, inhibited | - | - | **-58 mA** |

Adapter 2 is the clear winner and is the recommended configuration. It roughly
doubles deliverable power: APSD classifies it as DCP, so the driver takes the
full 1.5 A ceiling (`0x1370=0x1e`, override `0x1365=0xb5`) and the path actually
sustains about 1 A, against 500 mA for adapter 1 through the dock. Cable 2
separately fixed the series resistance. The two fixes are independent and both
were needed.

With adapter 2 the server goal is met for its normal state: idle with charging
inhibited holds the cell at +0.49 mA over 120 seconds while the adapter supplies
1.23 W, so the battery is neither charged nor discharged.

One limitation remains and it is the same mechanism seen throughout. Under
sustained CPU load with `inhibit-charge` active, USBIN draws only 740 mA /
3.43 W and the battery supplies the balance at -58 mA, whereas the same load in
`auto` drew about 1 A / 4.83 W and left the battery at +21.3 mA. Inhibiting
consistently reduces how much the input delivers; a stronger adapter shrinks the
shortfall (-147 mA -> -58 mA) but does not remove it. For a mostly idle server
this is acceptable. Eliminating it is what patch 0018 is for, since float
capping leaves the charger regulating instead of handing the rail back to the
cell.

#### Power-path verification matrix — 2026-09-06 15:30 UTC

`phoenix-power-path-verify.sh` walks load levels against charge behaviours,
settling before each measurement and cooling to 45 C between load steps, so no
row is contaminated by the previous row's heat. On adapter 2 + cable 2:

| condition | behaviour | cell mA | min | max | input W | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| idle | inhibit-charge | **+0.4** | -0.2 | +0.9 | 1.59 | **BATTERY IDLE** |
| idle | auto | +193.0 | +147.9 | +249.9 | 4.48 | CHARGING |
| light (1 core) | inhibit-charge | **+5.3** | +0.0 | +20.1 | 2.94 | **BATTERY IDLE** |
| light (1 core) | auto | +170.8 | +144.7 | +191.0 | 5.43 | CHARGING |
| medium (2 cores) | inhibit-charge | thermal limit before first sample | | | | - |
| medium (2 cores) | auto | thermal limit before first sample | | | | - |

This confirms the intended behaviour directly. With charging inhibited the cell
sits at +0.4 mA at idle and +5.3 mA under one core of load, while adapter input
scales 1.59 W -> 2.94 W to absorb the extra demand. The battery is neither
charged nor discharged: the adapter is powering the SoC and peripherals, and the
cell is simply along for the ride. The `auto` rows are the control -- same
conditions, but +170 to +193 mA flows into the cell and input rises to
4.5-5.4 W, which is the charge current the inhibit removes.

The verified envelope is idle through one core. Both two-core rows crossed the
85 C abort during their settle window, so they could not be sampled at all. An
earlier ad-hoc measurement under two continuous `dd` workers (a heavier load
than one spinning core) recorded -58 mA with inhibit active, so the cell does
begin supplying somewhere above this envelope. Thermals, not the power path,
are what stop the measurement.

Thermals bound these tests rather than power: two `dd` workers took the hottest
zone from 41 C to 86 C in 30 seconds. Sustained full-load operation is not
viable on this hardware without active cooling, which also bounds any llama.cpp
plan.

Practical consequence: patch 0018 is no longer the only route to the goal, but it
remains the better one. Float capping removes the hysteresis cycle entirely and
does not depend on path headroom, whereas the inhibit path now works only while
the cable stays good. The adapter-deficit guard remains valuable precisely
because it catches the cable-1 case automatically.

Both CPU policies were also moved from `performance` to `schedutil` for the
measurement, which cut system load from 0.739 W to 0.568 W but did not by itself
change the battery deficit. **That change did not persist**: `tuned` runs the
`throughput-performance` profile and re-applied `performance` at the next boot.
See the SoC configuration audit below; `performance` is the intended state.

Interim expectation until patch 0018 is installed: with the deficit guard active
the limiter will keep the charger in `auto`, so the cell will rest near the
device tree float of about 4.4 V rather than at the intended 4.10 V ceiling.
That is a deliberate trade -- a high resting voltage ages the cell, but draining
it to the shutdown guard is worse -- and it is exactly what patch 0018 removes.

| Test | Required result |
| --- | --- |
| Normal 5 V Type-C source >=1.5 A | requested ICL <=1.5 A |
| Explicit 9 V PD through powered dock | requested ICL <=1.5 A and <=15 W; USB input remains online |
| Explicit 12 V PD | requested ICL <=1.25 A (15 W ceiling) |
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
| Disable/reset with QGauge missing or invalid | owned inhibition returns to `auto`; external inhibition remains untouched |
| Synthetic/register OV test | Linux reports OV from status 2 correctly |
| Cool/warm/cold/hot tests | correct status-7 health mapping |
| Wall clock jumps forward/back | integrated mAh/mWh unchanged |
| Reboot between telemetry rows | no integration across boot IDs |
| Base plus v2-v4 telemetry headers all mismatch | no existing file is modified; a safe new version is created or collection fails closed |
| External power loss at low voltage | automatic orderly shutdown |
| Type-C voltage files absent, capacity low | capacity fallback triggers the guarded recovery path |
| Sync after deleting a Phoenix patch | stale source/checksum removed, unrelated patches preserved, no dummy checksum emitted |
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
- charge-cap reset is independent of gauge availability and has a safe disable workflow;
- telemetry never appends across incompatible schemas;
- Type-C urgency falls back correctly when voltage attributes are absent;
- pmaports synchronization removes stale entries without re-inserting them;
- k3s core services are healthy under the final firewall policy;
- the current package and kernel are installed together, with manual overrides
  removed or documented;
- remote access and privileged commands are hardened; and
- the full transition matrix passes without overheating, repeated cycling,
  filesystem corruption, or unsafe current retention.

## Final replacement-battery statement

The earlier telemetry window showed voltage at or below 4.130 V and temperature
within 28.6-35.5 C. A later live reading on September 6 reached approximately
4.443 V (`voltage_now`) and 4.437 V (`voltage_avg`), slightly above the configured
4.400 V design maximum, while battery temperature remained normal at about
32-33 C. This may be measurement/scaling/calibration error rather than physical
cell overcharge, but it invalidates the older blanket statement that the battery
was always at or below 4.130 V. The replacement battery is not showing abnormal
heat, yet voltage-ceiling behavior now requires targeted validation.

The data does not validate over-voltage or thermal cutoff behavior because those
conditions were not approached. The live device now runs patches 0010+0011,
including the SMB5 status-2 over-voltage selection and watchdog/OV/float/ICL
robustness, and true charge inhibition has passed its basic hardware test. On
September 6 the charge-cap timer, shutdown guard, telemetry collector and Type-C
recovery timer were all enabled. Synthetic OV/thermal tests, real low-voltage
shutdown validation, source-transition tests, and the newly compiled
patch-0012 9 V PD test remain required before treating the device as a finished
unattended always-powered server.

## External references (updated 2026-09-05)

- Upstream 5-patch Fixes series: watchdog base, health bits, float selector, float validation, OV recovery (LKML 06756)
- Upstream SMB5 v4 series (LKML 07902, Patchew 20260820 v4)

- [Linux power-supply sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-power)
- [August 20, 2026 SMB5 v4 patch](https://lkml.iu.edu/2608.2/07902.html)
- [Qualcomm downstream SM7150 BMS implementation](https://android.googlesource.com/kernel/msm.git/+/0bdc64f155814eb6a109d0ec9e3965c821da5853/drivers/power/supply/google/sm7150_bms.c)
- [Qualcomm downstream QGauge-related history](https://android.googlesource.com/kernel/msm/+/9bc512676061161105fa95ccf40532f625c05b7e%5E2..9bc512676061161105fa95ccf40532f625c05b7e/)
- [Qualcomm Snapdragon 730G product brief](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/qualcomm-snapdragon-730g-mobile-platform-product-brief.pdf)
- [Mesa Freedreno and Turnip documentation](https://docs.mesa3d.org/drivers/freedreno.html)
- [Alpine aarch64 Mesa Freedreno Vulkan package](https://pkgs.alpinelinux.org/package/edge/main/aarch64/mesa-vulkan-freedreno)
- [Alpine aarch64 llama.cpp package family](https://pkgs.alpinelinux.org/package/edge/community/aarch64/llama.cpp-libs)
- [llama.cpp Vulkan build documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md)
- [llama.cpp OpenCL backend documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md)
- [llama.cpp Snapdragon Linux guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/linux.md)
- [llama.cpp Hexagon backend details](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/developer.md)
- [TurboQuant ICLR 2026 paper](https://openreview.net/forum?id=tO3ASKZlok)
- [TheTom llama.cpp TurboQuant implementation](https://github.com/TheTom/llama-cpp-turboquant/tree/feature/turboquant-kv-cache)
- [XHToken Spark-X2.5 llama.cpp support](https://github.com/XHToken/llama.cpp)
- [llama.cpp Vulkan Turbo4 SET_ROWS report](https://github.com/ggml-org/llama.cpp/issues/22842)
