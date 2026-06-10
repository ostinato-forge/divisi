# divisi audit: scan the host for the things that leak when you run agents.
# Read-only. Prints paths/metadata and counts, never secret values. Works
# with or without a divisi config (the posture checks need one).

divisi_audit() {
  local H="$HOME"
  echo "== divisi audit :: $(hostname) :: $(date -Is) =="

  echo; echo "-- standing credential files (paths/perms/mtime, not contents) --"
  local f
  for f in "$H"/.aws/credentials "$H"/.kube/config "$H"/.docker/config.json \
           "$H"/.netrc "$H"/.pgpass "$H"/.boto "$H"/.npmrc "$H"/.pypirc \
           "$H"/.git-credentials "$H"/.config/rclone/rclone.conf "$H"/.m2/settings.xml \
           "$H"/.config/gh/hosts.yml "$H"/.config/gcloud/application_default_credentials.json \
           "$H"/.config/containers/auth.json; do
    [ -e "$f" ] && printf '   %s  %s  %s\n' "$(stat -c '%A' "$f")" "$(stat -c %y "$f" | cut -d. -f1)" "$f"
  done

  echo; echo "-- secrets exported in shell init (values redacted) --"
  rg -n --no-heading -i 'export +[A-Z_]*(TOKEN|SECRET|KEY|PASSWORD|PASSWD|API)[A-Z_]*=' \
     "$H"/.bashrc "$H"/.bash_profile "$H"/.profile "$H"/.zshrc 2>/dev/null \
     | sed -E 's/=.*/=<redacted>/' || echo "   none"

  echo; echo "-- HOME accidentally a git repo? --"
  if [ -d "$H/.git" ]; then
    printf '   yes: %s tracked files (an accidental \047git init\047 in HOME is a footgun)\n' \
      "$(git --git-dir="$H/.git" --work-tree="$H" ls-files 2>/dev/null | wc -l)"
  else echo "   no"; fi

  echo; echo "-- ssh private keys without a passphrase --"
  local k any=0
  for k in "$H"/.ssh/*; do
    [ -f "$k" ] || continue; case "$k" in *.pub) continue;; esac
    grep -qsI 'PRIVATE KEY' "$k" || continue
    if ssh-keygen -y -P '' -f "$k" >/dev/null 2>&1; then printf '   NO-PASSPHRASE  %s\n' "$k"; any=1; fi
  done
  [ "$any" = 0 ] && echo "   none (or all encrypted)"

  echo; echo "-- gpg secret keys present --"
  gpg --list-secret-keys 2>/dev/null | grep -c '^sec' | sed 's/^/   secret keys: /'

  echo; echo "-- shell history lines that look like secrets --"
  for f in "$H"/.bash_history "$H"/.zsh_history "$H"/.python_history; do
    [ -e "$f" ] || continue
    printf '   %-28s %s secret-ish of %s lines\n' "$(basename "$f")" \
      "$(rg -ci 'token|secret|password|api[_-]?key|sk-|gho_|glpat|nvapi' "$f" 2>/dev/null || echo 0)" \
      "$(wc -l < "$f")"
  done

  echo; echo "-- high-entropy tokens loose under ~/.config (paths only) --"
  rg -l -i --no-messages -g '!**/node_modules/**' -g '!**/Cache/**' -g '!**/google-chrome/**' \
     -g '!**/chromium/**' -g '!**/Code/**' -g '!**/Cursor/**' \
     'nvapi-|sk-[A-Za-z0-9]{20}|gho_[A-Za-z0-9]{36}|glpat-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----' \
     "$H"/.config "$H"/.npmrc "$H"/.netrc 2>/dev/null | head -20 || echo "   none"

  echo; echo "-- services listening on all interfaces (0.0.0.0 / ::) --"
  ss -tlnH 2>/dev/null | awk '$4 ~ /0\.0\.0\.0:|\[::\]:|\*:/ {print "   "$4"  "$6}' | sort -u | head -25

  echo; echo "-- world-writable files in HOME (depth 2, caches excluded) --"
  find "$H" -maxdepth 2 -type f -perm -o+w 2>/dev/null \
    | grep -vE '/\.(cache|local/share|mozilla|config/(Code|Cursor|google-chrome)|cursor|vscode|ollama|continue)/' | head -15 \
    || echo "   none"

  echo; echo "-- scheduled execution --"
  printf '   crontab: %s\n' "$(crontab -l 2>/dev/null | grep -cvE '^\s*#|^\s*$' || echo 0) entries"
  printf '   enabled user timers: %s\n' "$(systemctl --user list-timers --all --no-legend 2>/dev/null | grep -c . || echo 0)"
  printf '   autostart entries: %s\n' "$(ls "$H"/.config/autostart/ 2>/dev/null | wc -l)"

  echo; echo "-- firewall --"
  if command -v firewall-cmd >/dev/null; then
    printf '   firewalld: %s (rules need: sudo firewall-cmd --list-all)\n' "$(systemctl is-active firewalld 2>/dev/null)"
  elif command -v ufw >/dev/null; then ufw status 2>/dev/null | head -1 | sed 's/^/   /'
  else echo "   no firewalld/ufw detected"; fi

  # divisi posture (only if configured)
  if [ -f "$(divisi_config_path)" ]; then
    echo; echo "-- divisi posture --"
    load_config 2>/dev/null || true
    local t bin
    for t in "${DIVISI_GUARD_TOOLS[@]}"; do
      bin="$(command -v "$t" 2>/dev/null || true)"; [ -z "$bin" ] && continue
      if grep -q divisi-guard "$bin" 2>/dev/null; then echo "   $t: shimmed on host (good)"; else echo "   $t: NOT shimmed - runs free on host"; fi
    done
    command -v gh >/dev/null && { gh auth status >/dev/null 2>&1 && echo "   gh: still logged in on host (should be logged out)" || echo "   gh: logged out on host (good)"; }
  fi

  echo; echo "== audit complete. Findings are leads, not verdicts; rotate anything real. =="
}
