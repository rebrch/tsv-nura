# Shared helpers, sourced by every script in this repo. Loads ./.env (copy .env.example first).
# shellcheck shell=bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO/.env" ]; then
  set -a; . "$REPO/.env"; set +a
else
  echo "No $REPO/.env - copy .env.example to .env and fill it in." >&2
  exit 1
fi

# Defaults for anything left blank.
: "${TSV_HOSTNAME:=tsv}"
: "${TSV_TIMEZONE:=UTC}"
: "${TSV_SSH_KEY:=$REPO/secrets/tsv_ed25519}"
: "${TSV_HOST:=}"
: "${TSV_USER:=}"
: "${TSV_PASSWORD_FILE:=}"
: "${KIOSK_MODE:=}"
: "${LIMA_VM:=nura-build}"
: "${PMB_WORK:=}"
: "${EDL_DIR:=$REPO/edl}"
: "${BACKUP_DIR:=$REPO/backup}"
: "${OUT_DIR:=$REPO/out}"
# "~/x" -> $HOME/x and "./x" -> $REPO/x for every path setting.
for _v in TSV_SSH_KEY TSV_PASSWORD_FILE EDL_DIR BACKUP_DIR OUT_DIR LIMA_HOME PMB_WORK; do
  _p="${!_v:-}"; _p="${_p/#\~/$HOME}"; case "$_p" in ./*) _p="$REPO/${_p#./}" ;; esac
  printf -v "$_v" '%s' "$_p"
done
unset _v _p
if [ -n "${LIMA_HOME:-}" ]; then export LIMA_HOME; else unset LIMA_HOME; fi

die() { echo "error: $*" >&2; exit 1; }
need() { for v in "$@"; do [ -n "${!v:-}" ] || die "$v is empty - set it in .env"; done; }

# ---- talking to the device -------------------------------------------------
tsv_ssh() {
  need TSV_HOST TSV_USER
  ssh -i "$TSV_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$TSV_USER@$TSV_HOST" "$@"
}
tsv_scp() { # tsv_scp <local...> <remote dir>
  need TSV_HOST TSV_USER
  local dst="${*: -1}"; local n=$(($# - 1))
  scp -q -r -i "$TSV_SSH_KEY" -o IdentitiesOnly=yes "${@:1:$n}" "$TSV_USER@$TSV_HOST:$dst"
}
# Run a local shell script as root on the device: tsv_root <script> [args...]
# Uses TSV_PASSWORD_FILE for sudo when set (unattended, e.g. an agent); otherwise sudo asks on a TTY.
tsv_root() {
  local script="$1"; shift
  local remote="/tmp/tsv-root.$$.sh"
  tsv_scp "$script" "$remote"
  if [ -n "$TSV_PASSWORD_FILE" ] && [ -r "$TSV_PASSWORD_FILE" ]; then
    tsv_ssh "sudo -S -p '' sh $remote $*; rc=\$?; rm -f $remote; exit \$rc" < "$TSV_PASSWORD_FILE"
  else
    tsv_ssh -t "sudo sh $remote $*; rc=\$?; rm -f $remote; exit \$rc"
  fi
}

# ---- the build environment (macOS: Lima VM; Linux: this machine) -----------
# Tools and sources live in $REPO/.build (git-ignored). The repo is mounted at the same path inside the VM,
# so every path is the same on both sides. Commands run with scripts/build-env.sh loaded (pmb, pmb_init, ...).
BUILD_DIR="$REPO/.build"
in_build_env() { # in_build_env '<bash script>'
  local cmd="set -euo pipefail; . '$REPO/scripts/lib.sh'; . '$REPO/scripts/build-env.sh'; $1"
  if [ "$(uname -s)" = Darwin ]; then
    command -v limactl >/dev/null || die "Lima not installed - run build/00-build-host.sh"
    limactl shell --workdir "$REPO" "$LIMA_VM" -- bash -lc "$cmd"
  else
    (cd "$REPO" && bash -lc "$cmd")
  fi
}
