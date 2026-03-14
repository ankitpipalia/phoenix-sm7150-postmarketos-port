# postmarketOS port for Xiaomi POCO X2 / Redmi K30 4G (phoenix)

> **Status: Working** — boots to phosh UI, WiFi, USB networking, display, touchscreen functional.

This repository contains the pmaports packages and kernel patches needed to run [postmarketOS](https://postmarketos.org) on the **Xiaomi POCO X2** (Indian market) / **Xiaomi Redmi K30 4G** (Global), codename **phoenix**, powered by the Qualcomm Snapdragon 730G (SM7150-AB).

If you are starting from a completely fresh Linux host and a stock MIUI phone in fastboot mode, use the end-to-end guide: [docs/FRESH-LINUX-STOCK-ROM.md](docs/FRESH-LINUX-STOCK-ROM.md).

---

## Device Specifications

| Item | Details |
|------|---------|
| **Codename** | `phoenix` (POCO X2) / `phoenixin` (Redmi K30 4G India) |
| **SoC** | Qualcomm SM7150-AB (Snapdragon 730G) |
| **CPU** | 2× Kryo 470 Gold + 6× Kryo 470 Silver, octa-core |
| **GPU** | Adreno 618 |
| **RAM** | 6 GB / 8 GB LPDDR4X |
| **Storage** | 64 GB / 128 GB / 256 GB UFS 2.1 |
| **Display** | 6.67" IPS LCD, 1080×2400, 120 Hz |
| **Kernel** | [sm7150-mainline/linux](https://github.com/sm7150-mainline/linux) |

---

## Feature Status

| Feature | Status |
|---------|--------|
| Booting | ✅ Working |
| Display | ✅ Working |
| Touchscreen | ✅ Working |
| USB networking (RNDIS) | ✅ Working |
| WiFi | ✅ Working |
| Bluetooth | ✅ Working (adapter up, scanning works) |
| Root access for default user | ✅ Working (`doas` and `sudo` are passwordless for `user`) |
| Screen wake behavior | ✅ Working (notification/task-complete wakeups disabled by dconf policy; power button wake only) |
| Audio | ❌ Not working (ADSP sensor PD crash, q6asm-dai probe fails) |
| Camera | ❌ Not working |
| Modem / calls | ⚠️ Remoteproc running, untested |
| GPS | 🔧 Untested |
| Sensors | ❌ Not working (missing sensor PD firmware) |
| Battery / charging | ⚠️ PM6150 charging path enabled; PM6150 SMB5 register-offset fix added. Hub/PD edge cases still incomplete |
| GPU / 3D acceleration | ⚠️ DRI device present (card0, renderD128), untested |
| SD card | 🔧 Untested |
| NFC | ⚠️ nfc0 detected, untested |
| USB-C hub ethernet | ⚠️ Works, but drops when charger/USB added to hub (see Troubleshooting) |

---

## Repository Structure

```
├── device-xiaomi-phoenix/       # pmaports device package
│   ├── APKBUILD                 # Package build definition
│   ├── deviceinfo               # Device configuration for pmbootstrap
│   ├── 00-phoenix-notification-policy      # dconf defaults: disable wake-on-notification
│   ├── 00-phoenix-notification-policy.lock # dconf locks to keep wake policy enforced
│   ├── dconf-profile-user       # enables system-db:local policy loading
│   ├── 90-phoenix-mac.conf      # disable NetworkManager randomized WiFi MAC
│   ├── phoenix-wlan-mac.sh      # deterministic wlan0 MAC provisioning
│   ├── phoenix-wlan-mac.service # applies MAC before NetworkManager
│   ├── doas-user-nopass.conf    # passwordless doas for default user
│   ├── sudoers-user-nopass.conf # passwordless sudo for default user
│   ├── device-xiaomi-phoenix.post-install  # masks uim-selection, updates dconf
│   ├── device-xiaomi-phoenix.post-upgrade  # re-applies service/policy defaults
│   ├── hexagonrpcd.confd        # Hexagon DSP daemon config
│   └── modules-initfs           # Kernel modules loaded in initramfs
│
├── firmware-xiaomi-phoenix/     # pmaports firmware package
│   ├── APKBUILD                 # Firmware package build definition
│   └── 30-initramfs-firmware-xiaomi-phoenix.files  # Files included in initramfs
│
├── kernel-patches/              # Kernel DTS patches for phoenix
│   ├── 0001-dts-add-xiaomi-phoenix.patch   # Add phoenix to sm7150 Makefile
│   ├── 0002-phoenix-dts.patch              # Main device tree source
│   ├── 0003-phoenix-panel.patch            # NT36672C display panel support
│   ├── 0004-pm6150-add-charger-support.patch  # PM6150 charger + USB-C PD role config
│   ├── 0005-add-wcn3998-wifi-bt-power-management.patch # WCN3998 WiFi/BT DT fixes (UART3 pinctrl + BT compatible)
│   ├── 0006-ath10k-qmi-treat-malformed-host-cap-as-non-fatal.patch # ath10k QMI host-cap fallback
│   └── 0007-pm6150-smb5-register-offsets.patch # PM6150 SMB5-style charger register offsets for online/current detection
│
├── docs/
│   └── FRESH-LINUX-STOCK-ROM.md           # Full clean-host + stock-ROM runbook
│
└── scripts/
    ├── wipe-pmbootstrap-state.sh          # Remove old pmbootstrap state (fresh init)
    ├── sync-phoenix-port-into-pmaports.sh # Copy packages/patches + update kernel APKBUILD sums
    ├── pmbootstrap-phoenix.sh             # Run pmbootstrap with fixed config/work/pmaports paths
    └── build-firmware-tarball.sh          # Build firmware-xiaomi-phoenix.tar.gz from extracted blobs
```

---

## How It Works: Boot Chain

```
Qualcomm ABL (stock)
  └─→ U-Boot (sm7150-mainline, flashed to boot partition as Android boot image)
        └─→ systemd-boot (BOOTAA64.EFI on FAT32 ESP in userdata)
              └─→ linux.efi (kernel 6.18+ with EFI stub) + initramfs + DTB
                    └─→ postmarketOS
```

The Qualcomm ABL expects an Android boot image on the `boot` partition. U-Boot is packaged as one, and once loaded it provides a UEFI environment. U-Boot's UEFI implementation scans storage for an EFI System Partition (identified by GPT type GUID `C12A7328-...`) and boots systemd-boot from there.

The FAT32 ESP and rootfs are stored as a combined GPT image flashed to `userdata`.

---

## Prerequisites

- **Unlocked bootloader** — required; follow [Xiaomi's unlock process](https://en.miui.com/unlock/)
- **ADB / fastboot** tools installed on your computer
- **pmbootstrap** 3.9.0+ (required by current pmaports)
  - If your distro package is too old, clone pmbootstrap:
    `git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git ~/Documents/phoenix/pmbootstrap`
- **U-Boot** for SM7150 (see below)
- At least 4 GB free space for the build

---

## Installation

### Step 0: Fresh-system guide (recommended)

If this is your first install, follow [docs/FRESH-LINUX-STOCK-ROM.md](docs/FRESH-LINUX-STOCK-ROM.md) exactly.
It includes host package installation, stock ROM prerequisites, firmware tarball creation,
pmbootstrap setup, and flashing commands.

### Step 1: Get U-Boot

Download the U-Boot image from [sm7150-mainline/u-boot releases](https://github.com/sm7150-mainline/u-boot/releases).

> **Note:** No phoenix-specific U-Boot exists yet. Use the `davinci` (Xiaomi Mi 9T / Redmi K20) variant — it shares the same SM7150 SoC and works for booting.

```bash
wget https://github.com/sm7150-mainline/u-boot/releases/download/2025-12-02/u-boot-sm7150-xiaomi-davinci-samsung.img
```

### Step 2: Set up pmaports

Clone [pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) and sync this repo into it:

```bash
./scripts/sync-phoenix-port-into-pmaports.sh ~/Documents/phoenix/pmaports
```

The sync script copies both device packages, copies all kernel patches, and updates
`pmaports/device/community/linux-postmarketos-qcom-sm7150/APKBUILD` (`source=` and `sha512sums`) automatically.
It also ensures `CONFIG_DRM_PANEL_G7B_37_02_0A_DSC=m` in the kernel config to avoid interactive oldconfig prompts.
It also ensures `CONFIG_CHARGER_QCOM_SMB2=m` in the kernel config for PM6150 charger support.
The checksum update is source-order aware (`tarball`, `config`, then patches) to prevent
abuild checksum mismatches during kernel package builds.

### Step 3: Configure pmbootstrap

```bash
# IMPORTANT: fresh state, do not reuse old chroots/workdirs
./scripts/wipe-pmbootstrap-state.sh ~/Documents/phoenix/.pmbootstrap

./scripts/pmbootstrap-phoenix.sh init
# Select: device = xiaomi-phoenix, UI = phosh (or your choice), kernel = edge
```

### Step 4: Build and install

```bash
./scripts/pmbootstrap-phoenix.sh install --password YOUR_PASSWORD
```

Generated rootfs image (used for fastboot flashing):
`~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img`

### Step 5: Flash

Boot your device into fastboot mode (hold **Volume Down + Power**), then:

```bash
# 1. Flash U-Boot (replaces kernel on boot partition)
fastboot flash boot u-boot-sm7150-xiaomi-davinci-samsung.img

# 2. Erase dtbo (CRITICAL — stock overlays corrupt mainline DTB)
fastboot erase dtbo

# 3. Disable AVB verification
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta_system vbmeta_system.img

# 4. Flash combined rootfs image (FAT32 ESP + ext4 root) to userdata
./scripts/pmbootstrap-phoenix.sh flasher flash_rootfs

# 5. Reboot
fastboot reboot
```

### Step 6: Connect

After boot (~10–15 seconds), a USB network interface appears at `172.16.42.1`:

```bash
ssh user@172.16.42.1
```

---

## Firmware

The `firmware-xiaomi-phoenix` package requires proprietary firmware files extracted from the stock ROM. The package tarball should include a full firmware tree with at least:

```
lib/firmware/qcom/sm7150/phoenix/adsp.mbn
lib/firmware/qcom/sm7150/phoenix/cdsp.mbn
lib/firmware/qcom/sm7150/phoenix/modem.mbn
lib/firmware/qcom/sm7150/phoenix/wlanmdsp.mbn
lib/firmware/qcom/sm7150/phoenix/ipa_fws.mbn
lib/firmware/qcom/sm7150/phoenix/venus.mbn
lib/firmware/qcom/sm7150/phoenix/a615_zap.mbn
lib/firmware/novatek_nt36672c_g7b_fw01.bin
lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin
lib/firmware/qca/crbtfw21.tlv
lib/firmware/qca/crnv21.bin
```

Recommended tarball creation (from an assembled firmware tree):

```bash
./scripts/build-firmware-tarball.sh \
  --firmware-root /path/with/lib/firmware
```

Legacy minimal mode is still available with `--a615-zap` and `--novatek-fw`, but it is not enough for modem/remoteproc-dependent features.

These files can be extracted from stock MIUI partitions using [payload-dumper-go](https://github.com/ssut/payload-dumper-go) or similar tools. A pre-packaged base set is available at the [firmware-xiaomi-phoenix](https://github.com/Vanilla-s-Android-Stuff/firmware-xiaomi-phoenix) community repository.

**Firmware files are proprietary and are NOT included in this repository.**

---

## Building the Kernel from Source

The kernel patches in `kernel-patches/` apply on top of the [sm7150-mainline Linux fork](https://github.com/sm7150-mainline/linux):

```bash
git clone https://github.com/sm7150-mainline/linux.git
cd linux
git checkout v6.18
git apply ../kernel-patches/0001-dts-add-xiaomi-phoenix.patch
git apply ../kernel-patches/0002-phoenix-dts.patch
git apply ../kernel-patches/0003-phoenix-panel.patch
git apply ../kernel-patches/0004-pm6150-add-charger-support.patch
git apply ../kernel-patches/0005-add-wcn3998-wifi-bt-power-management.patch
git apply ../kernel-patches/0006-ath10k-qmi-treat-malformed-host-cap-as-non-fatal.patch
git apply ../kernel-patches/0007-pm6150-smb5-register-offsets.patch
```

Or use pmbootstrap which handles this automatically:

```bash
pmbootstrap build linux-postmarketos-qcom-sm7150
```

---

## Troubleshooting

### Device returns to fastboot immediately
- Make sure you flashed U-Boot to `boot`, NOT a Linux kernel or FAT32 image
- Verify `dtbo` was erased: `fastboot erase dtbo`
- Verify AVB was disabled

### "Failed to load/authenticate boot image: Load Error"
- This happens when trying to fastboot-boot a `linux.efi` directly — ABL can't boot EFI apps
- You must use U-Boot as the intermediary (see installation steps)

### USB network doesn't appear
- Wait at least 30 seconds after reboot
- Check `dmesg` on your computer for RNDIS device detection
- Ensure the combined image was fully flashed to `userdata` (all 4 sparse parts)

### WiFi / Ethernet not working — "NetworkManager Not Running"
- NetworkManager must be enabled as an OpenRC service (this is now handled by the device package)
- If you hit this on an older install, fix manually:
  ```bash
  doas rc-update add networkmanager default
  doas rc-service networkmanager start
  ```
- After NM starts, WiFi networks appear in Settings and USB-C hub ethernet works automatically

### WiFi MAC address changes on every boot
- This port now installs `phoenix-wlan-mac.service` to force a deterministic `wlan0` MAC before NetworkManager starts.
- The address is derived from device serial and persisted at `/var/lib/phoenix/wlan0-mac`.
- Verify with:
  ```bash
  cat /sys/class/net/wlan0/address
  cat /var/lib/phoenix/wlan0-mac
  systemctl status phoenix-wlan-mac.service
  ```

### Screen wakes up on notifications / task completion
- This port ships a locked dconf policy so normal notifications do not wake the display.
- Wakeup is restricted to physical wake actions (power button), which avoids random screen wake events.
- Verify the policy is active:
  ```bash
  gsettings get org.gnome.desktop.notifications show-banners
  gsettings get org.gnome.desktop.notifications show-in-lock-screen
  gsettings get sm.puri.phosh.notifications wakeup-screen-triggers
  gsettings writable org.gnome.desktop.notifications show-banners
  gsettings writable sm.puri.phosh.notifications wakeup-screen-triggers
  ```
- Expected values:
  - `show-banners` = `false`
  - `show-in-lock-screen` = `false`
  - `wakeup-screen-triggers` = `@as []`
  - both `gsettings writable ...` checks return `false` (policy lock is enforced)

### Settings app opens slowly / hangs (ModemManager timeout)
- This port masks `msm-modem-uim-selection.service` by default in the device package until modem firmware/userspace are fully ready.
- If you intentionally want to test modem bring-up, unmask it manually:
  ```bash
  doas rm -f /etc/systemd/system/msm-modem-uim-selection.service
  doas systemctl daemon-reload
  doas systemctl enable --now msm-modem-uim-selection.service
  ```

### Bluetooth not working
- The `bluetooth` OpenRC service must be running. The device package now enables it at boot.
- If you're on an older install, enable manually:
  ```bash
  doas rc-update add bluetooth default
  doas rc-service bluetooth start
  doas hciconfig hci0 up
  ```
- Verify with `hciconfig hci0` — should show `UP RUNNING`

### USB-C hub ethernet drops when charging or adding USB devices
- **Known limitation**: When a charger or additional USB device is plugged into the same USB-C hub, the phone's Type-C port may undergo a USB PD power role swap. The kernel TCPM driver (qcom,pm6150-typec) renegotiates the USB-C connection, which can reset the DWC3 USB controller and disconnect all downstream devices (hub, ethernet adapter).
- The DT connector is configured with `data-role = "dual"` and `power-role = "dual"` (`try-power-role = "sink"`). Role renegotiation can still disrupt the USB host session on some hubs.
- **Workaround**: Only connect ethernet via the USB-C hub. Do not plug a charger into the same hub while ethernet is in use.
- **Future fix**: A DTS overlay could lock the connector to `data-role = "host"` to prevent role swaps, but this would disable USB gadget/RNDIS mode when connected directly to a PC.

### Audio not working / ADSP crash loop
- The ADSP remoteproc runs but its sensor user-PD subprocess crashes repeatedly with: `USER-PD DOG detects stalled initialization`
- This causes `q6asm-dai` probe to fail (error -22), preventing audio initialization
- Root cause: missing sensor process firmware for phoenix. The ADSP sensor watchdog times out every ~40 seconds and restarts.
- This is a known issue on SM7150 mainline — proper sensor firmware extraction and hexagonrpcd configuration may resolve it.
- Check `dmesg | grep -i "fatal error"` to see the crash cycle

### Display/panel issues in U-Boot
- U-Boot uses the `davinci` device tree; the phoenix display panel differs
- This may cause garbled or no display in U-Boot, but Linux will initialize the panel correctly
- Boot will still proceed even if U-Boot display is blank

### Reboot / shutdown not working from phosh menu
- The phosh power menu uses `elogind` (via D-Bus) to trigger reboot/shutdown. If `elogind` is not running, the menu appears but times out after 60 seconds without acting.
- The device package now enables elogind at boot. For older installs, fix manually:
  ```bash
  doas rc-update add elogind default
  doas rc-service elogind start
  ```
- You can also reboot via SSH: `doas reboot` or `loginctl reboot`

### Charging is inconsistent
- The PM6150 charger path is enabled by `0004-pm6150-add-charger-support.patch`.
- `0007-pm6150-smb5-register-offsets.patch` fixes PM6150 charger online/current register offset handling (SMB5-style status offsets), improving charging detection.
- Charging behavior is still inconsistent across power bricks/hubs/cables because USB-C PD role negotiation can still reset the link.
- For long debug sessions, pre-charge in Android or use a stable direct charger path (not a multi-function hub).
- Battery level is visible at `/sys/class/power_supply/qcom_qg/capacity`

---

## Contributing

Contributions welcome! Areas that need work:

- **Charging robustness** — improve PM6150 USB-C role/negotiation stability across different hubs/chargers
- **Phoenix-specific U-Boot DTS** — port the davinci U-Boot DT to phoenix for correct display in U-Boot
- **Audio** — fix ADSP sensor PD crash that prevents q6asm-dai initialization
- **Modem** — test cellular/call functionality
- **Sensors** — extract and package sensor PD firmware for ADSP
- **Submit to pmaports** — once stable, upstream these packages to [pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports)

Please follow the [postmarketOS contributing guidelines](https://wiki.postmarketos.org/wiki/Contributing) when submitting patches to pmaports.

---

## Related Projects & Documentation

| Resource | Link |
|----------|------|
| postmarketOS | https://postmarketos.org |
| pmaports (package repo) | https://gitlab.postmarketos.org/postmarketOS/pmaports |
| SM7150 mainline Linux | https://github.com/sm7150-mainline/linux |
| SM7150 U-Boot | https://github.com/sm7150-mainline/u-boot |
| SM7150 wiki (postmarketOS) | https://wiki.postmarketos.org/wiki/Qualcomm_SM7150-AC_Snapdragon_732G |
| phoenix wiki (postmarketOS) | https://wiki.postmarketos.org/wiki/Xiaomi_Redmi_K30_4G_(xiaomi-phoenix) |
| SM7150 generic migration post | https://postmarketos.org/edge/2025/03/09/sm7150-generic-migration/ |
| U-Boot on Qualcomm phones | https://docs.u-boot.org/en/latest/board/qualcomm/phones.html |
| pmbootstrap docs | https://wiki.postmarketos.org/wiki/Pmbootstrap |
| Fresh host + stock ROM runbook | [docs/FRESH-LINUX-STOCK-ROM.md](docs/FRESH-LINUX-STOCK-ROM.md) |
| Deviceinfo reference | https://wiki.postmarketos.org/wiki/Deviceinfo_reference |
| Firmware extraction guide | https://wiki.postmarketos.org/wiki/Firmware |
| Tauchgang (U-Boot releases) | https://tauchgang.dev |
| sm7150-mainline community | https://matrix.to/#/#sm7150-mainline:matrix.org |
| XDA thread (phoenix pmos) | https://xdaforums.com/t/poco-x2-porting-a-linux-project-postmarketos-to-this-smartphone.4308905/ |

---

## License

Device package files (`device-xiaomi-phoenix/`) are licensed under **MIT**.
Kernel patches (`kernel-patches/`) are licensed under **GPL-2.0-only**, matching the Linux kernel.
Firmware package metadata (`firmware-xiaomi-phoenix/`) is a build recipe only; the firmware itself is proprietary Qualcomm/Xiaomi IP.

See [LICENSE](LICENSE) for the MIT license text.
