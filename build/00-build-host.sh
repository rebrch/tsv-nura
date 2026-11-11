#!/bin/bash
# Prepare the build environment (once). Everything it fetches goes into .build/ in this repo (git-ignored).
#  macOS : creates a Lima VM ($LIMA_VM, Debian 13 arm64) with this repo mounted read-write at the same path.
#  Linux : installs the same packages on this machine (Debian/Ubuntu; adapt for other distros).
# Then fetches pmbootstrap (pinned), lk2nd (pinned) and a python venv for lk2nd's AVB1 signing.
#
# Apple Silicon / arm64 Linux is fastest (native aarch64). x86_64 works, but pmbootstrap then emulates
# aarch64 with QEMU for the panel, kernel-module and libcamera builds, which is much slower.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

PMBOOTSTRAP_REV=e0dfe2cda7f3a0b70cdcc96f3060100839322aa4   # 3.12.1-7, used for the reference build
LK2ND_REV=e9c8b21735c13dd7ace808b1e35451638f0a0c6d         # tag 23.1

if [ "$(uname -s)" = Darwin ]; then
  command -v limactl >/dev/null || { echo "Installing Lima (brew install lima)"; brew install lima; }
  if ! limactl list -q 2>/dev/null | grep -qx "$LIMA_VM"; then
    limactl create --name="$LIMA_VM" --tty=false --vm-type=vz --arch=aarch64 \
      --cpus="${VM_CPUS:-8}" --memory="${VM_MEMORY_GB:-16}" --disk="${VM_DISK_GB:-80}" \
      --set=".mounts=[{\"location\":\"$REPO\",\"writable\":true}]" template:debian-13
  fi
  limactl start "$LIMA_VM" >/dev/null 2>&1 || true
fi

in_build_env "
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y git make rsync curl xz-utils gcc-arm-none-eabi \
  libnewlib-arm-none-eabi device-tree-compiler python3 python3-venv openssl kpartx android-sdk-libsparse-utils
mkdir -p \"\$BUILD_DIR\"
# pmbootstrap (postmarketOS/Nura build tool)
[ -d \"\$BUILD_DIR/pmbootstrap/.git\" ] || git clone -q https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git \"\$BUILD_DIR/pmbootstrap\"
git -C \"\$BUILD_DIR/pmbootstrap\" fetch -q origin && git -C \"\$BUILD_DIR/pmbootstrap\" checkout -q $PMBOOTSTRAP_REV
# lk2nd (secondary bootloader). Debian's python3-pycryptodome installs as 'Cryptodome', but lk2nd's
# signer imports 'Crypto' - so the signing deps come from pip in a venv.
[ -d \"\$BUILD_DIR/lk2nd/.git\" ] || git clone -q https://github.com/msm8916-mainline/lk2nd.git \"\$BUILD_DIR/lk2nd\"
git -C \"\$BUILD_DIR/lk2nd\" checkout -q $LK2ND_REV
[ -x \"\$BUILD_DIR/venv-lk2nd/bin/python\" ] || python3 -m venv \"\$BUILD_DIR/venv-lk2nd\"
\"\$BUILD_DIR/venv-lk2nd/bin/pip\" -q install pycryptodome pyasn1 pyasn1-modules
pmb --version
pmb_init
echo \"pmbootstrap work dir: \$PMB_WORK\"
"
echo "Build host ready."
