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
  : "${DIVISI_GID:=$(id -g)}"
  : "${DIVISI_USER:=$(id -un)}"
  [ "${#CONTEXTS[@]}" -gt 0 ] || die "config defines no CONTEXTS"
  validate_config
}

# Pre-declare the per-context maps as globals so a config's assignments land
# globally even though the config is sourced from inside load_config.
declare -gA CTX_MOUNT CTX_GIT_NAME CTX_GIT_EMAIL CTX_GH CTX_COLOR
declare -gA CTX_CLAUDE_AUTH CTX_VERTEX_PROJECT CTX_VERTEX_REGION CTX_SECRETS CTX_SEED

_paths_overlap() {
  [ "$1" = "$2" ] || [[ "$1" == "$2/"* ]] || [[ "$2" == "$1/"* ]]
}

validate_config() {
  [[ "$DIVISI_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid DIVISI_USER: $DIVISI_USER"
  [ "$DIVISI_UID" = "$(id -u)" ] || die "DIVISI_UID must match the current user"
  [ "$DIVISI_GID" = "$(id -g)" ] || die "DIVISI_GID must match the current primary group"
  [ "$DIVISI_USER" = "$(id -un)" ] || die "DIVISI_USER must match the current user"
  [ "${#DIVISI_GUARD_TOOLS[@]}" -gt 0 ] || die "config defines no guard tools"

  local state n other mount peer
  [[ "$DIVISI_STATE" = /* ]] || die "DIVISI_STATE must be an absolute path"
  state="$(realpath -m -- "$DIVISI_STATE")"
  [ "$state" != / ] || die "DIVISI_STATE cannot be /"
  local -A seen=()
  for n in "${CONTEXTS[@]}"; do
    [[ "$n" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "invalid context name: $n"
    [ -z "${seen[$n]:-}" ] || die "duplicate context name: $n"
    seen[$n]=1
    [[ "${CTX_SEED[$n]:-}" != apikey:* ]] || die "remove the API key from CTX_SEED[$n] and place it in $state/$n/.secrets/anthropic_api_key"
    mount="${CTX_MOUNT[$n]:-}"
    [ -n "$mount" ] || continue
    [[ "$mount" = /* && "$mount" != *:* ]] || die "mount for $n must be an absolute path without a colon"
    [ -d "$mount" ] || die "mount for $n does not exist: $mount"
    mount="$(realpath -e -- "$mount")"
    [ "$mount" != / ] || die "mount for $n cannot be /"
    _paths_overlap "$mount" "$state" && die "mount for $n overlaps DIVISI_STATE: $mount"
    for other in "${CONTEXTS[@]}"; do
      [ "$other" = "$n" ] && break
      peer="${CTX_MOUNT[$other]:-}"
      [ -n "$peer" ] || continue
      peer="$(realpath -e -- "$peer")"
      _paths_overlap "$mount" "$peer" && die "mounts for $n and $other overlap: $mount and $peer"
    done
    CTX_MOUNT[$n]="$mount"
  done
}

ctx_home() { echo "$DIVISI_STATE/$1"; }

# ---- podman / selinux ---------------------------------------------------
require_podman() { command -v podman >/dev/null || die "podman not found (install the podman package)"; }

require_supported_os() {
  local os_file="${DIVISI_OS_RELEASE:-/etc/os-release}"
  [ -r "$os_file" ] || die "cannot read $os_file"
  local ID='' VERSION_ID=''
  # shellcheck disable=SC1090
  . "$os_file"
  case "$ID:$VERSION_ID" in
    fedora:*) [[ "$VERSION_ID" =~ ^[0-9]+$ ]] && [ "$VERSION_ID" -ge 40 ] ;;
    rhel:9|rhel:9.*|rhel:10|rhel:10.*) true ;;
    *) false ;;
  esac || die "supported hosts are RHEL 9, RHEL 10, and Fedora 40 or newer (found $ID $VERSION_ID)"
}

require_supported_host() {
  require_supported_os
  [ "$(id -u)" -ne 0 ] || die "run divisi as a regular user, not root"
  require_podman
  local ids user uid
  user="$(id -un)"; uid="$(id -u)"
  for ids in /etc/subuid /etc/subgid; do
    [ -r "$ids" ] || die "cannot read $ids"
    awk -F: -v user="$user" -v uid="$uid" \
      '($1 == user || $1 == uid) && $3 > 0 { found=1 } END { exit !found }' "$ids" \
      || die "rootless Podman needs an entry for $user in $ids"
  done
  podman info >/dev/null 2>&1 || die "rootless Podman is not ready; run 'podman info' for details"
}

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

ctx_managed() {
  [ "$(podman inspect -f '{{index .Config.Labels "io.divisi.managed"}}' "$1" 2>/dev/null)" = 1 ] &&
    [ "$(podman inspect -f '{{index .Config.Labels "io.divisi.context"}}' "$1" 2>/dev/null)" = "$1" ]
}
ctx_running() { podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true; }
