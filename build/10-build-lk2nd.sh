#!/bin/bash
# OPTIONAL: rebuild flash/lk2nd-signed-23.1.img (a prebuilt, tested copy is already in the repo).
#
# Why a custom lk2nd: the TSV's bootloader must stay LOCKED (an unlocked TSV does not boot), and a locked
# bootloader only boots AVB1-signed boot images. The lk2nd release image is unsigned and carries a QCDT,
# so it does not boot here. SIGN_BOOTIMG=1 signs it with the AOSP test key; LK2ND_QCDTBS="" drops the QCDT.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
mkdir -p "$OUT_DIR"
in_build_env "
. \"\$BUILD_DIR/venv-lk2nd/bin/activate\"
cd \"\$BUILD_DIR/lk2nd\" && rm -rf build-lk2nd-msm8953
make -j\$(nproc) TOOLCHAIN_PREFIX=arm-none-eabi- SIGN_BOOTIMG=1 LK2ND_QCDTBS='' lk2nd-msm8953 > build.log 2>&1 || { tail -30 build.log; exit 1; }
cp build-lk2nd-msm8953/lk2nd.img \"\$OUT_DIR/lk2nd-signed-23.1.img\"
"
shasum -a 256 "$OUT_DIR/lk2nd-signed-23.1.img"
echo "Reference (flash/): $(grep lk2nd "$REPO/flash/SHA256SUMS" | cut -d' ' -f1)"
echo "To use your build: cp out/lk2nd-signed-23.1.img flash/ and update flash/SHA256SUMS."
