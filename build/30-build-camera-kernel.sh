#!/bin/bash
# OPTIONAL (camera): build the patched qcom-camss + s5kc505a kernel modules and the camera-enabled TSV DTB
# for the kernel the image ships. Output: $OUT_DIR/camera/ (install with: camera/install.sh "$OUT_DIR/camera").
#
# Chain: msm8953-mainline kernel source (the exact tarball + config pmaports builds the device kernel from)
#   + camera/upstream/kernel/0001-0004 patches -> built with LLVM inside pmbootstrap's native Alpine chroot
#   (same clang as the device kernel package) -> modules stripped of debug info.
#
# Other camera variants (see camera/vendor/README.md), via environment or .env:
#   CAMERA_EXTRA_PATCHES   extra patch files applied after camera/upstream/kernel/* (space separated, repo-relative ok)
#   CAMERA_EXTRA_CONFIG    extra Kconfig lines, e.g. "CONFIG_VIDEO_OV5693=m"
#   CAMERA_EXTRA_MODULES   extra .ko targets, e.g. "drivers/media/i2c/ov5693.ko"
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
mkdir -p "$OUT_DIR/camera"
# Pass the camera variables through to the build environment (the VM does not inherit this shell's env).
PASS=$(for v in CAMERA_EXTRA_PATCHES CAMERA_EXTRA_CONFIG CAMERA_EXTRA_MODULES; do printf '%s=%q; ' "$v" "${!v:-}"; done)
in_build_env "$PASS"'
pmb_init
APORTS=$PMB_APORTS
KPKG=$(ls -d "$APORTS"/device/*/linux-postmarketos-qcom-msm8953)
pkgver=$(sed -n "s/^pkgver=//p" "$KPKG/APKBUILD"); pkgrel=$(sed -n "s/^pkgrel=//p" "$KPKG/APKBUILD")
TAG="$pkgver-r$pkgrel"; echo "kernel: msm8953-mainline v$TAG (from pmaports $(git -C "$APORTS" rev-parse --short HEAD))"
[ "$TAG" = 7.0.9-r0 ] || echo "NOTE: the patches were made against 7.0.9-r0; they may need rebasing for v$TAG."
TARBALL=linux-postmarketos-qcom-msm8953-v$TAG.tar.gz
mkdir -p "$BUILD_DIR/dl"
[ -f "$BUILD_DIR/dl/$TARBALL" ] || curl -fsSL -o "$BUILD_DIR/dl/$TARBALL" "https://github.com/msm8953-mainline/linux/archive/v$TAG.tar.gz"
# Verify against the sha512 pmaports pins for the device kernel.
want=$(grep -E "  $TARBALL\$" "$KPKG/APKBUILD" | cut -d" " -f1)
echo "$want  $BUILD_DIR/dl/$TARBALL" | sha512sum -c --quiet
# Toolchain inside the chroot (idempotent)
pmb -q chroot -- apk add -q $(sed -n "/^makedepends=\"/,/\"/p" "$KPKG/APKBUILD" | tr -d \"= | sed "s/makedepends//" | grep -v postmarketos-installkernel) \
  make gcc musl-dev binutils elfutils-dev linux-headers bc dtc diffutils xz tar patch
H=$(pmb_chroot_home)
sudo rm -rf "$H/tsv-kernel"; sudo mkdir -p "$H/tsv-kernel"
sudo tar -xzf "$BUILD_DIR/dl/$TARBALL" -C "$H/tsv-kernel"
sudo mkdir -p "$H/tsv-kernel/patches"
sudo cp "$REPO"/camera/upstream/kernel/000[1-4]-*.patch "$H/tsv-kernel/patches/"
n=5; for p in ${CAMERA_EXTRA_PATCHES:-}; do case "$p" in /*) ;; *) p="$REPO/$p";; esac; sudo cp "$p" "$H/tsv-kernel/patches/$(printf %04d $n)-$(basename "$p")"; n=$((n+1)); done
printf "%s\n" ${CAMERA_EXTRA_CONFIG:-} | sudo tee "$H/tsv-kernel/extra.config" >/dev/null
sudo cp "$KPKG/config-postmarketos-qcom-msm8953.aarch64" "$H/tsv-kernel/config"
sudo chown -R 12345:12345 "$H/tsv-kernel"
pmb -q chroot --user -- sh -ec "
cd ~/tsv-kernel/linux-$TAG
for p in ../patches/*.patch; do patch -p1 -s < \$p; done
cp ../config .config && echo CONFIG_VIDEO_S5KC505A=m >> .config && cat ../extra.config >> .config
M=\"make -s LLVM=1 LOCALVERSION= -j\$(nproc)\"   # LOCALVERSION= : otherwise vermagic gets a + and modules will not load
\$M olddefconfig
\$M modules_prepare
# Only these two modules are built (no vmlinux), so modpost cannot see core-kernel exports: its
# \"undefined!\" warnings are expected. depmod on the device resolves the dependencies.
\$M drivers/media/platform/qcom/camss/qcom-camss.ko drivers/media/i2c/s5kc505a.ko $CAMERA_EXTRA_MODULES KBUILD_MODPOST_WARN=1 > ../mods.log 2>&1 || { cat ../mods.log; exit 1; }
grep -v -e \"modpost: \" -e \"vmlinux.o is missing\" -e \"Modules may not have\" -e \"unresolved symbol errors\" -e \"KBUILD_MODPOST_WARN=1 to\" -e \"if you want to proceed\" ../mods.log || true
\$M qcom/apq8053-lenovo-cd-18781y.dtb
mkdir -p ~/tsv-kernel/out
for k in drivers/media/platform/qcom/camss/qcom-camss.ko drivers/media/i2c/s5kc505a.ko $CAMERA_EXTRA_MODULES; do llvm-strip --strip-debug -o ~/tsv-kernel/out/\$(basename \$k) \$k; done
cp arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb ~/tsv-kernel/out/
"
cp "$H"/tsv-kernel/out/* "$OUT_DIR/camera/"
cd "$OUT_DIR/camera"; strings qcom-camss.ko | grep ^vermagic || true; sha256sum *.ko *.dtb
'
