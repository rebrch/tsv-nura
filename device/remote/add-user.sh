#!/bin/sh
# Runs as root ON the TSV: add-user.sh <name> <yes|no: sudo> ; password read from stdin (one line).
set -e
NAME="$1"; ADMIN="${2:-yes}"
IFS= read -r PW
id "$NAME" >/dev/null 2>&1 && { echo "user $NAME exists - updating password"; } ||
  # NB: Alpine has no bash by default - use /bin/ash (a missing shell makes logins fail silently).
  useradd -m -s /bin/ash -G audio,video,netdev,plugdev,input "$NAME"
[ "$ADMIN" = yes ] && usermod -aG wheel "$NAME"
printf '%s:%s\n' "$NAME" "$PW" | chpasswd
id "$NAME"
