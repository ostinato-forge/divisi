# Host guard shims live in the user's bin directory. System binaries stay in place.
# Override and blocked events log the tool name only, never command arguments.

divisi_guard_preflight() {
  local bindir="${DIVISI_BIN:-$HOME/.local/bin}" t found dir
  local -a dirs=()
  [[ "$bindir" = /* ]] || die "DIVISI_BIN must be an absolute path"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) die "$bindir must be on PATH before running divisi apply" ;;
  esac
  for t in "${DIVISI_GUARD_TOOLS[@]}"; do
    [[ "$t" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "invalid guard tool name: $t"
    found="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$found" ] || continue
    [[ "$found" = /* ]] || die "guard tool $t resolves to a shell function or alias"
    IFS=: read -r -a dirs <<< "$PATH"
    for dir in "${dirs[@]}"; do
      [ "$dir" = "$bindir" ] && break
      [ "$found" = "$dir/$t" ] && die "$bindir must come before $dir on PATH to guard $t"
    done
  done
}

divisi_enforce() {
  divisi_guard_preflight
  local bindir="${DIVISI_BIN:-$HOME/.local/bin}"
  local quarantine="$DIVISI_STATE/host-tools"
  local log="$DIVISI_STATE/host-block.log"
  mkdir -p "$quarantine" "$bindir"
  chmod 700 "$quarantine"
  touch "$log"
  chmod 600 "$log"

  local t path real tmp target log_path names
  names="$(printf '%s | ' "${DIVISI_GUARD_TOOLS[@]}")"
  names="${names% | }"
  for t in "${DIVISI_GUARD_TOOLS[@]}"; do
    path="$bindir/$t"
    if [ -e "$path" ] && grep -q 'divisi-guard shim' "$path" 2>/dev/null; then
      [ -e "$quarantine/$t" ] || die "guard for $t has no saved host command"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      real="$(readlink -f "$path")"
      if [ "$real" = "$path" ]; then
        mv "$path" "$quarantine/$t"
      else
        ln -sfn "$real" "$quarantine/$t"
        rm -f "$path"
      fi
    elif [ ! -e "$quarantine/$t" ]; then
      real="$(command -v "$t" 2>/dev/null || true)"
      [ -n "$real" ] || { info "skip $t (not on host PATH)"; continue; }
      [ -e "$real" ] || die "host command is missing: $real"
      if grep -q 'divisi-guard shim' "$real" 2>/dev/null; then
        die "existing guard for $t has no saved host command"
      fi
      ln -s "$real" "$quarantine/$t"
    fi

    tmp="$(mktemp "$bindir/.divisi-$t.XXXXXX")"
    target="$(printf '%q' "$quarantine/$t")"
    log_path="$(printf '%q' "$log")"
    cat > "$tmp" <<SHIM
#!/usr/bin/env bash
# divisi-guard shim (managed by divisi enforce)
if [ "\${DIVISI_OVERRIDE:-}" = "1" ]; then
  printf '%s OVERRIDE $t\\n' "\$(date -Is)" >> $log_path
  exec $target "\$@"
fi
printf 'BLOCKED: $t runs inside a divisi context ($names).\\n' >&2
printf 'Enter one with: divisi enter <name>\\n' >&2
printf '%s BLOCKED $t\\n' "\$(date -Is)" >> $log_path
exit 127
SHIM
    chmod 700 "$tmp"
    mv -f "$tmp" "$path"
    hash -r
    [ "$(command -v "$t")" = "$path" ] || die "host guard for $t is not first on PATH"
    ok "guarded $t in $bindir"
  done
}
