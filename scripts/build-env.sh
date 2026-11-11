# Sourced INSIDE the build environment (Lima VM on macOS, or the Linux host) by in_build_env.
# shellcheck shell=bash
# pmbootstrap's work dir (chroots, package repo, caches) needs a native Linux filesystem: on macOS the
# repo is a virtiofs mount, so the work dir defaults to the VM's own disk. Override with PMB_WORK in .env.
if [ -z "${PMB_WORK:-}" ]; then
  if [ -e /run/lima-boot-done ] || [ -d /mnt/lima-cidata ]; then PMB_WORK="$HOME/tsv-nura-work"; else PMB_WORK="$BUILD_DIR/work"; fi
fi
PMB_CFG="$BUILD_DIR/pmbootstrap.cfg"
PMB_APORTS="$PMB_WORK/pmaports"   # this repo's own pmaports checkout (never a pre-existing one)
PMB_CHANNEL=v26.06
PMB_DEVICE=qcom-msm8953   # generic msm8953 device; lk2nd picks the TSV DTB (apq8053-lenovo-cd-18781y)

pmb() { "$BUILD_DIR/pmbootstrap/pmbootstrap.py" -c "$PMB_CFG" -w "$PMB_WORK" -p "$PMB_APORTS" "$@"; }

# Initialise this repo's own pmbootstrap config + work dir (never touches ~/.config/pmbootstrap*.cfg).
pmb_init() {
  [ -x "$BUILD_DIR/pmbootstrap/pmbootstrap.py" ] || { echo "run build/00-build-host.sh first" >&2; return 1; }
  mkdir -p "$PMB_WORK"
  [ -d "$PMB_APORTS/.git" ] || git clone -q -b "$PMB_CHANNEL" https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMB_APORTS"
  if [ ! -f "$PMB_CFG" ]; then
    yes '' | pmb init >/dev/null 2>&1 || true
    [ -f "$PMB_CFG" ] || { echo "pmbootstrap init failed; run: $BUILD_DIR/pmbootstrap/pmbootstrap.py -c $PMB_CFG -w $PMB_WORK init" >&2; return 1; }
  fi
  [ "$(git -C "$PMB_APORTS" branch --show-current)" = "$PMB_CHANNEL" ] || git -C "$PMB_APORTS" checkout -q "$PMB_CHANNEL"
  [ "$(pmb config aports)" = "$PMB_APORTS" ] || pmb config aports "$PMB_APORTS"
  [ "$(pmb config aports)" = "$PMB_APORTS" ] || { echo "pmbootstrap is not using $PMB_APORTS - refusing to continue" >&2; return 1; }
  pmb config device "$PMB_DEVICE"
  pmb config ui console
}

# Path of the pmbootstrap native chroot's /home/pmos as seen from the build environment.
pmb_chroot_home() { echo "$(pmb config work)/chroot_native/home/pmos"; }
