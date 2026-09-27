# Windows on Arm for phoenix — status and first test

This covers what exists for running Windows 11 Arm64 on the POCO X2 / Redmi K30
4G (`phoenix`, SM7150-AB, soc_id 365), what has been built and verified, and a
first hardware test that does not touch the installed postmarketOS system.

## Status (checked 2026-09-27)

**Windows does not boot on phoenix today, anywhere.** The only UEFI with a
phoenix target is Project Silicium's
[Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium). Its own
[status page](https://github.com/Project-Silicium/Mu-Silicium/blob/main/Status.md)
lists phoenix as **Inactive**:

| UEFI feature | phoenix | surya (POCO X3 NFC, SM7150-AC) |
| --- | :---: | :---: |
| Display, internal storage, side buttons | ✅ | ✅ |
| USB device mode, mass storage | ✅ | ✅ |
| USB host, USB PD, SD card | ❌ | ❌ / ❌ / ✅ |
| **Windows boot** | **❌** | ✅ |
| Linux boot | ❌ | ✅ |
| Windows driver pack | none | [Project-Aloha/windows_oem_xiaomi_surya](https://github.com/Project-Aloha/windows_oem_xiaomi_surya) |

The reason is concrete, not vague: Windows needs ACPI tables, and phoenix has
none. `phoenixPkg/phoenix.dsc` carries its ACPI include commented out
(`#phoenixPkg/AcpiTables.inf`), and
[Silicium-ACPI](https://github.com/Project-Silicium/Silicium-ACPI) has a DSDT
for surya but no phoenix directory. The phoenix target is also absent from
upstream CI, which only builds active devices. Project Aloha's SM7150 work
describes Windows on this SoC as "more proof of concept".

## What is prepared

Built from source with `scripts/build-mu-silicium-phoenix.sh` (Docker,
ubuntu-24.04 amd64, mirroring upstream CI), pinned to Mu-Silicium
`d19ae66c49fa47e47fd56a28e0e4db58b3638968` (2026-09-25, "Update Project Mu to
2026/08") with `Binaries` at `203fb36b` and `Silicium-ACPI` at `9abca7f9`.
Model 1 selects the POCO X2 SMBIOS identity. Both targets built cleanly
(RELEASE 3 m 13 s, DEBUG 3 m 59 s). Outputs are in `artifacts/windows/`
(ignored by git; regenerate with the script), with `provenance.txt` listing
every submodule revision:

| file | SHA-256 |
| --- | --- |
| `Mu-phoenix-1-DEBUG.img` (4,306,944 B) | `e1e80e8c121407f3b84447cb35be72d19d63656169c1752ac13fccfd344bb37f` |
| `Mu-phoenix-1-RELEASE.img` (4,190,208 B) | `8b6e6badc505ad8b1d08ce3d6df0132d4b09b346006180457450aa2b227fa5e1` |

Each image was taken apart and checked, not just built:

- Android boot image, header v1, page 2048 — what the stock Xiaomi ABL expects.
- The kernel slot is gzip data that decompresses to exactly 112 bytes of ARM64
  boot shim (valid `ARMd` kernel header, so ABL treats it as a kernel) followed
  by the 3 MiB UEFI firmware volume (`_FVH` at the start).
- Appended after it is a 16-entry Qualcomm multi-DTB set, byte-identical to the
  pinned source's `Resources/DTBs/phoenix.dtb`. ABL will only boot an image
  whose DTB matches the SoC; the set contains `SDMMAGPIE` with
  `qcom,msm-id = 0x16d` (365), and this phone reports `soc_id 365`.
- UEFI variables are RAM-emulated in this build
  (`PcdEmuVariableNvModeEnable|TRUE`, no TrustZone or partition backend), so
  booting it persists nothing.
- DEBUG prints the firmware's debug log on the screen
  (`FrameBufferSerialPortLib`); RELEASE is silent.

`artifacts/windows/reference/` holds the surya ACPI tables at the pinned
Silicium-ACPI commit (the starting point for a phoenix DSDT) and a copy of the
status page as read. `SHA256SUMS` covers those files, both UEFI images, and the
downloaded Windows ISO; check with
`shasum -a 256 -c artifacts/windows/SHA256SUMS`.

## Test 1: tethered UEFI boot (non-destructive)

`fastboot boot` loads the image into RAM once. No partition is written; the
next restart returns to the normal chain (ABL → `boot` = U-Boot → systemd-boot
→ Linux). This validates the UEFI on this particular phone and is the first
test anything else depends on.

Expect about 10–15 minutes of server downtime. The phone runs on battery the
whole time, so start above roughly 4.0 V.

1. **Enter fastboot.** Over SSH:
   `sudo systemctl reboot --reboot-argument=bootloader`
   The PMIC's `mode-bootloader` reboot reason and the `qcom-pon` /
   `syscon-reboot-mode` drivers are present, but this path has not been
   exercised on this unit yet. Fallback: hold Power to switch off, then hold
   Volume-Down + Power until the fastboot screen appears.
2. **Swap the cable.** There is one USB-C port: unplug the dock and connect the
   phone to the Mac with a data cable.
3. **Confirm the device.** `fastboot devices` should list it, and
   `fastboot getvar product` should name phoenix.
4. **Boot the DEBUG image first:**
   `fastboot boot artifacts/windows/Mu-phoenix-1-DEBUG.img`
   Its on-screen log makes a hang diagnosable from a photo.
5. **Observe.** Success is the Mu/Silicium splash followed by a UEFI boot menu.
   Volume keys move, Power selects. Windows will not start — there is nothing
   for it to boot yet. Worth recording: whether the display comes up and at
   what orientation and resolution, whether buttons respond, what the boot
   manager lists, and the last lines of the log if it stops.
6. **Optionally repeat with the RELEASE image** for the production look.
7. **Return to Linux.** Hold Power for about 10–15 s to force a restart. The
   untouched `boot` partition brings Linux back. Reconnect the dock;
   `phoenix-usb-host-wake` restores Ethernet within about a minute, then check
   `ssh user@192.168.1.101 'uptime; systemctl --failed'`.

Rules for this test:

- **Never `fastboot flash boot`** (or `erase`, or `flash userdata`). Flashing
  the UEFI over `boot` replaces the davinci U-Boot and the Linux install stops
  booting until U-Boot is flashed back.
- **Do not choose USB mass-storage mode while the phone is plugged into the
  Mac.** It exposes the raw UFS. macOS auto-mounts every FAT partition it
  recognises — including Android firmware partitions such as `modem` — and
  writes metadata to them, and an "Initialize…" prompt for the unrecognised
  partitions would erase the phone if accepted.
- Boot only images whose SHA-256 matches the table above.

## The Windows image

Microsoft's official Arm64 ISO (Windows 11 2025 Update, version 25H2,
multi-edition, product "Windows 11 Arm64 25H2__V2") was downloaded on
2026-09-27 after generating the link through Microsoft's browser download
page. It is stored at
`artifacts/windows/Win11_25H2_English_Arm64_v2.iso` (7,994,415,104 bytes).
Its SHA-256, `638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0`,
matches the English 64-bit value on Microsoft's live verification table. The
ISO identifies as a bootable ISO 9660 image labeled
`CCCOMA_A64FRE_EN-US_DV9`.

To obtain a fresh copy if this local artifact is removed:

1. Open <https://www.microsoft.com/en-us/software-download/windows11arm64>.
2. Choose **Windows 11 (multi-edition ISO for Arm64)**, then **English (United
   States)**. The link is valid for 24 hours.
3. Verify against the hash table Microsoft publishes on that page:
   `scripts/verify-windows-arm64-iso.sh /path/to/<file>.iso`
   The script reads the live table and falls back to the snapshot in
   `scripts/windows-arm64-iso-sha256.tsv` (captured 2026-09-27) only if the page
   is unreachable. As published that day, English (US) is
   `638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0`.

The image is not needed for Test 1 and cannot boot on phoenix until the work
below is done.

## What Windows boot actually needs

1. **ACPI.** A phoenix DSDT in `Silicium-ACPI/Platforms/Xiaomi/phoenix`,
   derived from surya's: same SoC family, and surya's touch device `TSC1` is
   the same NT36672C over SPI that the Linux port drives with `nt36xxx-spi`.
   Phoenix-specific differences already visible in the UEFI package are the
   memory map (TZApps `0x03E00000` versus `0x02200000`, and an ADSP RPC region
   at `0x9D800000`), a framebuffer-only display path, AW8624 haptics, and PIL
   firmware loading. Then enable `phoenixPkg/AcpiTables.inf` in `phoenix.dsc`.
2. **Drivers.** Start from surya's pack (pinned `2ee4509842f8`, 2025-12-26).
   SoC-level drivers should carry over; device-level INFs and configuration
   (touch, panel, battery and charger) need phoenix values.
3. **Storage layout.** Windows needs its own ESP and NTFS partition, while
   `userdata` currently holds the entire Linux image. Making room means
   repartitioning UFS, which is destructive: a separate, deliberate step after a
   full backup.
4. **Deployment tooling.** Applying the image and injecting drivers is normally
   done with DISM on a Windows host. macOS has no equivalent for driver
   injection.
