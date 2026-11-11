#!/bin/bash
# Log the kiosk's Chromium into Home Assistant from your computer (the TSV has no keyboard).
# Restarts Chromium with DevTools on the TSV's localhost:9222, tunnels it over SSH, waits while you
# log in via chrome://inspect, then restarts Chromium without the debug port.
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
SET='sed -i "s|^CHROMIUM_EXTRA_FLAGS=.*|CHROMIUM_EXTRA_FLAGS=$1|" /etc/tsv-kiosk/kiosk.env && systemctl restart tsv-kiosk'
T=$(mktemp); printf '%s\n' "$SET" > "$T"
tsv_root "$T" --remote-debugging-port=9222
cat <<MSG

1. In Chrome/Chromium/Edge on THIS computer open:  chrome://inspect/#devices
2. "Configure..." -> add  localhost:9222
3. Click "inspect" under the Home Assistant page, log in (tick "Keep me logged in").
4. Come back here and press Enter.
MSG
tsv_ssh -N -L 9222:127.0.0.1:9222 & TUN=$!
read -r _
kill $TUN 2>/dev/null || true
tsv_root "$T" ""
rm -f "$T"
echo "Debug port closed; kiosk restarted with the saved login."
