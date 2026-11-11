#!/bin/bash
# Trim unused services/drivers and cut idle eMMC writes to ~0 (journal in RAM, noatime, ...).
# The journal is then lost on reboot - use extras/remote-control (rsyslog forwarding) if you want logs kept.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
S=/tmp/tsv-slim
tsv_ssh "rm -rf $S && mkdir -p $S"
tsv_scp "$REPO/device/rootfs" "$S/"
tsv_root "$REPO/device/remote/slim.sh" "$S"
tsv_ssh "rm -rf $S"
