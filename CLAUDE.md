# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A postmarketOS **device port** for the Xiaomi POCO X2 / Redmi K30 4G (codename `phoenix`, SoC SM7150-AB / Snapdragon 730G). It is **not** a standalone software project — it is the source-of-truth for three things that get fed into upstream postmarketOS tooling:

1. `device-xiaomi-phoenix/` — pmaports device package (Alpine `APKBUILD` + helper units/policies that get installed into the image).
2. `firmware-xiaomi-phoenix/` — pmaports firmware package recipe (the actual `.mbn`/`.bin` blobs are proprietary, are NOT in the repo, and are gitignored — they are extracted from stock MIUI and assembled into `firmware-xiaomi-phoenix.tar.gz` locally).
3. `kernel-patches/` — DTS + driver patches applied on top of [sm7150-mainline/linux](https://github.com/sm7150-mainline/linux) (currently v7.1_rc3, tracked by upstream pmaports) via the kernel package `linux-postmarketos-qcom-sm7150`. **pmaports requires pmbootstrap ≥ 3.9.0** (the old PyPI 2.x is too old for the current pmaports.cfg schema). Clone pmbootstrap source from GitLab if your distro ships an older version.

All builds, installs and flashes happen through `pmbootstrap` against a clone of [pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports). This repo never builds anything on its own — it ships content into pmaports via `scripts/sync-phoenix-port-into-pmaports.sh`.

## Expected workspace layout

The wrapper scripts in `scripts/` resolve paths via `$(dirname "$0")/../..`, so they assume this repo sits inside a sibling-laid-out workspace:

```
~/Documents/phoenix/
├── phoenix-sm7150-postmarketos-port/   # this repo
├── pmaports/                            # postmarketOS package tree (cloned)
├── pmbootstrap/                         # pmbootstrap source checkout (optional; falls back to system pmbootstrap)
├── pmbootstrap.cfg                      # config consumed via `-c`
├── .pmbootstrap/                        # pmbootstrap workdir (`-w`)
└── fastboot-stock-rom/, stock-rom/, artifacts/   # vbmeta blobs, u-boot image, etc.
```

If you move the repo, the scripts break — they don't auto-discover pmaports/pmbootstrap. `docs/FRESH-LINUX-STOCK-ROM.md` is the canonical end-to-end runbook.

## Core workflow

```bash
# 1. Push local edits into pmaports + refresh checksums + kernel config
./scripts/sync-phoenix-port-into-pmaports.sh ~/Documents/phoenix/pmaports

# 2. Build the kernel (force after patch changes)
./scripts/pmbootstrap-phoenix.sh build linux-postmarketos-qcom-sm7150 --force

# 3. Build the install image
./scripts/pmbootstrap-phoenix.sh install --password YOUR_PASSWORD
# → ~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img

# 4. Flash to phone in fastboot mode
fastboot flash userdata ~/Documents/phoenix/.pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-phoenix.img
fastboot reboot

# Other useful pmbootstrap subcommands (all proxied through the wrapper):
./scripts/pmbootstrap-phoenix.sh init                              # interactive setup, OR write pmbootstrap.cfg directly (`systemd = always`, `device = xiaomi-phoenix`, `ui = phosh`, `boot_size = 512`, `build_pkgs_on_install = True`). pmbootstrap 3.x has no separate `systemd-edge` channel — it's `edge` + `systemd = always`.
./scripts/pmbootstrap-phoenix.sh build firmware-xiaomi-phoenix
./scripts/pmbootstrap-phoenix.sh build device-xiaomi-phoenix
./scripts/pmbootstrap-phoenix.sh flasher flash_rootfs              # flash rootfs without manual fastboot
./scripts/pmbootstrap-phoenix.sh shutdown                          # release chroots

# Nuke pmbootstrap state for a clean start (use sparingly — re-init required after)
./scripts/wipe-pmbootstrap-state.sh
```

Focused host-side regression tests now cover the battery helpers and pmaports
sync transformations:

```sh
sh tests/test-battery-tools.sh
bash tests/test-sync-phoenix-port.sh
```

They do not replace `pmbootstrap build`/`install` or live boot/dmesg validation
on the device over SSH at `user@172.16.42.1` (RNDIS).

## What `sync-phoenix-port-into-pmaports.sh` actually does (important)

Don't bypass this script with manual `cp` — it does several things you have to reproduce by hand otherwise:

- Copies `device-xiaomi-phoenix/` and `firmware-xiaomi-phoenix/` into `pmaports/device/testing/` (not `community/` — until upstreamed).
- Deletes only **previously-managed** `*.patch` files under `pmaports/device/community/linux-postmarketos-qcom-sm7150/` via a `.phoenix-managed-patches` manifest written by the previous sync run (unrelated upstream-pmaports patches in that dir are preserved). It then re-copies all `kernel-patches/*.patch`. If you ever `cp` a patch in by hand and need it tracked, you must also append it to that manifest, or the next sync will leave it stale.
- Rewrites the `source=` and `sha512sums=` blocks in the upstream kernel `APKBUILD` (`device/community/linux-postmarketos-qcom-sm7150/APKBUILD`). The checksum order is **source-order aware** (config first, then patches in `LC_COLLATE` sort order) — abuild's verification is order-sensitive, so reordering by hand breaks builds.
- Enforces required kernel config symbols in `config-postmarketos-qcom-sm7150.aarch64` to avoid interactive `oldconfig` prompts:
  - `CONFIG_DRM_PANEL_G7B_37_02_0A_DSC=m` (phoenix NT36672C panel from patch 0003)
  - `CONFIG_CHARGER_QCOM_SMB2=m` (PM6150 charger driver)
  - `CONFIG_NFT_FIB_INET=m` and `CONFIG_NFT_REDIR=m` (netavark's nftables ruleset for podman/k3s container networking; absent upstream, every bridged container fails without them)
- Recomputes and rewrites the kernel-config sha512 entry in the kernel APKBUILD since the config file was mutated above.

The script is intentionally portable across BSD-awk (macOS) and GNU-awk; multi-line strings are passed via `getline … < file` and `sed -i` is replaced with `sed > tmp && mv` — don't "simplify" back to GNU-only forms.

If you add a new kernel patch: drop the `NNNN-...patch` file in `kernel-patches/` with the right numeric prefix and re-run the sync script — it picks them up by glob. If you add a new file to a device-package `source=` list, you must also update that package's `sha512sums=` manually (the sync script only manages the kernel APKBUILD's checksums, not the device/firmware package ones).

## Boot chain (for changes that touch boot)

```
Qualcomm ABL (stock, on boot partition normally)
  └─ U-Boot from sm7150-mainline (flashed AS an Android boot image to `boot`)
        └─ systemd-boot (BOOTAA64.EFI on a FAT32 ESP, identified by GPT type GUID C12A7328-...)
              └─ linux.efi (kernel 7.1_rc3 with EFI stub) + initramfs + DTB
                    └─ postmarketOS userspace
```

The combined GPT image (FAT32 ESP + ext4 root in one file) is flashed to `userdata`. `deviceinfo` sets `deviceinfo_efi_boot="true"`, `deviceinfo_boot_filesystem="fat32"`, and `deviceinfo_flash_method="fastboot"` to drive this.

Phoenix uses the **davinci** U-Boot variant (`u-boot-sm7150-xiaomi-davinci-samsung.img`) because no phoenix-specific U-Boot exists — same SoC, different display, so U-Boot's framebuffer is wrong/blank until Linux takes over. Don't "fix" this by changing the deviceinfo to expect a phoenix U-Boot until one actually exists.

`fastboot erase dtbo` is **required** every flash because stock DTBO overlays corrupt the mainline DTB. The combined-image flash is sparse (~3.3 GB, 4 chunks); `Invalid sparse file format at header magic` printed before the chunks is benign.

## Gotchas the patches/units exist to work around

These are non-obvious and easy to undo accidentally — be careful before "simplifying" them:

- **`device-xiaomi-phoenix.post-install` masks `msm-modem-uim-selection.service`** by symlinking it to `/dev/null` and removes its `RequiredBy=` link from `ModemManager.service.requires/`. Without this, ModemManager waits 60s for UIM selection and drags down Settings. Unmask only after modem firmware/userspace is actually wired up.
- **`phoenix-wlan-mac.service` + `phoenix-wlan-mac.sh`** derive a deterministic locally-administered MAC for `wlan0` (SHA-256 of `/proc/device-tree/serial-number` → `02:xx:xx:xx:xx:xx`, persisted at `/var/lib/phoenix/wlan0-mac`) and apply it **before** NetworkManager comes up. `90-phoenix-mac.conf` disables NM's randomized-MAC mode. Without this, ath10k falls back to a random MAC every boot when calibration data is missing, and DHCP leases churn.
- **Notification wake policy** is enforced via a *locked* dconf default (`00-phoenix-notification-policy` + `.lock` + `dconf-profile-user`), not just user settings — verify with `gsettings writable …` returning `false`. Patch 0003 (panel) and the lack of a backlight-only wake path makes notification wake-up cycle the whole display, hence the lockdown.
- **The package deliberately does not install general passwordless sudo/doas policy.** The device package still depends on `doas` (not `doas-sudo-shim`) for authenticated administration; current pmaports `postmarketos-base-systemd` ships `sudo-rs`, and `doas-sudo-shim` conflicts with it.
- **OpenRC default-runlevel symlinks** for `networkmanager`, `bluetooth`, `elogind` are created in the APKBUILD's `package()` function. elogind in particular is required for the phosh power menu (reboot/shutdown) to work via D-Bus. These dangle harmlessly on systemd-edge installs.
- **Kernel patch 0004 (USB-C dual-role)** enables sink-pdo + dual-role on `&pm6150_typec` — the rest of the original 0004 (charger node, ADC channels, match-table) is upstream in v7.1_rc3 and was dropped. Don't re-add the `qcom_smbx.c` match-table entry: upstream changed `.data` from `char *` to `struct smb_match_data *` and a stale entry will silently break charger probe.
- **Kernel patch 0005 (WCN3998 + UART3)** is two surviving hunks: (a) `&qup_uart3_sleep` cts-pins `bias-bus-hold → bias-pull-up` — `bias-bus-hold` is invalid on the main SM7150 TLMM (only `lpass_tlmm` supports it) and is silently ignored, leaving CTS floating during sleep; (b) `qcom,snoc-host-cap-8bit-quirk` on `&wifi` — without it WCN3998 QMI bring-up fails. Battery chemistry, WCN3998 BT compatible, and UART3 pinctrl active-state are all upstream in v7.1.
- **Kernel patch 0006 (ath10k QMI host-cap non-fatal)** lets WCN3990 keep coming up when the QMI host-cap response is malformed (firmware-version-specific quirk on phoenix's WCN3998 actually identifying as WCN3990).
- **PM6150 SMB5 register offsets are upstream in v7.1_rc3.** The phoenix-local `0007-pm6150-smb5-register-offsets.patch` was deleted during the v7.1 rebase. On v7.1 the charger binds via the `qcom,pm8150b-charger` fallback compatible and uses the SMB5 path natively — `STATUS` now reflects reality (`Full`/`Charging`) rather than the v6.18 stuck `Not charging`.
- **Patches 0010–0017 harden SMB5 charging.** They provide true charge inhibition, correct status/OV/ICL/scaling and watchdog handling, enforce explicit-PD 5–12 V with 1.5 A/15 W caps, fix the SMB5 load-register offset, rerun AICL when entering an override, apply high-current override to trusted DCP/CDP, program the continuous 5–12 V adapter window needed by the tested 8.9 V dock path, and add bounded retries after a transient offline power-path reading. AICL and suspend-on-collapse remain enabled. Validate QGauge/TCPM and raw PMIC status after every kernel rebase.
- **`/etc/apk/world` doesn't always reflect deletions.** A device pkg `depends="…doas-sudo-shim…"` line gets pinned into world during install, so removing the dependency from the APKBUILD doesn't remove the world entry; flash a fresh image or `apk del doas-sudo-shim` post-upgrade if you ever re-add+remove a dep.
- **`adsp-disable-recovery.service` is load-bearing for thermal/battery.** Phoenix's ADSP firmware's `sensor_process` PD crashes at `SNS_REG_INIT` (`sns_registry_sensor.c:94: SNS_RC_SUCCESS == rc`) every time. The default `qcom_q6v5_pas` `recovery=enabled` policy then restarts the entire ADSP every ~4 s — observed ~11 crashes/min, package temp ~64 °C at 0.12 load, and a battery drain that empties a charged battery in ~1 h. The service writes `disabled` to `/sys/class/remoteproc/remoteproc0/recovery` early in `sysinit.target`; do NOT remove or disable it without also fixing the firmware probe (no known fix without proprietary sensor registry). Audio is broken anyway (`q6asm-dai` probe `-22`), and `cdsp`/`modem` remoteprocs are independent.
- **Headless mode is the packaged default.** `default.target` points to `multi-user.target`, `greetd` is disabled, and `phoenix-screen-off.service` blanks and powers down the internal backlight. `phoenix-usb-host-wake.service` is enabled and its 45-second role-toggle recovery brought up the tested dock's Ethernet two seconds later. SSH and networking remain active. Re-enable `greetd` and select `graphical.target` only when deliberately returning to phone/GUI use.
- **`phoenix-charge-cap.timer` exists for 24/7 server use; disabled by default.** It uses voltage hysteresis (4.00-4.10 V by default) and patch 0010's `charge_behaviour=inhibit-charge`, which leaves USB input online. It refuses to run on an old kernel rather than falling back to `STATUS`/`USBIN_SUSPEND`. Adjust `/etc/phoenix-charge-cap.conf` (`START_VOLTAGE_UV=`, `STOP_VOLTAGE_UV=`). To disable it while safely releasing an inhibit owned by the limiter, run `systemctl disable --now phoenix-charge-cap.timer && systemctl start phoenix-charge-cap-reset.service`; reset deliberately does not depend on QGauge data and never clears an external controller's inhibit.
- **`phoenix-battery-safety.service` is a separate shutdown guard; disabled by default.** It watches voltage, discharge current, source presence, and temperature every five seconds. Validate its conservative thresholds in a controlled source-loss test before enabling it on an unattended device.
- **`phoenix-typec-recover.timer` rescues "stuck as source" Type-C state; disabled by default.** When charger is briefly removed while a hub is still attached, the Type-C stack can swap to source/host so the hub keeps running on battery. The timer requires `[source]`, charger offline and a partner, then uses low voltage as its primary urgency signal and the voltage-derived level as a fallback when both voltage attributes are missing or invalid. It forces a manual swap by writing `sink`; if no external power appears, it reverts to `source` so the hub stays powered. Configure `/etc/phoenix-typec-recover.conf` and opt in with `systemctl enable --now phoenix-typec-recover.timer`.
- **Podman on the shipped kernel needs `firewall_driver = "none"`.** The 7.1_rc3 config lacks `CONFIG_NFT_FIB_INET`/`CONFIG_NFT_REDIR`, so netavark's nftables ruleset fails and netavark 2.x has no iptables fallback; `/etc/containers/containers.conf.d/10-phoenix.conf` disables netavark's firewall and `52_phoenix_eth_trust.nft` carries the `podman0` NAT/forward rules instead. Bridged containers therefore cannot publish ports — use `Network=host` (Portainer does) until a kernel built with the sync script's enforced symbols is installed. Also leave `cgroup_manager` at the default `cgroupfs`: Alpine's crun has no systemd support.
- **`modules-initfs`** only lists three modules (`nt36xxx-spi`, `panel_g7b_37_02_0a_dsc`, `qcom_wled`) — what's needed for the panel/touch path to come up in initramfs. Adding modules here grows the initramfs unnecessarily; only add what's blocking early-boot display/IO.

## Firmware tarball (`scripts/build-firmware-tarball.sh`)

The firmware-xiaomi-phoenix package expects `firmware-xiaomi-phoenix.tar.gz` *next to its APKBUILD* (the file is gitignored). Two modes:

- `--firmware-root <path>` — recommended; packages a full `lib/firmware/` tree and verifies all 9 required blobs are present (`a615_zap.mbn`, `adsp.mbn`, `cdsp.mbn`, `modem.mbn`, `wlanmdsp.mbn`, `ipa_fws.mbn`, `venus.mbn`, `novatek_nt36672c_g7b_fw01.bin`, and the stock Phoenix `ath10k/WCN3990/hw1.0/board.bin`). Strips duplicates already provided by `firmware-qcom-adreno-a630` (`a630_gmu.bin`, `a630_sqe.fw`) to avoid APK file-conflicts.
- `--a615-zap` + `--novatek-fw` — legacy minimal mode (panel + GPU only). Enough for display, not enough for modem/DSP/WiFi.

After regenerating the tarball, also update its sha512 in `firmware-xiaomi-phoenix/APKBUILD` (the sync script does NOT touch this — it's the firmware package's own APKBUILD, not the kernel one). `30-initramfs-firmware-xiaomi-phoenix.files` controls which firmware blobs get pulled into the initramfs (currently only the GPU zap + panel firmware).

## Repo conventions

- `.gitignore` blocks `*.bin`, `*.mbn`, `*.tar.gz`, `*.img` — firmware/images never enter the tree.
- Device package files: MIT. Kernel patches: GPL-2.0-only (matches Linux). The split matters when copying snippets between dirs.
- Patches in `kernel-patches/` are numbered and applied in order — `sync-phoenix-port-into-pmaports.sh` sorts them lexicographically before assembling `source=` and `sha512sums=`. New patches should pick the next free `NNNN-` prefix; don't renumber existing ones unless you also re-run sync to refresh checksums.
