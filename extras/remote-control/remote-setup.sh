#!/bin/sh
# Runs as root ON the TSV: remote-setup.sh <stage dir> <monitor host>. Idempotent.
set -e
S="$1"; MON="$2"; D="$S/rootfs"
apk add -q prometheus-node-exporter rsyslog
for f in etc/rsyslog/rsyslog.conf etc/nftables.d/60_remote_control.nft; do sed -i "s/@MONITOR_HOST@/$MON/g" "$D/$f"; done
# metrics: node_exporter :9100, reachable from the monitor host only
install -D -m 0644 $D/etc/systemd/system/node-exporter.service /etc/systemd/system/node-exporter.service
install -m 0644 $D/etc/nftables.d/60_remote_control.nft /etc/nftables.d/60_remote_control.nft
# logs: forward the RAM-only journal over UDP syslog
install -m 0644 $D/etc/rsyslog/rsyslog.conf /etc/rsyslog.conf
rm -rf /etc/rsyslog.d
if ! systemctl cat rsyslog.service >/dev/null 2>&1; then
  printf '%s\n' '[Unit]' 'Description=rsyslog: forward the journal' 'After=network-online.target' 'Wants=network-online.target' \
    '[Service]' 'RuntimeDirectory=rsyslog' 'ExecStart=/usr/sbin/rsyslogd -n -f /etc/rsyslog.conf -i /run/rsyslogd.pid' 'Restart=always' 'RestartSec=5' \
    '[Install]' 'WantedBy=multi-user.target' > /etc/systemd/system/rsyslog.service
fi
# remote actions: user mcremote, key-only from the monitor host, forced command (reboot | screen | camera | ping)
install -m 0755 $D/usr/local/bin/mc-remote $D/usr/local/bin/mc-screen $D/usr/local/bin/mc-camera /usr/local/bin/
id tsvcam >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin --groups video tsvcam
visudo -cf $D/etc/sudoers.d/mc-remote >/dev/null
install -m 0440 $D/etc/sudoers.d/mc-remote /etc/sudoers.d/mc-remote
id mcremote >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mcremote --shell /bin/sh mcremote
echo 'mcremote:*' | chpasswd -e   # no password, but not "locked" (sshd would refuse the key)
install -d -m 0700 -o mcremote -g mcremote /var/lib/mcremote/.ssh
printf 'restrict,from="%s",command="/usr/local/bin/mc-remote" %s\n' "$MON" "$(cat $S/mcremote.pub)" > /var/lib/mcremote/.ssh/authorized_keys
chown mcremote:mcremote /var/lib/mcremote/.ssh/authorized_keys; chmod 0600 /var/lib/mcremote/.ssh/authorized_keys
systemctl daemon-reload
systemctl enable -q --now node-exporter.service rsyslog.service
systemctl restart rsyslog.service nftables.service
rm -rf "$S"
systemctl is-active node-exporter.service rsyslog.service nftables.service | paste -sd' ' -
