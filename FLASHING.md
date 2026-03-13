# Flashing Guide — Xiaomi POCO X2 / Redmi K30 4G

Quick-reference for flashing postmarketOS. See [README.md](README.md) for full installation instructions.

## Required Files

| File | Where to Get |
|------|-------------|
| `u-boot-sm7150-xiaomi-davinci-samsung.img` | [sm7150-mainline/u-boot releases](https://github.com/sm7150-mainline/u-boot/releases) |
| `xiaomi-phoenix.img` | Built by `pmbootstrap install` |
| `vbmeta.img` + `vbmeta_system.img` | From stock MIUI ROM (fastboot-stock-rom/) |

## Enter Fastboot Mode

Power off the device, then hold **Volume Down + Power** until the fastboot screen appears.

## Flash Commands (in order)

```bash
# 1. U-Boot — UEFI intermediate bootloader
fastboot flash boot u-boot-sm7150-xiaomi-davinci-samsung.img

# 2. Erase device tree overlays — REQUIRED for mainline kernel
fastboot erase dtbo

# 3. Disable Android Verified Boot
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta_system vbmeta_system.img

# 4. Flash rootfs (FAT32 ESP + ext4, combined) to userdata
fastboot flash userdata xiaomi-phoenix.img

# 5. Reboot
fastboot reboot
```

> **Note:** Step 4 flashes a ~3.3 GB sparse image and takes 2–3 minutes.

## After Boot

USB network interface will appear on your computer within ~15 seconds of reboot.

```bash
ssh user@172.16.42.1        # password set during pmbootstrap install
```

## Re-flashing Only the OS (keeping U-Boot)

If U-Boot is already installed and you only want to update postmarketOS:

```bash
fastboot flash userdata xiaomi-phoenix.img
fastboot reboot
```

## Restoring Stock MIUI

Flash the stock boot image and re-lock:

```bash
fastboot flash boot stock_boot.img
fastboot flash dtbo stock_dtbo.img
fastboot flash vbmeta stock_vbmeta.img
fastboot flash userdata stock_userdata.img   # or fastboot erase userdata
fastboot reboot
```
