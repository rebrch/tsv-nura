#!/bin/bash
# Send a control command to the running native panel: page <0-3> | dim <light id> | close
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
[[ "$*" =~ ^[a-z]+( [A-Za-z0-9_.]+)?$ ]] || die "usage: ctl.sh page <0-3> | dim <light id> | close"
T=$(mktemp); cat > "$T" <<'R'
U=$(id -u kiosk)
su -s /bin/sh kiosk -c "python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect(\"/run/user/$U/tsv-panel.sock\"); s.sendall(b\"$*\\n\"); print(s.recv(16).decode().strip())'"
R
tsv_root "$T" "$*"; rm -f "$T"
