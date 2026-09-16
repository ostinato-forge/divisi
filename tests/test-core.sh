#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/sub" "$tmp/other" "$tmp/state" "$tmp/shims"
cat > "$tmp/bin/podman" <<'PODMAN'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  inspect)
    if [ "${MOCK_MANAGED:-}" = 1 ]; then
      case "$3" in
        *io.divisi.managed*) echo 1 ;;
        *io.divisi.context*) echo "$4" ;;
        *State.Running*) if [ "${MOCK_EXEC_FAIL:-}" = 1 ]; then echo true; else echo false; fi ;;
      esac
      exit 0
    fi ;;
  exec)
    if [ "${MOCK_EXEC_FAIL:-}" = 1 ]; then
      [ "$3" = true ] && exit 0
      exit 125
    fi ;;
  *) exit 1 ;;
esac
exit 1
PODMAN
chmod +x "$tmp/bin/podman"
export PATH="$tmp/shims:$tmp/bin:$PATH"
export DIVISI_BIN="$tmp/shims"

write_config() {
  cat > "$tmp/divisi.conf" <<CONFIG
DIVISI_STATE="$tmp/state"
DIVISI_GUARD_TOOLS=(fakeagent)
CONTEXTS=(work opensource)
declare -gA CTX_MOUNT CTX_GIT_NAME CTX_GIT_EMAIL CTX_GH CTX_COLOR
declare -gA CTX_CLAUDE_AUTH CTX_VERTEX_PROJECT CTX_VERTEX_REGION CTX_SECRETS CTX_SEED
CTX_MOUNT[work]="$1"
CTX_MOUNT[opensource]="$2"
CONFIG
  export DIVISI_CONFIG="$tmp/divisi.conf"
}

write_config '' ''
if "$root/bin/divisi" check >"$tmp/out" 2>&1; then
  echo 'check passed with no running containers' >&2
  exit 1
fi
rg -q 'context work is missing or not managed' "$tmp/out"
if MOCK_MANAGED=1 "$root/bin/divisi" check >"$tmp/out" 2>&1; then
  echo 'check passed when managed containers could not start' >&2
  exit 1
fi
rg -q 'context work could not start' "$tmp/out"
if MOCK_MANAGED=1 MOCK_EXEC_FAIL=1 "$root/bin/divisi" check >"$tmp/out" 2>&1; then
  echo 'check passed when Podman exec failed during a path test' >&2
  exit 1
fi
rg -q 'could not verify' "$tmp/out"

for second in "$tmp/work" "$tmp/work/sub"; do
  write_config "$tmp/work" "$second"
  if "$root/bin/divisi" status >"$tmp/out" 2>&1; then
    echo 'overlapping mounts passed validation' >&2
    exit 1
  fi
  rg -q 'overlap' "$tmp/out"
done
write_config "$tmp/work" "$tmp/other"
ln -s "$tmp/work" "$tmp/work-alias"
write_config "$tmp/work" "$tmp/work-alias"
if "$root/bin/divisi" status >"$tmp/out" 2>&1; then
  echo 'alias mount passed validation' >&2
  exit 1
fi
write_config "$tmp/work" "$tmp/other"
"$root/bin/divisi" status >"$tmp/out"

mkdir -p "$tmp/home"
export HOME="$tmp/home"
export DIVISI_CONFIG="$tmp/home/divisi.conf"
printf '\n\n%s\nfakeagent\n1\nwork\n\nA "Name"\na@example.com\n\napi_key\nexample-secret-value\n\n' "$tmp/state" \
  | "$root/bin/divisi" init >"$tmp/out" 2>&1
! rg -q 'example-secret-value' "$DIVISI_CONFIG"
[ "$(cat "$tmp/state/work/.secrets/anthropic_api_key")" = 'example-secret-value' ]
bash -n "$DIVISI_CONFIG"

# Accept every suggested context name and check the experiments auth default.
defaults_config="$tmp/home/defaults.conf"
{
  printf '\n\n%s\n' "$tmp/default-state"
  for ((i=0;i<30;i++)); do printf '\n'; done
} | DIVISI_CONFIG="$defaults_config" "$root/bin/divisi" init >"$tmp/out" 2>&1
bash -c 'source "$1"; [ "${CONTEXTS[*]}" = "work opensource experiments" ] && [ "${CTX_CLAUDE_AUTH[experiments]}" = none ]' _ "$defaults_config"

cat > "$tmp/bin/fakeagent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "$*"
AGENT
chmod +x "$tmp/bin/fakeagent"
export DIVISI_STATE="$tmp/state"
# Set the guard array in the Bash process that sources the library.
bash -c 'set -euo pipefail; source "$1/lib/common.sh"; source "$1/lib/enforce.sh"; DIVISI_GUARD_TOOLS=(fakeagent); divisi_enforce' _ "$root" >"$tmp/out"
if "$tmp/shims/fakeagent" private-argument >"$tmp/out" 2>&1; then
  echo 'host guard did not block' >&2
  exit 1
fi
bash -c 'set -euo pipefail; source "$1/lib/common.sh"; source "$1/lib/enforce.sh"; DIVISI_GUARD_TOOLS=(fakeagent); divisi_enforce' _ "$root" >"$tmp/out"
DIVISI_OVERRIDE=1 "$tmp/shims/fakeagent" private-argument >"$tmp/out"
[ "$(cat "$tmp/out")" = 'private-argument' ]
! rg -q 'private-argument' "$tmp/state/host-block.log"
[ "$(stat -c %a "$tmp/state/host-block.log")" = 600 ]

for release in 'fedora 40 yes' 'fedora 43 yes' 'rhel 9.6 yes' 'rhel 10.0 yes' 'fedora 39 no' 'rhel 8.10 no'; do
  read -r os version expected <<< "$release"
  printf 'ID=%s\nVERSION_ID=%s\n' "$os" "$version" > "$tmp/os-release"
  if DIVISI_OS_RELEASE="$tmp/os-release" bash -c 'set -euo pipefail; source "$1/lib/common.sh"; require_supported_os' _ "$root" >"$tmp/out" 2>&1; then
    actual=yes
  else
    actual=no
  fi
  [ "$actual" = "$expected" ] || { echo "host detection mismatch: $release" >&2; exit 1; }
done

echo 'core tests passed'
