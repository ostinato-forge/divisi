# divisi check: verify the walls still hold. Read-only, safe to run anytime.
# Exits non-zero on any breach so it can gate CI or a cron heartbeat.

divisi_check() {
  require_podman
  local ok=true
  _must()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else printf 'FAIL: %s\n' "$d"; ok=false; fi; }
  _mustnot() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf 'FAIL: %s\n' "$d"; ok=false; else ok "$d"; fi; }

  local n; for n in "${CONTEXTS[@]}"; do podman start "$n" >/dev/null 2>&1 || true; done

  # 1. Each context sees its own mount and nothing it shouldn't.
  local a b ma mb
  for a in "${CONTEXTS[@]}"; do
    ma="${CTX_MOUNT[$a]:-}"
    [ -n "$ma" ] && _must "$a sees its mount $ma" podman exec "$a" test -d "$ma"
    _mustnot "$a cannot reach host root /run/host" podman exec "$a" test -e /run/host
    for b in "${CONTEXTS[@]}"; do
      [ "$a" = "$b" ] && continue
      mb="${CTX_MOUNT[$b]:-}"
      [ -n "$mb" ] && [ "$mb" != "$ma" ] && _mustnot "$a cannot see $b's mount $mb" podman exec "$a" test -e "$mb"
    done
  done

  # 2. Git identities are distinct across contexts that declare one.
  local seen=""
  for n in "${CONTEXTS[@]}"; do
    local e; e="$(podman exec "$n" git config user.email 2>/dev/null || true)"
    [ -z "$e" ] && continue
    if printf '%s' "$seen" | grep -qx "$e"; then
      printf 'FAIL: git email %s reused across contexts\n' "$e"; ok=false
    else ok "$n git identity: $e"; seen="$seen"$'\n'"$e"; fi
  done

  # 3. Host guard shims intact for every guarded tool present.
  local t bin
  for t in "${DIVISI_GUARD_TOOLS[@]}"; do
    bin="$(command -v "$t" 2>/dev/null || true)"; [ -z "$bin" ] && continue
    _must "host $t is guard-shimmed" grep -q divisi-guard "$bin"
  done

  $ok && { echo; ok "all walls hold"; return 0; }
  echo; die "WALL BREACH(ES) above"
}
