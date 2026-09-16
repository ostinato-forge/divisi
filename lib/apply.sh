# divisi apply: build the image and (re)create every context from config.
# Idempotent - safe to re-run after editing the config or updating CLIs.
# Container homes hold all state, so containers are recreated freely.

divisi_apply() {
  require_supported_host
  . "$DIVISI_ROOT/lib/enforce.sh"
  divisi_guard_preflight
  umask 077
  mkdir -p "$DIVISI_STATE"
  chmod 700 "$DIVISI_STATE"

  info "Building image $DIVISI_IMAGE from $DIVISI_BASE"
  local pull=(); [ -n "${DIVISI_PULL:-}" ] && pull=(--pull=newer)
  podman build "${pull[@]}" \
    -t "$DIVISI_IMAGE" \
    --build-arg "BASE=$DIVISI_BASE" \
    --build-arg "UID=$DIVISI_UID" \
    --build-arg "GID=$DIVISI_GID" \
    --build-arg "USERNAME=$DIVISI_USER" \
    -f "$DIVISI_ROOT/Containerfile" "$DIVISI_ROOT" >/dev/null
  ok "image built"

  local n
  for n in "${CONTEXTS[@]}"; do _build_home "$n"; done
  divisi_relabel

  for n in "${CONTEXTS[@]}"; do _recreate_container "$n"; done

  info "Installing host guard shims"
  . "$DIVISI_ROOT/lib/enforce.sh"; divisi_enforce
  _install_launchers

  echo; ok "apply complete - run 'divisi check' to verify the walls"
  info "Per-context one-time logins (gh / claude /login) are still yours to do."
}

# Build (or refresh) one context's home directory: shell, git identity,
# secret vault, and claude auth wiring. Existing live state is preserved;
# only the divisi-managed files are rewritten.
_build_home() {
  local n="$1" home; home="$(ctx_home "$n")"
  mkdir -p "$home"
  chmod 700 "$home"

  # --- shell: visible context label + color, exported CONTEXT ---
  local color="${CTX_COLOR[$n]:-1;37}"
  {
    echo '[ -f /etc/bashrc ] && . /etc/bashrc'
    echo "export CONTEXT=$n"
    printf "PS1='\\[\\e[%sm\\][%s]\\[\\e[0m\\] \\w \\$ '\n" "$color" "$n"
    _auth_env_lines "$n"
  } > "$home/.bashrc"
  printf '[ -f ~/.bashrc ] && . ~/.bashrc\n' > "$home/.bash_profile"

  # --- git identity ---
  {
    if [ -n "${CTX_GIT_NAME[$n]:-}" ] || [ -n "${CTX_GIT_EMAIL[$n]:-}" ]; then
      echo '[user]'
      [ -n "${CTX_GIT_NAME[$n]:-}" ]  && echo "	name = ${CTX_GIT_NAME[$n]}"
      [ -n "${CTX_GIT_EMAIL[$n]:-}" ] && echo "	email = ${CTX_GIT_EMAIL[$n]}"
    fi
    echo '[pull]'; echo '	ff = only'
    echo '[credential "https://github.com"]'; echo '	helper = !/usr/bin/gh auth git-credential'
  } > "$home/.gitconfig"

  # --- secret vault (0700 dir, 0600 files), surfaced as ~/.secrets ---
  if [ -n "${CTX_SECRETS[$n]:-}" ]; then
    mkdir -p "$home/.secrets"
    chmod 700 "$home/.secrets"
    local f
    for f in ${CTX_SECRETS[$n]}; do
      [ -e "$f" ] || { warn "secret not found, skipping: $f"; continue; }
      install -m 600 "$f" "$home/.secrets/$(basename "$f")"
    done
  fi

  _seed_home "$n" "$home"
}

# Emit the auth-specific export lines for a context's .bashrc.
_auth_env_lines() {
  local n="$1"
  case "${CTX_CLAUDE_AUTH[$n]:-none}" in
    vertex)
      echo '# claude -> Vertex AI'
      echo 'export CLAUDE_CODE_USE_VERTEX=1'
      [ -n "${CTX_VERTEX_REGION[$n]:-}" ]  && echo "export CLOUD_ML_REGION=${CTX_VERTEX_REGION[$n]}"
      [ -n "${CTX_VERTEX_PROJECT[$n]:-}" ] && echo "export ANTHROPIC_VERTEX_PROJECT_ID=${CTX_VERTEX_PROJECT[$n]}" ;;
    claude_ai)
      echo '# claude -> Claude.ai (default per-context config dir)'
      echo 'export CLAUDE_CODE_USE_VERTEX=' ;;
    api_key)
      echo '# claude -> Anthropic API key from vault'
      echo 'export CLAUDE_CODE_USE_VERTEX='
      echo '[ -f ~/.secrets/anthropic_api_key ] && export ANTHROPIC_API_KEY="$(cat ~/.secrets/anthropic_api_key)"' ;;
    *) echo '# no agent auth in this context' ;;
  esac
}

# Honor the per-context CTX_SEED directive set during init.
_seed_home() {
  local n="$1" home="$2" seed
  seed="${CTX_SEED[$n]:-}"
  case "$seed" in
    gcloud)
      [ -d "$HOME/.config/gcloud" ] && { mkdir -p "$home/.config/gcloud"; cp -a "$HOME/.config/gcloud/." "$home/.config/gcloud/"; ok "$n: seeded gcloud ADC"; } ;;
    claude:*)
      local src="${seed#claude:}"
      [ -d "$src" ] && { mkdir -p "$home/.claude"; cp -a "$src/." "$home/.claude/"; ok "$n: seeded claude config from $src"; } ;;
  esac
}

# Auth env must be set at the CONTAINER level, not just in .bashrc: agents are
# often launched by a non-login exec (IDE terminal profile, `podman exec ... claude`)
# that never sources .bashrc. TERM is set too, or the TUI keyboard breaks.
_ctx_env_args() {
  local n="$1"
  printf '%s\0' -e "TERM=xterm-256color"
  case "${CTX_CLAUDE_AUTH[$n]:-none}" in
    vertex)
      printf '%s\0' -e "CLAUDE_CODE_USE_VERTEX=1"
      [ -n "${CTX_VERTEX_REGION[$n]:-}" ]  && printf '%s\0' -e "CLOUD_ML_REGION=${CTX_VERTEX_REGION[$n]}"
      [ -n "${CTX_VERTEX_PROJECT[$n]:-}" ] && printf '%s\0' -e "ANTHROPIC_VERTEX_PROJECT_ID=${CTX_VERTEX_PROJECT[$n]}" ;;
    claude_ai)
      printf '%s\0' -e "CLAUDE_CODE_USE_VERTEX=" ;;
    api_key)
      printf '%s\0' -e "CLAUDE_CODE_USE_VERTEX=" ;;
  esac
}

_recreate_container() {
  local n="$1" home; home="$(ctx_home "$n")"
  if podman container exists "$n"; then
    ctx_managed "$n" || die "container $n is not marked as managed by divisi; inspect or rename it before apply"
    podman rm -f "$n" >/dev/null
  fi
  local mount_args=()
  if [ -n "${CTX_MOUNT[$n]:-}" ]; then mount_args=(-v "${CTX_MOUNT[$n]}:${CTX_MOUNT[$n]}:z"); fi
  local env_args=(); mapfile -d '' -t env_args < <(_ctx_env_args "$n")
  podman create --name "$n" --hostname "$n" \
    --label io.divisi.managed=1 --label "io.divisi.context=$n" \
    --userns=keep-id --user "$DIVISI_UID:$DIVISI_GID" \
    -e "HOME=/home/$DIVISI_USER" -e DISABLE_AUTOUPDATER=1 "${env_args[@]}" \
    --network host \
    -v "$home:/home/$DIVISI_USER:Z" "${mount_args[@]}" \
    -w "/home/$DIVISI_USER" \
    "$DIVISI_IMAGE" sleep infinity >/dev/null
  podman start "$n" >/dev/null
  ok "context $n ready"
}

# Optional convenience: a `divisi-<name>` launcher per context on PATH.
_install_launchers() {
  local bindir="${DIVISI_BIN:-$HOME/.local/bin}"
  mkdir -p "$bindir"
  local self; self="$DIVISI_ROOT/bin/divisi"
  local n
  for n in "${CONTEXTS[@]}"; do
    cat > "$bindir/$n" <<EOF
#!/usr/bin/env bash
exec "$self" enter "$n" "\$@"
EOF
    chmod +x "$bindir/$n"
  done
  info "launchers in $bindir (ensure it is on PATH): ${CONTEXTS[*]}"
}
