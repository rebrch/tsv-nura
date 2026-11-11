# Vendor camera files: reference material for any of the three TSV camera variants

Lenovo's Android image supports **three** camera sensors on the ThinkSmart View. Each unit has exactly **one** of them,
fitted in camera slot 0. Linux needs a driver for whichever one your unit has.

These files come from the TSV's own stock vendor partition and boot image. They are **not used at build time or at
runtime**: no script loads them. They exist so a person or an AI agent can bring up the camera on a unit that doesn't
have the S5KC505A.

> **Not in git.** These are proprietary Qualcomm/Lenovo files, git-ignored and never pushed. Only this README, the
> tools, the fetch scripts and `SHA256SUMS` are versioned. Every TSV carries the files itself, so get them from yours:
> ```bash
> camera/vendor/fetch.sh                                   # lib/ + etc/ from your TSV's stock vendor partition (over SSH)
> camera/vendor/dt/extract-stock-dtb.sh path/to/boot.img   # dt/ from a stock boot image (see below)
> ```
> Both check the results against `SHA256SUMS`, the hashes of the reference unit's files.

## The three sensors at a glance

Decoded with `tools/sensor-lib-dump.py` and `etc/camera_config.xml`.

| | **Samsung S5KC505A** | **Samsung S5K4E8** | **OmniVision OV5693** |
|---|---|---|---|
| Status on Linux | **Working** (reference unit): `camera/driver`, `camera/upstream` | No driver yet | Mainline driver exists (`drivers/media/i2c/ov5693.c`, binding `ovti,ov5693`). Untested on a TSV |
| I2C (CCI master 0), 7-bit address | `0x37` | `0x2d` | `0x36` |
| Chip ID | `0x5034` @ reg `0x0000` | `0x04e8` @ reg `0x0000` | `0x5690` @ reg `0x300a` |
| Register map | SMIA-style | SMIA-style | OmniVision |
| MIPI lanes (vendor `LaneMask`) | 2 (`0x7`) | 2 (`0x7`) | 4 (`0x1F`) |
| Modes in the vendor library | 2608×1960, 1304×980, 1936×1096, 1296×736, 640×490 | **Same five, same table sizes** | 2592×1944, 1280×720 |
| Vendor `Position` | FRONT | FRONT | BACK. It's the same physical slot; the label only affects Android's mirroring |
| EEPROM library in config | `qtech_s5kc505a` (no library shipped) | `qtech_s5k4e8` (no library shipped) | `qtech_ov5693` (`lib/libmmcamera_qtech_ov5693_eeprom.so`) |
| Lens (vendor `LensInfo`) | f = 4.04 mm, F2.2, 64.8°×51.2° | f = 4.04 mm, F2.2, 64.8°×51.2° | f = 4.73 mm, F2.2, 64.1°×51.6° |

### The camera slot, the same for every variant

The slot comes from the stock DTB `dt/apq8053-lite-dragonboard-v2-tsv-stock.dts`, node `qcom,camera@0`.

| Item | Value |
|---|---|
| CSIPHY / CSID | 0 / 0 |
| CCI | master 0 |
| Mount angle | 270°: rotate the image 90° counter-clockwise for upright |
| Master clock | MCLK0 = GPIO26, 24 MHz |
| Reset | GPIO40 |
| Standby (power-down) | GPIO39 |
| Rail enables | Two external LDOs switched by GPIO118 (`CAM_VDIG`) and GPIO119 (`CAM_VANA`) |
| `cam_vio` | L6, 1.8 V |
| `cam_vdig` | L2, raised to **1.2 V** |
| `cam_vana` | L17, 2.85 V |

`camera/dts/tsv-camera.dts` and `camera/upstream/kernel/0004-*.patch` describe exactly this for the S5KC505A. For another
sensor, change only the sensor node: compatible, `reg`, lane count, link frequency.

## Porting to your sensor

### 1. Identify your sensor

Use either method:
- Install the reference camera DTB and look at the probe messages in `dmesg`. The S5KC505A driver refuses any chip ID except `0x5034`.
- Probe the bus directly with the probe-only DT (`camera/dts/tsv-camprobe.dts`) and `i2ctransfer`. `camera/BRINGUP-NOTES.md` ("Probe method") has the exact commands. Read the ID register at each address in the table above.

### 2a. S5K4E8

This is the most likely easy port. Its library has the same table layout, the same five modes and the same lane rates as the S5KC505A; the two look like sibling parts.

1. Copy `camera/driver/s5kc505a.c` to `s5k4e8.c`. Change the chip ID to `0x04e8`, the DT compatible, and the I2C address in the DTS to `0x2d`.
2. Regenerate the register tables:
   ```bash
   python3 camera/vendor/tools/sensor-lib-dump.py camera/vendor/lib/libmmcamera_s5k4e8.so        # list tables
   python3 camera/vendor/tools/sensor-lib-dump.py camera/vendor/lib/libmmcamera_s5k4e8.so --header \
     s5k4e8_global=0x6e20 s5k4e8_2608x1960=0x3eee4 s5k4e8_1304x980=0x42ef4 s5k4e8_1936x1096=0x46f04 \
     s5k4e8_1296x736=0x4af14 s5k4e8_640x490=0x4ef24 > camera/driver/s5k4e8_regs.h
   ```
   Mode tables 2 to 5 start with a placeholder entry, `0x0001 = 0x00`, which the S5KC505A tables skip. That's why the `--header` offsets are 8 bytes past the offsets the scan lists.
3. Add a libcamera CameraSensorHelper and sensor properties entry, modelled on `camera/upstream/libcamera/*.patch`. Check the analogue gain format in the vendor library or by experiment.
4. Build with `CAMERA_EXTRA_PATCHES="your-driver.patch your-dts.patch" CAMERA_EXTRA_MODULES=drivers/media/i2c/s5k4e8.ko build/30-build-camera-kernel.sh`. Your driver patch adds the file plus Kconfig/Makefile entries. Pass `CAMERA_EXTRA_CONFIG=CONFIG_VIDEO_S5K4E8=m` too, then run `build/31-build-libcamera.sh` with your libcamera patch added to `camera/libcamera-pmaports/`.

### 2b. OV5693

Mainline Linux already has a driver (`CONFIG_VIDEO_OV5693`), so this needs DT work rather than a new driver.

1. In the DTS, replace the S5KC505A node with an `ovti,ov5693` node at `0x36`. Use the same clocks, GPIOs and supplies, and the binding's supply names. Set the CAMSS endpoint's lanes.
2. **Use 2 data lanes.** The mainline driver rejects anything other than 2, although the vendor wiring has 4. That works as long as the first two lanes are used. Running at 4 lanes would mean extending the driver; the vendor tables (`--dump 0x3eee4`) show the 4-lane PLL and timing settings.
3. The device kernel config ships with `CONFIG_VIDEO_OV5693` **off**. Build the module with the extra-sensor hooks of `build/30-build-camera-kernel.sh`; this exact command was verified to produce a loadable-vermagic, DT-matchable `ov5693.ko`:
   ```bash
   CAMERA_EXTRA_CONFIG=CONFIG_VIDEO_OV5693=m CAMERA_EXTRA_MODULES=drivers/media/i2c/ov5693.ko \
   CAMERA_EXTRA_PATCHES=path/to/your-dts.patch  build/30-build-camera-kernel.sh
   ```
   Your DTS patch applies on top of `upstream/kernel/0004`. `camera/install.sh out/camera` installs every `.ko` it finds.
4. The CSIPHY-timer CAMSS fix (`upstream/kernel/0001`) is needed for **every** sensor on this SoC.

### 3. Image tuning

`etc/<sensor>_chromatix.xml` lists the Qualcomm ISP tuning libraries (`lib/libchromatix_<sensor>_*.so`). They target Qualcomm's hardware ISP and proprietary 3A, so libcamera can't use them directly.

Linux uses libcamera's software ISP with a small YAML tuning file (`camera/libcamera-pmaports/s5kc505a.yaml`). The chromatix data is the place to mine colour matrices or black levels if better colour is needed.

## Files

| Path | What |
|---|---|
| `lib/libmmcamera_{s5kc505a,s5k4e8,ov5693}.so` | Sensor drivers (power sequences, identity, register tables, exposure/gain math) |
| `lib/libmmcamera_qtech_ov5693_eeprom.so`, `lib/libmmcamera_eeprom_util.so` | OTP/EEPROM calibration readers |
| `lib/libchromatix_{s5kc505a,s5k4e8,ov5693}_*.so` | ISP tuning per mode |
| `etc/camera_config.xml` | Which sensors the image supports, lanes, lens data |
| `etc/<sensor>_chromatix.xml` | Tuning library lists |
| `dt/apq8053-lite-dragonboard-v2-tsv-stock.{dtb,dts}` | The TSV's stock Android device tree. It is board-id `0x1010520` ("APQ8053 Lite DragonBoard V2.0") out of the 46 DTBs in the stock `boot.img`. Camera nodes: `qcom,camera@0..2`, `qcom,eeprom@*`, `qcom,actuator@*`, `qcom,cci`, `qcom,csiphy` |
| `tools/sensor-lib-dump.py` | Reads the identity block and register tables. It reproduces `camera/driver/s5kc505a_regs.h` byte for byte |
| `SHA256SUMS` | Checksums of all of the above |

## Provenance

| Files | Source |
|---|---|
| `lib/`, `etc/` | Copied from the reference TSV's stock vendor partition, mounted read-only by Nura at `/run/msm-firmware-loader/mnt/vendor`. Fingerprint `Lenovo/CD-18781Y/CD-18781Y:8.1.0/OPM1.171019.026/penghu06021417:user/release-keys` |
| `dt/` | Extracted from `image/boot.img` of the stock firmware package `CD-18781Y.200628.084` (see `flash/firehose/SOURCE.md` for the download). The DTBs are found by their `d00dfeed` magic, then decompiled with `dtc` |

### Getting them yourself

| Files | How | Where they come from |
|---|---|---|
| `lib/`, `etc/` | `camera/vendor/fetch.sh` | Your TSV running Nura: `/run/msm-firmware-loader/mnt/vendor/lib/libmmcamera_*`, `.../lib/libchromatix_*`, `.../etc/camera/`. Nura mounts the stock vendor partition read-only, and flashing never touches it |
| `dt/` | `camera/vendor/dt/extract-stock-dtb.sh boot.img` | A stock boot image. Either `image/boot.img` from the stock firmware package `CD-18781Y.200628.084.zip` (download link in `flash/firehose/SOURCE.md`), or your own unit's `boot` partition read with `edl r boot boot.img` **before** flashing (afterwards it holds lk2nd), or carved out of `backup/emmc-full.bin` |

All three fetch paths were tested and reproduce the reference files byte for byte. A unit with a different vendor build
may give different hashes. That's fine, but the table offsets quoted above may then differ, so re-run the dump tool.
