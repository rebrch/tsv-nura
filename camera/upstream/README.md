# Upstream candidates: ThinkSmart View camera

Prepared locally on 2026-11-09. NOTHING HAS BEEN SENT ANYWHERE.

## Kernel series (`kernel/`, `git format-patch --cover-letter`)
| # | Patch | Target |
|---|---|---|
| 1 | media: qcom: camss: Use dedicated CSIPHY resources for MSM8953 | linux-media (+ msm8953-mainline) |
| 2 | media: dt-bindings: i2c: Add Samsung S5KC505A image sensor | linux-media + devicetree |
| 3 | media: i2c: Add Samsung S5KC505A image sensor driver | linux-media |
| 4 | arm64: dts: qcom: apq8053-lenovo-cd-18781y: Enable front camera | linux-arm-msm (Qualcomm DT) |

Base: msm8953-mainline tag v7.0.9-r0 (the kernel postmarketOS ships for this device). Source tree with
history: recreate it with build/30-build-camera-kernel.sh (it applies these patches to that exact tarball).

Checks done:
- `checkpatch.pl --strict`: clean for all four.
- `make W=1` (clang): no warnings for s5kc505a.c.
- `dt_binding_check` on samsung,s5kc505a.yaml: clean. `CHECK_DTBS` for the TSV dtb: no new warnings
  (existing ones come from msm8953.dtsi / camss schema / gpio-keys names in the base tree).
- Hardware: exactly these builds (modules + dtb, dtb byte-identical to the patch result) run on the TSV:
  probe OK, runtime PM suspends when idle, raw capture and libcamera/GStreamer streaming work.

## libcamera (`libcamera/`)
1. libcamera: camera_sensor_properties: Add Samsung S5KC505A
2. ipa: libipa: camera_sensor_helper: Add Samsung S5KC505A
Base: v0.7.1. Run libcamera's `utils/checkstyle.py` on a real checkout before sending.
(The pmOS package also ships a per-sensor tuning file `s5kc505a.yaml`; that would be a pmaports MR, not libcamera.)

## Before sending
1. Replace `Your Name <you@example.com>` (Signed-off-by, author, MAINTAINERS, binding maintainers) - the
   Signed-off-by certifies the Developer Certificate of Origin, so it must be you.
2. Patch 1 `Fixes:` tag: fill in the upstream commit that added MSM8953 CAMSS support.
3. Rebase onto current trees: linux-media `next` (patches 1-3) and the Qualcomm arm64 DT tree (patch 4). Upstream
   mainline may lack msm8953 bits that msm8953-mainline has; check the TSV dts exists upstream.
   Easiest first route: a PR to github.com/msm8953-mainline/linux (pmOS builds from it).
4. Reviewers will likely ask about:
   - register tables derived from the vendor firmware (no datasheet): say so (cover letter does);
   - L2 raised to 1.2 V (taken from the vendor DT; untested at the stock 0.975 V);
   - unit cell size 1.12 um in libcamera is a guess;
   - powerdown GPIO naming (Android calls the pin CAM_STANDBY0);
   - default 10 fps VBLANK policy (they may prefer the mode's native frame length).
5. `scripts/get_maintainer.pl` for recipients; send with `git send-email`.
