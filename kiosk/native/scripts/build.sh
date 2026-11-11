#!/bin/bash
# Build tsv-panel inside pmbootstrap's native Alpine chroot (same Alpine release + musl as the device),
# so nothing is compiled on the TSV. Output: kiosk/native/target/tsv-panel
# Cargo.lock is kept in the repo: builds use exactly the locked crate versions (--locked).
# Usage: kiosk/native/scripts/build.sh [test]
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
MODE=${1:-build}
in_build_env "
SRC=\"\$REPO/kiosk/native\"
pmb_init
# Rust toolchain + headers in the chroot (idempotent)
pmb -q chroot -- apk add -q rust cargo pkgconf musl-dev fontconfig-dev freetype-dev libxkbcommon-dev \
  wayland-dev mesa-dev libinput-dev eudev-dev
H=\$(pmb_chroot_home)
sudo mkdir -p \$H/tsv-panel
sudo rsync -a --delete --exclude target --chown=12345:12345 \"\$SRC/\" \$H/tsv-panel/
LOCK=--locked; [ -f \"\$SRC/Cargo.lock\" ] || LOCK=
if [ '$MODE' = test ]; then
  pmb -q chroot --user -- sh -c \"cd ~/tsv-panel && CARGO_TARGET_DIR=~/target-tsv-panel cargo test --release \$LOCK 2>&1 | tail -20\"
else
  pmb -q chroot --user -- sh -c \"cd ~/tsv-panel && CARGO_TARGET_DIR=~/target-tsv-panel cargo build --release \$LOCK > ~/build.log 2>&1; rc=\\\$?; grep -vE '^ +(Compiling|Downloaded|Downloading|Locking|Adding|Updating)' ~/build.log | tail -60; exit \\\$rc\"
  mkdir -p \"\$SRC/target\"
  sudo cp \$H/target-tsv-panel/release/tsv-panel \"\$SRC/target/tsv-panel\"
  [ -f \"\$SRC/Cargo.lock\" ] || sudo cp \$H/tsv-panel/Cargo.lock \"\$SRC/Cargo.lock\"
  sudo chown \$(id -u) \"\$SRC/target/tsv-panel\" \"\$SRC/Cargo.lock\"
  pmb -q chroot -- sh -c 'rustc --version; cargo --version' 
  ls -la \"\$SRC/target/tsv-panel\"
fi
"
