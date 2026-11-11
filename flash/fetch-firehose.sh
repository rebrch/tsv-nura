#!/bin/bash
# Obtain the EDL firehose loader + rawprogram0.xml (proprietary Qualcomm/Lenovo files; not in git).
# Downloads the archive documented in flash/firehose/SOURCE.md, verifies every hash, extracts into flash/firehose/.
# Usage: flash/fetch-firehose.sh [path/to/CD-18781Y-firehose-rawprogram.7z]   (use a local copy instead of downloading)
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
URL=https://s3.wasabisys.com/filestash-buk/lenovo-thinksmart-view/CD-18781Y-firehose-rawprogram.7z
ARCHIVE_SHA256=caed20e5451ce7682085789ace1cdc19c0fbf487027ec01c54a03090c748f315
D="$REPO/flash/firehose"
if (cd "$REPO/flash" && shasum -a 256 -c --status SHA256SUMS 2>/dev/null); then echo "firehose files already present and verified"; exit 0; fi
A="${1:-$BUILD_DIR/dl/CD-18781Y-firehose-rawprogram.7z}"
mkdir -p "$(dirname "$A")"
[ -f "$A" ] || { echo "Downloading $URL"; curl -fsSL -o "$A" "$URL"; }
echo "$ARCHIVE_SHA256  $A" | shasum -a 256 -c --quiet || die "archive checksum mismatch: $A (see flash/firehose/SOURCE.md)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if command -v bsdtar >/dev/null; then bsdtar -xf "$A" -C "$T"
elif command -v 7z >/dev/null; then 7z x -bd -y -o"$T" "$A" >/dev/null
else die "need bsdtar (libarchive-tools) or 7z (p7zip) to extract the .7z"; fi
install -m 0644 "$T/prog_emmc_firehose_8953_ddr.mbn" "$T/rawprogram0.xml" "$D/"
(cd "$REPO/flash" && shasum -a 256 -c SHA256SUMS)
