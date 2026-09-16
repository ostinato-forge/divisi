# divisi check: verify the walls still hold. Read-only, safe to run anytime.
# Exits non-zero on any breach so it can gate CI or a cron heartbeat.

divisi_check() {
  require_podman
  local ok=true
  _must()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else printf 'FAIL: %s\n' "$d"; ok=false; fi; }
  _path_exists() {
    local result
    result="$(podman exec "$1" bash -c 'if [ -e "$1" ]; then printf exists; else printf absent; fi' bash "$2")" || return 2
    case "$result" in exists) return 0 ;; absent) return 1 ;; *) return 2 ;; esac
  }
  _mustnot() {
    local d="$1" result=0
    shift
    "$@" >/dev/null 2>&1 || result=$?
    case "$result" in
      0) printf 'FAIL: %s\n' "$d"; ok=false ;;
      1) ok "$d" ;;
      *) printf 'FAIL: could not verify %s (command exit %s)\n' "$d" "$result"; ok=false ;;
    esac
  }

  local n
  local -A live=()
  for n in "${CONTEXTS[@]}"; do
    if ! ctx_managed "$n"; then
      printf 'FAIL: context %s is missing or not managed by divisi\n' "$n"
      ok=false
      continue
    fi
    if ! ctx_running "$n" && ! podman start "$n" >/dev/null 2>&1; then
      printf 'FAIL: context %s could not start\n' "$n"
      ok=false
      continue
    fi
    if ! podman exec "$n" true >/dev/null 2>&1; then
      printf 'FAIL: context %s cannot run commands\n' "$n"
      ok=false
      continue
    fi
    live[$n]=1
  done

  # 1. Each context sees its own mount and nothing it shouldn't.
  local a b ma mb
  for a in "${CONTEXTS[@]}"; do
    [ -n "${live[$a]:-}" ] || continue
    ma="${CTX_MOUNT[$a]:-}"
    [ -n "$ma" ] && _must "$a sees its mount $ma" _path_exists "$a" "$ma"
    _mustnot "$a cannot reach host root /run/host" _path_exists "$a" /run/host
    for b in "${CONTEXTS[@]}"; do
      [ "$a" = "$b" ] && continue
      mb="${CTX_MOUNT[$b]:-}"
      [ -n "$mb" ] && [ "$mb" != "$ma" ] && _mustnot "$a cannot see $b's mount $mb" _path_exists "$a" "$mb"
    done
  done

  # 2. Git identities are distinct across contexts that declare one.
  local seen=""
  for n in "${CONTEXTS[@]}"; do
    [ -n "${live[$n]:-}" ] || continue
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
