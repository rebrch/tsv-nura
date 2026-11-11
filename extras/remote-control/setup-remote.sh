#!/bin/bash
# OPTIONAL: let one monitoring/control host (MONITOR_HOST in .env) watch and manage the TSV:
#  - Prometheus node_exporter on :9100 (firewalled to MONITOR_HOST)
#  - journal forwarded to MONITOR_HOST:514/udp (rsyslog) - pairs with device/slim.sh's RAM-only journal
#  - SSH user `mcremote` with a forced command: `ssh mcremote@tsv reboot|screen|camera|ping`
#    screen = live JPEG frames of the display, camera = MJPEG from the front camera (camera/install.sh first).
# Key: secrets/mcremote_ed25519 (generated here); copy the private key to the monitoring host.
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
need MONITOR_HOST
K="$REPO/secrets/mcremote_ed25519"
[ -f "$K" ] || ssh-keygen -q -t ed25519 -N "" -C "mcremote" -f "$K"
S=/tmp/tsv-remote-setup
tsv_ssh "rm -rf $S && mkdir -p $S"
tsv_scp "$REPO/extras/remote-control/rootfs" "$K.pub" "$S/"
tsv_ssh "mv $S/mcremote_ed25519.pub $S/mcremote.pub"
tsv_root "$REPO/extras/remote-control/remote-setup.sh" "$S" "$MONITOR_HOST"
echo "From $MONITOR_HOST: ssh -i mcremote_ed25519 mcremote@$TSV_HOST ping   # -> pong"
