# postmarketOS port for Xiaomi POCO X2 / Redmi K30 4G (phoenix)

> **Status: Working** — boots to phosh UI, WiFi, USB networking, display, touchscreen functional.

This repository contains the pmaports packages and kernel patches needed to run [postmarketOS](https://postmarketos.org) on the **Xiaomi POCO X2** (Indian market) / **Xiaomi Redmi K30 4G** (Global), codename **phoenix**, powered by the Qualcomm Snapdragon 730G (SM7150-AB).

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
| USB networking (RNDIS) | 🔧 Untested |
| WiFi | 🔧 Untested |
| Bluetooth | 🔧 Untested |
| Audio | 🔧 Untested |
| Camera | ❌ Not working |
| Modem / calls | 🔧 Untested |
| GPS | 🔧 Untested |
| Sensors | 🔧 Untested |
| Battery / charging | 🔧 Untested |
| 3D acceleration | 🔧 Untested |
| SD card | 🔧 Untested |

---

## Repository Structure

```
├── device-xiaomi-phoenix/       # pmaports device package
│   ├── APKBUILD                 # Package build definition
│   ├── deviceinfo               # Device configuration for pmbootstrap
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
│   └── 0003-phoenix-panel.patch            # NT36672C display panel support
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
- **pmbootstrap** 3.9.0+ — install with: `pip install pmbootstrap`
- **U-Boot** for SM7150 (see below)
- At least 4 GB free space for the build

---

## Installation

### Step 1: Get U-Boot

Download the U-Boot image from [sm7150-mainline/u-boot releases](https://github.com/sm7150-mainline/u-boot/releases).

> **Note:** No phoenix-specific U-Boot exists yet. Use the `davinci` (Xiaomi Mi 9T / Redmi K20) variant — it shares the same SM7150 SoC and works for booting.

```bash
wget https://github.com/sm7150-mainline/u-boot/releases/download/2025-12-02/u-boot-sm7150-xiaomi-davinci-samsung.img
```

### Step 2: Set up pmaports

Clone [pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) and copy the packages from this repo:

```bash
git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git
# Copy device package
cp -r device-xiaomi-phoenix/ pmaports/device/testing/
# Copy firmware package
cp -r firmware-xiaomi-phoenix/ pmaports/device/testing/
# Apply kernel patches
cp kernel-patches/*.patch pmaports/device/community/linux-postmarketos-qcom-sm7150/
```

Then update `pmaports/device/community/linux-postmarketos-qcom-sm7150/APKBUILD` to include the patches in its `source=` list and update sha512sums.

### Step 3: Configure pmbootstrap

```bash
pmbootstrap init
# Select: device = xiaomi-phoenix, UI = phosh (or your choice), kernel = edge
```

### Step 4: Build and install

```bash
pmbootstrap install --password YOUR_PASSWORD
```

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
pmbootstrap flasher flash_rootfs

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

The `firmware-xiaomi-phoenix` package requires proprietary firmware files extracted from the stock ROM. The APKBUILD expects a tarball containing:

```
lib/firmware/qcom/sm7150/phoenix/a615_zap.mbn
lib/firmware/novatek_nt36672c_g7b_fw01.bin
```

These can be extracted from a stock MIUI ROM using [payload-dumper-go](https://github.com/ssut/payload-dumper-go) or similar tools. A pre-packaged tarball is available at the [firmware-xiaomi-phoenix](https://github.com/Vanilla-s-Android-Stuff/firmware-xiaomi-phoenix) community repository.

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

### Display/panel issues in U-Boot
- U-Boot uses the `davinci` device tree; the phoenix display panel differs
- This may cause garbled or no display in U-Boot, but Linux will initialize the panel correctly
- Boot will still proceed even if U-Boot display is blank

---

## Contributing

Contributions welcome! Areas that need work:

- **Phoenix-specific U-Boot DTS** — port the davinci U-Boot DT to phoenix for correct display in U-Boot
- **Audio** — test and enable audio drivers
- **Modem** — test cellular/call functionality
- **Sensors** — IIO sensor drivers
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
