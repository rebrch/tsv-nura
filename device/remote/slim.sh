#!/bin/sh
# Runs as root ON the TSV: slim.sh <staging dir with rootfs/>. Idempotent.
# Undo a unit with: systemctl unmask <unit> && systemctl enable --now <unit>
set -e
D="$1/rootfs"
# ---- services a wall kiosk never uses (the TSV has no modem; only the ADSP remoteproc runs)
UNITS="avahi-daemon.service avahi-daemon.socket q6voiced.service rmtfs.service msm-modem-uim-selection.service
  rtkit-daemon.service sleep-inhibitor.service
  systemd-nsresourced.service systemd-nsresourced.socket systemd-mountfsd.service systemd-mountfsd.socket
  systemd-sysext.service systemd-sysext.socket systemd-confext.service
  systemd-boot-update.service systemd-boot-clear-sysfail.service systemd-bootctl.socket systemd-tpm2-clear.service
  systemd-report-basic.socket systemd-report-cgroup.socket systemd-importd.socket systemd-repart.socket
  systemd-storage-block.socket systemd-storage-fs.socket systemd-factory-reset.socket
  systemd-binfmt.service proc-sys-fs-binfmt_misc.automount"
for u in $UNITS; do systemctl disable --now "$u" >/dev/null 2>&1 || true; systemctl mask "$u" >/dev/null 2>&1 || true; done
# ---- drivers for hardware it never uses (Bluetooth, accelerometer, Venus codec which fails to probe anyway)
install -m 0644 $D/etc/modprobe.d/tsv-blacklist.conf /etc/modprobe.d/tsv-blacklist.conf
for m in hci_uart btqca btbcm bluetooth bmc150_accel_i2c bmc150_accel_core; do rmmod $m 2>/dev/null || true; done
# ---- eMMC wear: journal in RAM only, no core dumps
install -D -m 0644 $D/etc/systemd/journald.conf.d/10-tsv-volatile.conf /etc/systemd/journald.conf.d/10-tsv-volatile.conf
install -D -m 0644 $D/etc/systemd/coredump.conf.d/10-tsv.conf /etc/systemd/coredump.conf.d/10-tsv.conf
systemctl restart systemd-journald
rm -rf /var/log/journal
# ---- filesystem: no access-time writes, batch metadata commits
sed -i -E 's#^(UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+ext4[[:space:]]+)defaults([[:space:]])#\1defaults,noatime,commit=60\2#; s#^(UUID=[^[:space:]]+[[:space:]]+/boot[[:space:]]+ext2[[:space:]]+)nodev,nosuid,noexec([[:space:]])#\1nodev,nosuid,noexec,noatime\2#' /etc/fstab
mount -o remount,noatime,commit=60 / ; mount -o remount,noatime /boot
# timesyncd rewrites its clock stamp on every sync: keep it in RAM (swclock-offset carries time across reboots)
grep -q ' /var/lib/systemd/timesync ' /etc/fstab || echo "tmpfs /var/lib/systemd/timesync tmpfs rw,nosuid,nodev,noexec,size=64k,mode=0755,uid=$(id -u systemd-timesync),gid=$(id -g systemd-timesync) 0 0" >> /etc/fstab
mountpoint -q /var/lib/systemd/timesync || { systemctl daemon-reload; mount /var/lib/systemd/timesync; systemctl restart systemd-timesyncd; }
rm -rf /var/cache/apk/*
echo "fstab:"; grep -E ' / | /boot |timesync' /etc/fstab
