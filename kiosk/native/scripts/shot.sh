#!/bin/bash
# Screenshot the TSV display (works for either kiosk mode). Usage: shot.sh [out.png]
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
OUT=${1:-shot.png}
T=$(mktemp); cat > "$T" <<'R'
U=$(id -u kiosk)
su -s /bin/sh kiosk -c "XDG_RUNTIME_DIR=/run/user/$U WAYLAND_DISPLAY=wayland-0 grim /tmp/k.png" && install -m644 /tmp/k.png /tmp/shot.png
R
tsv_root "$T"; rm -f "$T"
need TSV_HOST TSV_USER
scp -q -i "$TSV_SSH_KEY" -o IdentitiesOnly=yes "$TSV_USER@$TSV_HOST:/tmp/shot.png" "$OUT"
echo "$OUT"
