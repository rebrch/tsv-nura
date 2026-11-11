#!/bin/sh
# Runs as root ON the TSV: remote-install.sh <stage dir>. Installs the front camera support.
set -e
S="$1"; KV=$(uname -r); WANT="$2"
if [ "$KV" != "$WANT" ]; then
  echo "Kernel is $KV; these modules are for $WANT. Build matching ones: build/30-build-camera-kernel.sh - aborting."; exit 1
fi
# 1. Kernel modules: patched qcom-camss (CSIPHY timer fix) + the S5KC505A sensor driver; 'updates/' wins over the stock module.
install -D -m 0644 "$S/qcom-camss.ko" /lib/modules/$KV/updates/qcom-camss.ko
install -D -m 0644 "$S/s5kc505a.ko"  /lib/modules/$KV/updates/s5kc505a.ko
depmod -a
# 2. Device tree with the camera enabled (keeps the stock one as .orig, used for rollback).
DTB=/boot/apq8053-lenovo-cd-18781y.dtb
[ -f $DTB.orig ] || cp $DTB $DTB.orig
install -m 0644 "$S/apq8053-lenovo-cd-18781y.dtb" $DTB
# 3. libcamera with the S5KC505A sensor helper + tuning file (locally built, hence --allow-untrusted).
apk add -q --allow-untrusted "$S"/apks/*.apk
apk add -q gstreamer-tools gst-plugins-good gst-plugins-base
# Camera users must be in `video` (libcamera then allocates from /dev/udmabuf; the root-only reserved CMA heap is too small).
rm -rf "$S"
echo "Installed. Reboot, then test (as a user in group video):"
echo "  timeout -s INT 8 gst-launch-1.0 -e libcamerasrc ! video/x-raw,width=1024,height=768 ! videoconvert ! jpegenc ! multifilesink max-files=1 location=/tmp/cam-%05d.jpg"
