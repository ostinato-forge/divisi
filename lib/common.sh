# divisi common helpers: config loading, logging, podman/SELinux utilities.
# Sourced by bin/divisi and every lib/*.sh subcommand.

set -o pipefail

# ---- output -------------------------------------------------------------
divisi_c() { case "$1" in red) printf '\033[1;31m';; grn) printf '\033[1;32m';;
  ylw) printf '\033[1;33m';; dim) printf '\033[2m';; off) printf '\033[0m';; esac; }
info() { printf '%s%s%s\n' "$(divisi_c dim)" "$*" "$(divisi_c off)"; }
ok()   { printf '  %sok%s  %s\n' "$(divisi_c grn)" "$(divisi_c off)" "$*"; }
warn() { printf '%swarn%s %s\n' "$(divisi_c ylw)" "$(divisi_c off)" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$(divisi_c red)" "$(divisi_c off)" "$*" >&2; exit 1; }

# ---- config -------------------------------------------------------------
# Resolution order: $DIVISI_CONFIG, ./divisi.conf, ~/.config/divisi/divisi.conf
divisi_config_path() {
  if [ -n "${DIVISI_CONFIG:-}" ]; then echo "$DIVISI_CONFIG"; return; fi
  if [ -f ./divisi.conf ]; then echo "$PWD/divisi.conf"; return; fi
  echo "$HOME/.config/divisi/divisi.conf"
}

load_config() {
  local cfg; cfg="$(divisi_config_path)"
  [ -f "$cfg" ] || die "no config at $cfg - run 'divisi init' first"
  # Config is sourced bash (associative arrays). It is local, user-owned, gitignored.
  # shellcheck disable=SC1090
  . "$cfg"
  : "${DIVISI_IMAGE:=agentbox}"
  : "${DIVISI_BASE:=registry.fedoraproject.org/fedora:43}"
  : "${DIVISI_STATE:=$HOME/.local/share/divisi}"
  : "${DIVISI_UID:=$(id -u)}"
  : "${DIVISI_USER:=$(id -un)}"
  [ "${#CONTEXTS[@]}" -gt 0 ] || die "config defines no CONTEXTS"
}

# Pre-declare the per-context maps as globals so a config's assignments land
# globally even though the config is sourced from inside load_config.
declare -gA CTX_MOUNT CTX_GIT_NAME CTX_GIT_EMAIL CTX_GH CTX_COLOR
declare -gA CTX_CLAUDE_AUTH CTX_VERTEX_PROJECT CTX_VERTEX_REGION CTX_SECRETS CTX_SEED

ctx_home() { echo "$DIVISI_STATE/$1"; }

# ---- podman / selinux ---------------------------------------------------
require_podman() { command -v podman >/dev/null || die "podman not found (dnf install podman)"; }

# mv/cp -a preserve the source SELinux label; bind-mounted into a container
# that yields EACCES. Relabel context homes to a known-good local label.
divisi_relabel() {
  command -v chcon >/dev/null || return 0   # non-SELinux host: nothing to do
  local name ref
  for name in "${CONTEXTS[@]}"; do
    ref="$(ctx_home "$name")/.gitconfig"
    [ -e "$ref" ] || continue
    chcon -R --reference="$ref" "$(ctx_home "$name")" 2>/dev/null || true
  done
}

ctx_running() { podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
