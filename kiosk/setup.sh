#!/bin/bash
# Install (or switch) the kiosk on the TSV.   Usage: kiosk/setup.sh [native|chromium]   (default: KIOSK_MODE)
#  native   : Rust/Slint panel (build first: kiosk/native/scripts/build.sh). Talks to HA's WebSocket API
#             with a long-lived token. Fixed layout configured in kiosk/native/config/config.toml.
#  chromium : full-screen Chromium on your HA dashboard. Needs a one-time HA login (see kiosk/chromium/README.md).
# Both run as service tsv-kiosk.service (cage on tty1, user `kiosk`); switching modes replaces it.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
MODE="${1:-$KIOSK_MODE}"
case "$MODE" in native|chromium) ;; *) die "set KIOSK_MODE=native|chromium in .env (or pass it)";; esac
need HA_URL
K="$REPO/kiosk"; S=/tmp/tsv-kiosk-setup
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp -R "$K/common" "$STAGE/"
if [ "$MODE" = native ]; then
  [ -x "$K/native/target/tsv-panel" ] || die "build first: kiosk/native/scripts/build.sh"
  CFG="$K/native/config/config.toml"
  [ -f "$CFG" ] || die "create $CFG from config.example.toml (your entities)"
  mkdir -p "$STAGE/native"; cp "$K/native/tsv-kiosk.service" "$STAGE/native/"; cp "$K/native/target/tsv-panel" "$STAGE/"
  # HA URL from .env wins over the one in config.toml.
  sed -E "s#^url = .*#url = \"$HA_URL\"#" "$CFG" > "$STAGE/config.toml"
  TOKEN="${HA_TOKEN:-}"
  if [ -z "$TOKEN" ] && [ -t 0 ]; then
    read -r -s -p "HA long-lived token (Enter = keep the one already on the TSV / set it manually later): " TOKEN; echo
  fi
  [ -n "$TOKEN" ] && (umask 077; printf '%s' "$TOKEN" > "$STAGE/ha_token")
else
  mkdir -p "$STAGE/chromium"; cp "$K/chromium/tsv-chromium" "$K/chromium/tsv-kiosk.service" "$STAGE/chromium/"
  printf 'HA_URL=%s\nHA_DASHBOARD_PATH=%s\nCHROMIUM_EXTRA_FLAGS=\n' "$HA_URL" "${HA_DASHBOARD_PATH:-/}" > "$STAGE/kiosk.env"
fi
tsv_ssh "rm -rf $S && mkdir -p -m 700 $S"
tar -C "$STAGE" -cf - . | tsv_ssh "tar -C $S -xf -"
tsv_root "$K/common/remote-setup.sh" "$S" "$MODE"
[ "$MODE" = chromium ] && echo "Next: log Chromium into HA once - kiosk/chromium/login-remote.sh (or trusted_networks, see README)."
true
