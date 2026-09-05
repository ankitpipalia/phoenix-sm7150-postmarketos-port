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
2. Run controlled low-voltage/source-loss and thermal-input tests before enabling the shutdown guard. **Live:** guard `disabled` as intended; synthetic tests now cover independent channels (`temp 500` with invalid voltage fires, `voltage_now 3300000` vs `voltage_avg 3500000` triggers emergency), sensor-failure policy (12 samples logs + conservative shutdown), and `ConditionPathExists` removed (`Restart=always`); real source-loss still pending.
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
| CPU | **High confidence.** Generic aarch64 llama.cpp should run on the Kryo 470 CPU. Establish this baseline first. |
| Vulkan/Turnip | **Plausible and the first accelerator to test.** Mesa Turnip supports Adreno 6xx, the repository supplies the GPU ZAP firmware, and a prior live audit saw DRM nodes. `vulkaninfo` and llama.cpp execution have not yet proved that this Adreno 618 path works correctly. |
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
- no successful `vulkaninfo`, llama.cpp device listing, model load or GPU
  inference result has been recorded;
- the latest connectivity audit could not reach the device to close those
  gaps.

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

## Production-safety validation matrix

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

The replacement battery appears healthy under the conditions observed. Recorded
voltage remained at or below 4.130 V and recorded temperature remained within
28.6-35.5 C, with no observed evidence of overcharging or abnormal thermal
behavior. The configured 1.5 A ceiling is conservative.

The data does not validate over-voltage or thermal cutoff behavior because those
conditions were not approached. The live device now runs patches 0010+0011,
including the SMB5 status-2 over-voltage selection and watchdog/OV/float/ICL
robustness, and true charge inhibition has passed its basic hardware test.
Synthetic OV/thermal tests, low-voltage shutdown validation, source-transition
tests, and the newly compiled patch-0012 9 V PD test remain required before
treating the device as a finished unattended always-powered server.

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
