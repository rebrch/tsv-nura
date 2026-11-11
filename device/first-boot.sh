#!/bin/bash
# After the first boot: grow the root fs, mask the failing qbootctl unit, print a health summary.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
tsv_root "$REPO/device/remote/first-boot.sh"
