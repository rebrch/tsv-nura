#!/bin/bash
# OPTIONAL (camera): build libcamera with the S5KC505A sensor helper + tuning file, as Alpine packages.
# Applies camera/libcamera-pmaports/ to pmaports' temp/libcamera (pkgrel 1), builds with pmbootstrap,
# then restores pmaports. Output: $OUT_DIR/camera/apks/ (install with: camera/install.sh "$OUT_DIR/camera").
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
mkdir -p "$OUT_DIR/camera/apks"
in_build_env '
pmb_init
APORTS=$PMB_APORTS; L="$APORTS/temp/libcamera"
git -C "$APORTS" checkout -q -- temp/libcamera
git -C "$APORTS" apply "$REPO/camera/libcamera-pmaports/APKBUILD.diff"
cp "$REPO/camera/libcamera-pmaports/0004-ipa-libipa-add-s5kc505a.patch" "$REPO/camera/libcamera-pmaports/s5kc505a.yaml" "$L/"
trap "git -C \"$APORTS\" checkout -q -- temp/libcamera; git -C \"$APORTS\" clean -qfd temp/libcamera" EXIT
echo "Building libcamera (10-20 min)..."
pmb -q build --force --arch aarch64 libcamera > "$OUT_DIR/camera/libcamera-build.log" 2>&1 || { tail -40 "$OUT_DIR/camera/libcamera-build.log"; exit 1; }
for p in libcamera libcamera-ipa libcamera-gstreamer libcamera-tools; do
  cp "$(pmb config work)/packages/$PMB_CHANNEL/aarch64/$p"-[0-9]*-r1.apk "$OUT_DIR/camera/apks/"
done
ls -la "$OUT_DIR/camera/apks"
'
