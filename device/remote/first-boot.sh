#!/bin/sh
# Runs as root ON the TSV. Idempotent.
set -e
# pmbootstrap sizes the root fs to its contents; grow it to fill the userdata subpartition.
resize2fs /dev/loop0p2 2>&1 | tail -1 || true
# qbootctl marks A/B boot slots; this device has none, so it fails (and warns) on every boot.
systemctl mask qbootctl.service >/dev/null 2>&1 || true
systemctl disable --now qbootctl.service >/dev/null 2>&1 || true
echo "--- $(grep PRETTY /etc/os-release) / kernel $(uname -r)"
df -h / /boot | sed 1d
nmcli -t -f DEVICE,STATE,CONNECTION dev | grep wlan0 || true
systemctl --failed --no-legend || true
