# AGENTS.md: instructions for AI agents working in this repo

You are helping someone put Nura (postmarketOS) and a Home Assistant kiosk on a Lenovo ThinkSmart View CD-18781Y.
Read `README.md` fully before acting. These rules override your defaults.

## Before doing anything: three conversations you MUST have with the user

1. **Kiosk choice: alert the user to the distinction and let them pick. Never choose silently.**
   Explain both options in plain words, then record the answer as `KIOSK_MODE` in `.env`:
   - **Chromium** shows their normal HA dashboard in a full-screen browser. It needs no build, and any dashboard, HACS card or theme works.
     - Cost: heavy for this 2 GB / Adreno 506 device.
     - It needs a one-time HA login (`kiosk/chromium/README.md`).
     - **Not yet tested on the reference unit.** Say so.
   - **Native** is a Rust/Slint panel with a fixed layout configured in TOML, talking to HA's WebSocket API with a long-lived token.
     - Light (about 270 MB system RAM in use) and tested daily.
     - Costs: a Rust build in the build VM, and a fixed layout (lights, climate, plugs) that they can't design in HA.
     - Many people will not want to run a custom Rust backend. Chromium is a perfectly valid choice; present it neutrally.
2. **Their own user account: always prompt the user to create a user with their preferred credentials.**
   - Ask for the username they want and put it in `.env` as `TSV_USER`.
   - Never invent, default or reuse a username or password. Never put a password in chat, git, commit messages or logs.
   - Have the user type the password into a prompt:
     - `build/20-build-image.sh` asks for it when run in a terminal.
     - In Claude Code the user can run it themselves with `! build/20-build-image.sh`.
     - Or the user writes it to `secrets/tsv_password` (`chmod 600`) and sets `TSV_PASSWORD_FILE`.
   - For extra people, use `device/add-user.sh`. Each person picks their own name and password.
   - If an image was built without this step, stop and do it before flashing.
3. **How they want to manage the Home Assistant connection.** Offer both:
   - **`.env`:** `HA_URL`, `HA_DASHBOARD_PATH` (Chromium) and `HA_TOKEN` (native, a long-lived token from HA profile → Security).
     `kiosk/setup.sh` pushes them to the device.
   - **Manual on the device:** edit `/etc/tsv-panel/config.toml` and `/etc/tsv-panel/ha_token` (native), or `/etc/tsv-kiosk/kiosk.env` (Chromium), then `sudo systemctl restart tsv-kiosk`.
     The README table "Managing the Home Assistant connection by hand" has the exact formats.
   - A token is a secret. Never echo it, commit it or paste it into a command line others can see. Prefer that the user types it at the prompt or puts it in `.env`.

Also ask for: Wi-Fi SSID/PSK (`.env`), timezone, and later the TSV's IP (`TSV_HOST`). Suggest a DHCP reservation.

## The camera differs between units: find out which one this unit has

Every TSV has one camera, but Lenovo fitted one of three sensors. Only the **Samsung S5KC505A** works out of the box (`camera/install.sh`). If the user wants the camera:

1. **Identify the sensor before installing anything.** Use the probe method in `camera/BRINGUP-NOTES.md`, or install the S5KC505A build and check `dmesg`: the driver refuses any other chip ID.

   | Sensor | I2C address on CCI master 0 | Chip ID |
   |---|---|---|
   | S5KC505A | 0x37 | 0x5034 @ 0x0000 |
   | S5K4E8 | 0x2d | 0x04e8 @ 0x0000 |
   | OV5693 | 0x36 | 0x5690 @ 0x300a |

2. **S5K4E8:** port `camera/driver/s5kc505a.c`. Its vendor library has the same table layout and modes. Generate the tables with `camera/vendor/tools/sensor-lib-dump.py`.
3. **OV5693:** use the mainline `ov5693` driver.
   - It is off in the device kernel config. Enable it with build/30's `CAMERA_EXTRA_CONFIG` and `CAMERA_EXTRA_MODULES`.
   - Write a DTS patch with 2 data lanes (mainline rejects 4) and pass it with `CAMERA_EXTRA_PATCHES`.
4. Every variant needs the CAMSS CSIPHY-timer fix (`camera/upstream/kernel/0001`) and the shared slot wiring (GPIOs, regulators, MCLK) documented in `camera/vendor/README.md`.

`camera/vendor/` holds the stock vendor sensor libraries, `camera_config.xml`, the chromatix tuning and the stock Android device tree for all three. It is reference material for porting: nothing in the build or at runtime loads it.

Tell the user that a new port is untested hardware work. Verify each step on the device in order: chip ID read, then stream, then image.

## Stock firmware: what's included and what isn't

- **Flashing needs only** the firehose loader and `rawprogram0.xml` (fetched by `flash/fetch-firehose.sh`, sources in `flash/firehose/SOURCE.md`), the signed lk2nd and the built image. The 1.3 GB stock package is not needed.
- **Rollback depends on the user's own full backup.** Without it, the only route back to Android is the stock package via QFIL/edl, which is outside this repo. Insist on the backup.
- **Wi-Fi and the ADSP load their firmware from the device's stock `modem` and `vendor` partitions** (`msm-firmware-loader`).
  - Never write those partitions.
  - On a unit where they were wiped, restore them first.

## Proprietary files: obtain, never commit

- The firehose loader, `rawprogram0.xml` and everything under `camera/vendor/{lib,etc}` and `camera/vendor/dt/*.dt[bs]` are Qualcomm/Lenovo proprietary. They are git-ignored.
  - Get them with `flash/fetch-firehose.sh`, `camera/vendor/fetch.sh` and `camera/vendor/dt/extract-stock-dtb.sh`. Each one verifies sha256.
- **Never** `git add -f` them, copy them into tracked paths, attach them to issues or releases, or paste their contents.
- If a file is missing, run its fetch script. Don't look for other mirrors without asking the user.

## Safety rules (the device can be bricked or lose unrecoverable data)

- **Never flash before a verified full backup.**
  - `flash/flash.sh backup` must have produced `backup/emmc-full.bin` with a matching `SHA256SUMS`.
  - It holds device-unique calibration (persist, modemst1/2, fsg) that cannot be recreated.
  - Tell the user to keep a second copy.
- **Never unlock the bootloader.** On this device an unlocked bootloader does not boot.
  - Boot only the AVB1-signed lk2nd from `flash/`, or a rebuild via `build/10-build-lk2nd.sh`.
  - The upstream lk2nd release image is unsigned and has a QCDT, so it **will not boot**.
- Only ever write the `boot` and `userdata` partitions. The exception is `flash.sh restore`, which rewrites everything from the backup.
- Confirm with the user before every EDL write (`flash`, `restore`), and say what will be overwritten.
- Never compile on the TSV. All builds happen on the build host or VM. The device has 8 GB eMMC with wear concerns.
- Don't change the user's Home Assistant configuration unless asked. For Chromium login via `trusted_networks`, give them the snippet and let them apply it.

## How things work (facts you would otherwise rediscover the hard way)

- **Build host:**
  - macOS uses the Lima VM `$LIMA_VM`, with the repo mounted at the same path. Linux builds natively.
  - `scripts/lib.sh::in_build_env` runs commands there, with `scripts/build-env.sh` loaded.
  - Always call pmbootstrap through `pmb`. It uses the repo's own config (`.build/pmbootstrap.cfg`), work dir (`PMB_WORK`) and pmaports clone. Calling `pmbootstrap` directly would use or modify the user's personal pmbootstrap setup.
  - The work dir is on the VM's own disk on macOS: pmbootstrap chroots can't live on the virtiofs mount.
  - **No hard-coded paths:** every script resolves paths from the repo root (`$REPO`). Keep it that way. Paths under `~` inside `pmb chroot` refer to the chroot's `/home/pmos`.
- **Build chain:**
  - `build/00` → `10` (optional) → `20` → `kiosk/native/scripts/build.sh` → `30`/`31` (camera, optional).
  - Each step's pinned inputs are listed in README's "The build chain".
  - A pmbootstrap build prunes the native chroot, so every script re-adds its own build dependencies. Keep that pattern.
- **Device in pmbootstrap:** the generic `qcom-msm8953`, not a TSV-specific package. lk2nd picks the TSV DTB (`apq8053-lenovo-cd-18781y.dtb`) from `/boot` via extlinux.
- **Boot:**
  - EDL is Vol Up + Vol Down at power-on, with a black screen.
  - The Nura image lives in `userdata` as `/dev/loop0`; p1 is /boot (ext2) and p2 is / (ext4).
  - Kernel and DTB changes are plain file edits in `/boot` over SSH; no EDL is needed.
- **First boot:**
  - The root fs must be grown (`device/first-boot.sh`).
  - `qbootctl.service` fails on every boot (no A/B slots), so it is masked.
- **Kiosk:**
  - `tsv-kiosk.service` runs `cage -d` on tty1 as the `kiosk` user, with `StartLimitIntervalSec=0` and `Restart=always`.
  - getty and autovt on tty1 are masked, and logind has `NAutoVTs=0`, so **a login prompt must never appear on the display**. Keep it that way in any change.
- **Native panel:**
  - Rust 2024 + Slint (winit-wayland, femtovg on GLES/freedreno) + tokio-tungstenite/rustls.
  - HA WebSocket message ids must strictly increase. The panel sends get_states=1, subscribe=2, then the area, device and entity registries (3–5).
  - Only `light.*` and the configured plugs can be switched.
  - Dev control socket: `kiosk/native/scripts/ctl.sh page 1`.
- **Sudo over SSH:** helpers use `TSV_PASSWORD_FILE` when it is set (unattended). Otherwise they open a TTY and sudo prompts. The device uses `sudo-rs`.
- **Alpine specifics:**
  - BusyBox userland, with no bash by default. Use `/bin/ash` for users.
  - BusyBox `nc` has no UNIX sockets; use python3 (installed in native mode).
  - `pkill -f <pattern>` run inside `sh -c '…<pattern>…'` kills its own shell.
- **Camera:**
  - The prebuilt modules and DTB match kernel `7.0.9-msm8953` only. `camera/install.sh` refuses other kernels; rebuild per `camera/README.md`.
  - A kernel or libcamera upgrade silently removes camera support.
- **Slimming:** `device/slim.sh` makes the journal RAM-only. For persistent logs, use `extras/remote-control` (rsyslog forwarding).

## Working style

- Use the scripts. If you must deviate, update the script and docs too, so the repo stays the single source of truth.
- After each step, verify:
  - `ssh` works.
  - `systemctl --failed` is empty.
  - `systemctl is-active tsv-kiosk` returns active.
  - A screenshot (`kiosk/native/scripts/shot.sh`) shows the expected screen.
- Report outcomes honestly, especially anything marked "untested", such as Chromium mode on this hardware.
