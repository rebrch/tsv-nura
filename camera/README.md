# Front camera (Samsung S5KC505A) - optional

The TSV's single front camera works under mainline Linux with three additions. None of them are upstream yet;
patches are prepared in `upstream/`.

1. **Sensor driver:** `driver/s5kc505a.c`, a V4L2/CCI driver.
   - Its register tables (`s5kc505a_regs.h`) were extracted from the vendor `libmmcamera_s5kc505a.so` (`vendor/lib/`, reference only).
   - Sensor details: 2-lane CSI-2, RAW10, Bayer GRBG, black level 64. It is mounted at 270°, so rotate 90° CCW.
2. **CAMSS fix:** `driver/camss-8953-phytimer-200mhz.patch`.
   - On MSM8953 the CSIPHY timer clock at 100 MHz (GPLL0_DIV2) never turns on ("gcc_camss_csi0phytimer_clk status stuck at 'off'").
   - Running it at 200 MHz fixes streaming.
3. **Device tree:** `dts/tsv-camera.dts`.
   - It enables CCI and CAMSS csiphy0 and adds the sensor at 0x37 on CCI0, with GPIO-switched vana/vdig rails (GPIO119/118) and MCLK0.
   - `upstream/kernel/0004-*.patch` is the clean version; `prebuilt/apq8053-lenovo-cd-18781y.dtb` is built from it.

Plus **libcamera**: a CameraSensorHelper and sensor properties for the S5KC505A (gain = code/32), and a tuning file.
These are packaged as pmaports `temp/libcamera` pkgrel 1 (`libcamera-pmaports/`). Prebuilt APKs are in `prebuilt/apks/`.

**Not every TSV has this sensor.** Lenovo's image supports three: Samsung S5KC505A (this driver), Samsung S5K4E8 and OmniVision OV5693, one per unit.
- **Check yours:** after `camera/install.sh` and a reboot, run `dmesg | grep -i s5kc505a`. The driver verifies chip ID 0x5034 and refuses anything else.
- **Port to the others:** [`vendor/README.md`](vendor/README.md) has a step-by-step port for each. It covers the identity of all three sensors (I2C addresses, chip IDs, lanes, modes), the shared camera slot wiring, the vendor sensor libraries, a dump tool, the stock device tree and the build hooks.

The vendor library `libmmcamera_s5kc505a.so` (in `vendor/lib/`) is **not needed** to build or run anything. It was the source of the register tables in `driver/s5kc505a_regs.h`, which `vendor/tools/sensor-lib-dump.py` reproduces byte for byte.

## Install (prebuilt, kernel 7.0.9-msm8953 only)

```bash
camera/install.sh      # modules -> /lib/modules/<kver>/updates, DTB -> /boot (stock kept as .dtb.orig), libcamera APKs
# reboot the TSV, then on it:
timeout -s INT 8 gst-launch-1.0 -e libcamerasrc ! video/x-raw,width=1024,height=768 ! videoconvert ! jpegenc ! multifilesink max-files=1 location=/tmp/cam-%05d.jpg
```

- `tools/camera-mjpeg-stream.sh` streams MJPEG to stdout (1024×768, rotated upright). `extras/remote-control` uses it.
- Run camera apps as a user in the `video` group. libcamera then allocates from `/dev/udmabuf`; the root-only reserved CMA heap is too small.
- Remove everything with `camera/uninstall.sh`.

## Rebuild from source

The prebuilt modules only load on the exact kernel they were built for, `7.0.9-msm8953`.

```bash
build/30-build-camera-kernel.sh   # -> out/camera/{qcom-camss.ko,s5kc505a.ko,apq8053-lenovo-cd-18781y.dtb}
build/31-build-libcamera.sh       # -> out/camera/apks/*.apk
camera/install.sh out/camera
```

**What `build/30-build-camera-kernel.sh` does:**
1. It reads the device kernel's version, source tarball and sha512 from pmaports' `linux-postmarketos-qcom-msm8953` APKBUILD.
2. It downloads the msm8953-mainline tarball and verifies it.
3. It applies `upstream/kernel/0001-0004`: the CAMSS CSIPHY resources, the binding, the driver and the DTS.
4. It uses pmaports' kernel config plus `CONFIG_VIDEO_S5KC505A=m`.
5. In pmbootstrap's native Alpine chroot, it builds only the two modules and the TSV DTB with `make LLVM=1 LOCALVERSION=`. Without `LOCALVERSION=`, the vermagic gets a `+` and the modules won't load.
6. It strips debug info.

The output is reproducible: the same hashes on every run. The DTB is byte-identical to the one on the reference unit.

**What `build/31-build-libcamera.sh` does:** it applies `libcamera-pmaports/` to pmaports' `temp/libcamera`, builds it with pmbootstrap, then restores pmaports.

If pmaports moves to a newer kernel, the script warns. The patches were made against 7.0.9-r0 and may need rebasing.

## Files

```
driver/      s5kc505a.c, s5kc505a_regs.h, Makefile (out-of-tree), camss-8953-phytimer-200mhz.patch
dts/         tsv-camera.dts (+ mkcam.py that generated it from the stock DTB), tsv-camprobe.dts (I2C probe-only DT)
prebuilt/    modules + DTB from build/30 (verified streaming on the reference unit), libcamera APKs installed on it (SHA256SUMS)
libcamera-pmaports/  APKBUILD diff, sensor-helper patch, tuning yaml
upstream/    git format-patch series for linux-media / linux-arm-msm and libcamera (unsent; see its README)
tools/       bring-up helpers (userspace I2C streaming test, raw capture, RAW10 render/develop)
vendor/      stock vendor camera libraries, configs and device tree for all three sensor variants + dump tool (reference)
BRINGUP-NOTES.md   the full engineering log (pins, regulators, register maps, what failed and why)
```
