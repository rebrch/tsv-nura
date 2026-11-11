#!/bin/bash
# Remove the camera support: stock DTB back, patched modules removed, stock libcamera restored.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
T=$(mktemp); cat > "$T" <<'R'
set -e
KV=$(uname -r); DTB=/boot/apq8053-lenovo-cd-18781y.dtb
[ -f $DTB.orig ] && mv $DTB.orig $DTB
rm -f /lib/modules/$KV/updates/qcom-camss.ko /lib/modules/$KV/updates/s5kc505a.ko; depmod -a
apk del -q libcamera-gstreamer 2>/dev/null || true
apk fix -q libcamera 2>/dev/null || true
echo "Camera support removed; reboot to apply."
R
tsv_root "$T"; rm -f "$T"
