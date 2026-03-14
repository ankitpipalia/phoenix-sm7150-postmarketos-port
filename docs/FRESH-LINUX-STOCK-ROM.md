# Fresh Linux + Stock MIUI to postmarketOS (Phosh)

This guide is the full, reproducible path for a **fresh Linux host** and a phone on **stock MIUI** to a working postmarketOS Phosh boot on `xiaomi-phoenix` (POCO X2 / Redmi K30 4G).

It assumes:

- Device codename: `phoenix`
- SoC: `SM7150`
- Bootloader: **already unlocked**
- Device state before flashing: **fastboot mode**

If you only need fastboot commands, see [../FLASHING.md](../FLASHING.md).

---

## 1. Host Prerequisites (Fresh Linux)

Install core tools:

- `git`, `curl`, `python3`, `tar`, `sha512sum`
- `adb`, `fastboot`
- `sudo`

Examples:

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y git curl python3 python3-pip adb fastboot tar coreutils

# Fedora
sudo dnf install -y git curl python3 python3-pip android-tools tar coreutils

# Arch
sudo pacman -S --needed git curl python python-pip android-tools tar coreutils
```

Quick checks:

```bash
python3 --version
fastboot --version
adb version
```

---

## 2. Prepare Workspace

Recommended layout:

```text
~/Documents/phoenix/
├── phoenix-sm7150-postmarketos-port/      # this repository (source of truth)
├── pmaports/                               # postmarketOS package tree
├── pmbootstrap/                            # pmbootstrap source checkout
├── fastboot-stock-rom/                     # extracted MIUI fastboot ROM
└── stock-rom/                              # optional payload-based stock extraction
```

Clone tools/repos if missing:

```bash
mkdir -p ~/Documents/phoenix
cd ~/Documents/phoenix

# Source-of-truth port repo
git clone <your-phoenix-port-repo-url> phoenix-sm7150-postmarketos-port

# pmaports + pmbootstrap
git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git
git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git
```

---

## 3. Stock ROM Inputs (Required)

From extracted MIUI fastboot ROM, ensure these exist:

```text
~/Documents/phoenix/fastboot-stock-rom/images/vbmeta.img
~/Documents/phoenix/fastboot-stock-rom/images/vbmeta_system.img
```

Check:

```bash
ls -lh ~/Documents/phoenix/fastboot-stock-rom/images/vbmeta*.img
```

Do **not** relock bootloader after flashing stock if you plan to run postmarketOS.

---

## 4. Build Proprietary Firmware Tarball

This port expects:

- `a615_zap.mbn`
- `novatek_nt36672c_g7b_fw01.bin`

If you extracted stock payload/firmware already, build package tarball:

```bash
cd ~/Documents/phoenix/phoenix-sm7150-postmarketos-port

./scripts/build-firmware-tarball.sh \
  --a615-zap /absolute/path/to/a615_zap.mbn \
  --novatek-fw /absolute/path/to/novatek_nt36672c_g7b_fw01.bin
```

Expected output:

```text
~/Documents/phoenix/phoenix-sm7150-postmarketos-port/firmware-xiaomi-phoenix/firmware-xiaomi-phoenix.tar.gz
```

---

## 5. Sync Port Into pmaports

Run from port repo root:

```bash
cd ~/Documents/phoenix/phoenix-sm7150-postmarketos-port
./scripts/sync-phoenix-port-into-pmaports.sh ~/Documents/phoenix/pmaports
```

What this script does:

- copies `device-xiaomi-phoenix` and `firmware-xiaomi-phoenix` into `device/testing`
- copies kernel patches into `device/community/linux-postmarketos-qcom-sm7150`
- updates kernel `source=` and `sha512sums`
- enforces `CONFIG_DRM_PANEL_G7B_37_02_0A_DSC=m` in kernel config
- updates checksums in correct source order (`tarball`, `config`, patches) to avoid abuild mismatch

---

## 6. Reset pmbootstrap State (Fresh Start)

```bash
cd ~/Documents/phoenix/phoenix-sm7150-postmarketos-port
./scripts/wipe-pmbootstrap-state.sh
```

Then initialize:

```bash
./scripts/pmbootstrap-phoenix.sh init
```

Choose:

- Channel: `systemd-edge`
- Device: `xiaomi-phoenix`
- UI: `phosh`

---

## 7. Build + Create Install Image

Create install image:

```bash
cd ~/Documents/phoenix/phoenix-sm7150-postmarketos-port
./scripts/pmbootstrap-phoenix.sh install --password YOUR_PASSWORD
```

This can take a while on first run.

Generated image path:

```text
~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img
```

Optional validation builds:

```bash
./scripts/pmbootstrap-phoenix.sh build firmware-xiaomi-phoenix
./scripts/pmbootstrap-phoenix.sh build device-xiaomi-phoenix
./scripts/pmbootstrap-phoenix.sh build linux-postmarketos-qcom-sm7150 --force
```

---

## 8. Download U-Boot (davinci variant)

No phoenix-specific U-Boot exists yet; use davinci release:

```bash
mkdir -p ~/Documents/phoenix/artifacts
cd ~/Documents/phoenix/artifacts

curl -fL -o u-boot-sm7150-xiaomi-davinci-samsung.img \
  https://github.com/sm7150-mainline/u-boot/releases/download/2025-12-02/u-boot-sm7150-xiaomi-davinci-samsung.img
```

---

## 9. Flash to Device (Phone in Fastboot Mode)

Verify device:

```bash
fastboot devices
```

Flash sequence:

```bash
# 1) U-Boot to boot partition
fastboot flash boot ~/Documents/phoenix/artifacts/u-boot-sm7150-xiaomi-davinci-samsung.img

# 2) Remove stock DTBO overlays (required for mainline DT)
fastboot erase dtbo

# 3) Disable AVB checks
fastboot --disable-verity --disable-verification flash vbmeta \
  ~/Documents/phoenix/fastboot-stock-rom/images/vbmeta.img

fastboot --disable-verity --disable-verification flash vbmeta_system \
  ~/Documents/phoenix/fastboot-stock-rom/images/vbmeta_system.img

# 4) Flash combined pmOS image to userdata
fastboot flash userdata \
  ~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img

# 5) Reboot
fastboot reboot
```

Notes:

- `fastboot flash userdata` transfers sparse chunks (often 4 parts)
- Message `Invalid sparse file format at header magic` can appear before sparse transfer and is typically benign

---

## 10. First Boot Validation

Expected behavior:

- U-Boot text may briefly show `Model: Xiaomi Mi 9T (Samsung)` (davinci U-Boot)
- U-Boot panel output can be wrong/blank before Linux takes over
- Linux should boot and bring up USB networking

Connect over USB network:

```bash
ssh user@172.16.42.1
```

Use password passed to `pmbootstrap install --password`.

---

## 11. Iteration Workflow (After First Success)

For code/patch updates:

```bash
cd ~/Documents/phoenix/phoenix-sm7150-postmarketos-port
./scripts/sync-phoenix-port-into-pmaports.sh ~/Documents/phoenix/pmaports
./scripts/pmbootstrap-phoenix.sh build linux-postmarketos-qcom-sm7150 --force
./scripts/pmbootstrap-phoenix.sh install --password YOUR_PASSWORD
fastboot flash userdata ~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img
fastboot reboot
```

Only reflash `boot` if you changed U-Boot image.

---

## 12. Known Limitations

- Audio remains broken (ADSP sensor PD crash loop)
- Sensors are incomplete (firmware/user-PD path not finalized)
- USB-C hub + simultaneous charging can cause link resets
- U-Boot display is imperfect until phoenix-specific U-Boot DTS exists

