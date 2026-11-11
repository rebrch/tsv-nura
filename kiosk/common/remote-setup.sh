#!/bin/sh
# Runs as root ON the TSV: remote-setup.sh <stage dir> <native|chromium>. Idempotent.
set -e
S="$1"; MODE="$2"
# Display stack (Adreno 506 via freedreno/Mesa; cage = single-app Wayland compositor)
PKGS="cage mesa-dri-gallium mesa-egl libinput libxkbcommon grim font-inter font-droid font-droid-nonlatin font-twemoji"
[ "$MODE" = chromium ] && PKGS="$PKGS chromium" || PKGS="$PKGS python3"  # python3: dev control socket (ctl.sh)
apk add -q $PKGS
# Locked system user that owns the display; nobody can log in as it.
id kiosk >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/kiosk --shell /sbin/nologin --groups video,input,render,audio kiosk
passwd -l kiosk >/dev/null 2>&1 || true
# Never show a login prompt on the screen: no getty on tty1, no auto VTs.
install -D -m 0644 "$S/common/logind.conf.d/10-tsv-kiosk.conf" /etc/systemd/logind.conf.d/10-tsv-kiosk.conf
systemctl disable --now getty@tty1.service >/dev/null 2>&1 || true
systemctl mask getty@tty1.service autovt@tty1.service >/dev/null
if [ "$MODE" = native ]; then
  install -m 0755 "$S/tsv-panel" /usr/local/bin/tsv-panel
  install -d -m 0750 -o root -g kiosk /etc/tsv-panel
  install -m 0640 -o root -g kiosk "$S/config.toml" /etc/tsv-panel/config.toml
  [ -f "$S/ha_token" ] && install -m 0640 -o root -g kiosk "$S/ha_token" /etc/tsv-panel/ha_token
  [ -f /etc/tsv-panel/ha_token ] || echo "WARNING: /etc/tsv-panel/ha_token missing - the panel will show 'disconnected'"
  install -m 0644 "$S/native/tsv-kiosk.service" /etc/systemd/system/tsv-kiosk.service
else
  install -m 0755 "$S/chromium/tsv-chromium" /usr/local/bin/tsv-chromium
  install -d -m 0755 /etc/tsv-kiosk
  install -m 0644 "$S/kiosk.env" /etc/tsv-kiosk/kiosk.env
  install -m 0644 "$S/chromium/tsv-kiosk.service" /etc/systemd/system/tsv-kiosk.service
fi
systemctl daemon-reload
systemctl enable tsv-kiosk.service >/dev/null 2>&1
systemctl restart tsv-kiosk.service
sleep 5
systemctl is-active tsv-kiosk.service
journalctl -u tsv-kiosk -b --no-pager -n 10 -o cat
rm -rf "$S"
