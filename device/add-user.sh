#!/bin/bash
# Add (or re-password) a login on the TSV. Prompts for name and password - choose your own.
# Usage: device/add-user.sh [name] [--no-sudo]
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
NAME="${1:-}"; ADMIN=yes; [ "${2:-}" = --no-sudo ] && ADMIN=no
[ -t 0 ] || die "run this in a terminal: it asks for the new password"
[ -n "$NAME" ] || read -r -p "New username: " NAME
[[ "$NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username"
read -r -s -p "Password for $NAME: " PW; echo
read -r -s -p "Again: " PW2; echo
[ "$PW" = "$PW2" ] && [ ${#PW} -ge 6 ] || die "passwords differ or shorter than 6"
R=/tmp/add-user.$$.sh
tsv_scp "$REPO/device/remote/add-user.sh" "$R"
if [ -n "$TSV_PASSWORD_FILE" ] && [ -r "$TSV_PASSWORD_FILE" ]; then
  SUDO_PW=$(head -n1 "$TSV_PASSWORD_FILE")
else
  read -r -s -p "sudo password of $TSV_USER on the TSV: " SUDO_PW; echo
fi
printf '%s\n%s\n' "$SUDO_PW" "$PW" | tsv_ssh "sudo -S -p '' sh $R '$NAME' $ADMIN; rc=\$?; rm -f $R; exit \$rc"
