#!/bin/bash
# Flash Nura (postmarketOS) onto the Lenovo ThinkSmart View CD-18781Y over Qualcomm EDL.
#
# EDL mode: unplug power, hold Vol Up + Vol Down, plug in power + USB-C to the build host.
# The screen stays black in EDL; `flash.sh detect` confirms the connection.
#
#   flash.sh setup-edl        clone bkerler/edl (pinned) + python venv into $EDL_DIR
#   flash.sh detect           talk to the device, print the partition table
#   flash.sh backup           bit-exact dump of the WHOLE eMMC (~7.3 GB) -> $BACKUP_DIR  (do this first!)
#   flash.sh flash [image]    write signed lk2nd to `boot`, the Nura image to `userdata`, reboot
#   flash.sh restore [file]   write the full dump back (original Android, byte for byte), reboot
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

HERE="$REPO/flash"
LOADER="$HERE/firehose/prog_emmc_firehose_8953_ddr.mbn"
LK2ND="$HERE/lk2nd-signed-23.1.img"
EDL_COMMIT=1cda1a6   # bkerler/edl revision used for the reference device
[ "${1:-}" = setup-edl ] || [ -f "$LOADER" ] || die "missing $LOADER (proprietary, not in git) - run flash/fetch-firehose.sh"
edl() { "$EDL_DIR/.venv/bin/python" "$EDL_DIR/edl.py" --loader="$LOADER" "$@"; }

case "${1:-}" in
  setup-edl)
    if [ "$(uname -s)" = Darwin ]; then
      command -v brew >/dev/null && { brew list libusb >/dev/null 2>&1 || brew install libusb; }
    fi
    [ -d "$EDL_DIR/.git" ] || git clone https://github.com/bkerler/edl "$EDL_DIR"
    git -C "$EDL_DIR" checkout -q "$EDL_COMMIT"
    git -C "$EDL_DIR" submodule update --init --recursive -q
    python3 -m venv "$EDL_DIR/.venv"
    "$EDL_DIR/.venv/bin/pip" -q install -r "$EDL_DIR/requirements.txt"
    echo "edl ready in $EDL_DIR (Linux: you may need its udev rules, see $EDL_DIR/README.md)"
    ;;
  detect)
    edl printgpt
    ;;
  backup)
    mkdir -p "$BACKUP_DIR"
    [ -e "$BACKUP_DIR/emmc-full.bin" ] && die "$BACKUP_DIR/emmc-full.bin exists - refusing to overwrite your backup"
    edl printgpt > "$BACKUP_DIR/partitions.txt"
    edl rf "$BACKUP_DIR/emmc-full.bin"
    (cd "$BACKUP_DIR" && shasum -a 256 emmc-full.bin > SHA256SUMS && cat SHA256SUMS)
    echo "Backup done. Keep $BACKUP_DIR somewhere safe: it is the only way back to the stock/Android system,"
    echo "and it contains device-unique calibration (persist, modemst*, fsg) that cannot be recreated."
    ;;
  flash)
    IMG="${2:-$OUT_DIR/nura-qcom-msm8953.img}"
    [ -f "$IMG" ] || die "no image at $IMG - run build/20-build-image.sh first"
    [ -f "$BACKUP_DIR/emmc-full.bin" ] || [ "${TSV_SKIP_BACKUP_CHECK:-}" = yes ] ||
      die "no full backup in $BACKUP_DIR - run '$0 backup' first (or set TSV_SKIP_BACKUP_CHECK=yes)"
    (cd "$HERE" && shasum -a 256 -c SHA256SUMS)
    edl w boot "$LK2ND"
    edl w userdata "$IMG"
    edl reset
    echo "Flashed. First boot takes ~1 min; the TSV then joins the Wi-Fi from .env."
    ;;
  restore)
    F="${2:-$BACKUP_DIR/emmc-full.bin}"
    [ "$F" = "$BACKUP_DIR/emmc-full.bin" ] && (cd "$BACKUP_DIR" && shasum -a 256 -c SHA256SUMS)
    edl wf "$F"
    edl reset
    ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
