#!/bin/bash
# OPTIONAL: enable the TSV's front camera (Samsung S5KC505A).
# Usage: camera/install.sh [artifact dir]   default camera/prebuilt (kernel 7.0.9-msm8953, Nura v26.06);
#        or out/camera after build/30-build-camera-kernel.sh + build/31-build-libcamera.sh for other kernels. A kernel upgrade replaces the DTB and
# makes the modules unloadable; a libcamera upgrade drops the sensor helper. Re-run (or rebuild) after upgrades.
# Rollback: camera/uninstall.sh
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
C="${1:-$REPO/camera/prebuilt}"; S=/tmp/tsv-camera
[ -f "$C/SHA256SUMS" ] && { (cd "$C" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "checksum mismatch in $C"; }
KO=$(find "$C" -name qcom-camss.ko | head -1); [ -n "$KO" ] || die "no qcom-camss.ko in $C"
KV=$(strings "$KO" | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -1)
tsv_ssh "rm -rf $S && mkdir -p $S/apks"
tsv_scp $(find "$C" -name '*.ko') "$C/apq8053-lenovo-cd-18781y.dtb" "$S/"
tsv_scp "$C"/apks/libcamera-[0-9]*.apk "$C"/apks/libcamera-ipa-*.apk "$C"/apks/libcamera-gstreamer-*.apk "$S/apks/"
tsv_root "$REPO/camera/remote-install.sh" "$S" "$KV"
