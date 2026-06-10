# divisi enforce: make agent CLIs refuse to run on the host, so an agent
# can never be started outside a context by habit or typo. Idempotent.
#
# Real launchers are quarantined under $DIVISI_STATE/host-tools. A shim takes
# their place on $PATH: it blocks, logs to $DIVISI_STATE/host-block.log, and
# allows a deliberate, audited override via DIVISI_OVERRIDE=1.

divisi_enforce() {
  local quarantine="$DIVISI_STATE/host-tools"
  local log="$DIVISI_STATE/host-block.log"
  mkdir -p "$quarantine"
  local names
  names="$(printf '%s | ' "${DIVISI_GUARD_TOOLS[@]}")"
  names="${names% | }"

  local t bin real
  for t in "${DIVISI_GUARD_TOOLS[@]}"; do
    bin="$(command -v "$t" 2>/dev/null || true)"
    if [ -z "$bin" ]; then info "skip $t (not on host PATH)"; continue; fi
    if grep -q divisi-guard "$bin" 2>/dev/null; then ok "$t already shimmed"; continue; fi

    real="$(readlink -f "$bin")"
    if [ "$real" = "$bin" ]; then
      mv "$bin" "$quarantine/$t"            # real binary sat at the PATH location
    else
      ln -sfn "$real" "$quarantine/$t"      # PATH entry was a symlink
      rm -f "$bin"                          # remove before writing, or we clobber the target
    fi

    cat > "$bin" <<SHIM
#!/usr/bin/env bash
# divisi-guard shim (managed by 'divisi enforce')
if [ "\${DIVISI_OVERRIDE:-}" = "1" ]; then
  printf '%s OVERRIDE $t %s\n' "\$(date -Is)" "\$*" >> "$log"
  exec "$quarantine/$t" "\$@"
fi
{
  echo "BLOCKED: $t runs inside a divisi context ($names), not on the host."
  echo "  enter one:  divisi enter <name>"
  echo "  deliberate host run:  DIVISI_OVERRIDE=1 $t ..."
} >&2
printf '%s BLOCKED $t %s\n' "\$(date -Is)" "\$*" >> "$log"
exit 127
SHIM
    chmod +x "$bin"
    ok "shimmed $t (real -> $quarantine/$t)"
  done
}
