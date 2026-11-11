#!/bin/bash
# Obtain the stock vendor camera files (proprietary Qualcomm/Lenovo; not in git) from YOUR OWN TSV running Nura.
# They are reference material for porting camera drivers (see README.md); nothing at build time or runtime needs them.
# Source on the device: the stock vendor partition, mounted read-only by msm-firmware-loader at
#   /run/msm-firmware-loader/mnt/vendor/{lib/libmmcamera_*,lib/libchromatix_*,etc/camera/}
# Usage: camera/vendor/fetch.sh
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$REPO/camera/vendor"
T=$(mktemp); cat > "$T" <<'R'
set -e
cd /run/msm-firmware-loader/mnt/vendor
tar -cf /tmp/tsv-vendor-camera.tar lib/libmmcamera_ov5693.so lib/libmmcamera_s5k4e8.so lib/libmmcamera_s5kc505a.so \
  lib/libmmcamera_qtech_ov5693_eeprom.so lib/libmmcamera_eeprom_util.so \
  lib/libchromatix_ov5693_* lib/libchromatix_s5k4e8_* lib/libchromatix_s5kc505a_* etc/camera
chown "${SUDO_USER:-root}" /tmp/tsv-vendor-camera.tar
R
tsv_root "$T"; rm -f "$T"
mkdir -p "$V/lib" "$V/etc"
tsv_ssh "cat /tmp/tsv-vendor-camera.tar; rm -f /tmp/tsv-vendor-camera.tar" | tar -xf - -C "$V"
mv "$V"/etc/camera/* "$V/etc/" && rmdir "$V/etc/camera"
cd "$V"
if grep -E ' (lib|etc)/' SHA256SUMS | shasum -a 256 -c --quiet; then
  echo "Vendor camera files fetched; all match the reference unit (SHA256SUMS)."
else
  echo "NOTE: some files differ from the reference unit (different vendor build?). Usable, but offsets in README.md may differ."
fi
