#!/bin/bash
# Build the Nura (postmarketOS) v26.06 rootfs image for the TSV and bake in your account, SSH key,
# hostname, timezone and Wi-Fi. Output: $OUT_DIR/nura-qcom-msm8953.img (+ .sha256), flashed to `userdata`.
#
# Your account: TSV_USER from .env, password from TSV_PASSWORD_FILE or typed at the prompt. It gets
# sudo (group wheel). Pick your own credentials - nothing here has a default password.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
need TSV_USER WIFI_SSID WIFI_PSK

EXTRA_PKGS=openssh-server,networkmanager-cli,networkmanager-tui,htop

# ---- password (never written into the repo)
if [ -n "$TSV_PASSWORD_FILE" ] && [ -r "$TSV_PASSWORD_FILE" ]; then
  PW=$(head -n1 "$TSV_PASSWORD_FILE")
else
  [ -t 0 ] || die "no TTY to ask for a password - put it in TSV_PASSWORD_FILE (chmod 600) or run this in a terminal"
  read -r -s -p "Password for $TSV_USER on the TSV: " PW; echo
  read -r -s -p "Again: " PW2; echo
  [ "$PW" = "$PW2" ] || die "passwords differ"
fi
[ ${#PW} -ge 6 ] || die "password too short"

# ---- SSH key for your account
mkdir -p "$(dirname "$TSV_SSH_KEY")"
[ -f "$TSV_SSH_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "$TSV_USER@$TSV_HOSTNAME" -f "$TSV_SSH_KEY"
mkdir -p "$OUT_DIR"
cp "$TSV_SSH_KEY.pub" "$OUT_DIR/.tsv_key.pub"

# ---- Wi-Fi profile (NetworkManager keyfile), copied into the image below then deleted
umask 077
printf '[connection]\nid=home\ntype=wifi\nautoconnect=true\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
  "$WIFI_SSID" "$WIFI_PSK" > "$OUT_DIR/.wifi.nmconnection"
trap 'rm -f "$OUT_DIR/.wifi.nmconnection" "$OUT_DIR/.tsv_key.pub"' EXIT

printf '%s\n' "$PW" | in_build_env "
IFS= read -r PW
pmb_init
pmb config hostname \"\$TSV_HOSTNAME\"
pmb config user \"\$TSV_USER\"
pmb config ssh_keys True
pmb config ssh_key_glob \"\$OUT_DIR/.tsv_key.pub\"
pmb config timezone \"\$TSV_TIMEZONE\"
pmb config extra_packages '$EXTRA_PKGS'
pmb config kernel stable 2>/dev/null || true
echo 'Building (10-30 min on first run)...'
pmb -q install --password \"\$PW\" > \"\$OUT_DIR/install.log\" 2>&1 || { tail -40 \"\$OUT_DIR/install.log\"; exit 1; }
pmb shutdown >/dev/null
IMG=\$(pmb config work)/chroot_native/home/pmos/rootfs/\$PMB_DEVICE.img
OUT=\"\$OUT_DIR/nura-qcom-msm8953.img\"
sudo cp \"\$IMG\" \"\$OUT\" && sudo chown \$(id -u) \"\$OUT\"
# Bake in the Wi-Fi profile (root fs = partition 2 of the image).
L=\$(sudo losetup -fP --show \"\$OUT\"); M=\$(mktemp -d); sudo mount \${L}p2 \$M
sudo install -m600 -o root -g root \"\$OUT_DIR/.wifi.nmconnection\" \$M/etc/NetworkManager/system-connections/home.nmconnection
sudo umount \$M; sudo losetup -d \$L; rmdir \$M
"
(cd "$OUT_DIR" && shasum -a 256 nura-qcom-msm8953.img > nura-qcom-msm8953.img.sha256 && cat nura-qcom-msm8953.img.sha256)
echo "Image ready. Next: flash/flash.sh backup (if not done), then flash/flash.sh flash"
