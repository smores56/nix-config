#!/usr/bin/env bash
# The vault helper must fail closed: refuse a non-vault directory, surface a cryptomator-cli failure
# instead of hanging, and never hand the password to a command line. Both platform halves run
# against fake mount tools.
# Usage: vault.sh <modules/features/vault.sh> <vault-linux.sh> <vault-darwin.sh>
set -euo pipefail

script_src=$1
platform_linux=$2
platform_darwin=$3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

vault="$work/Sync/vault"
mkdir -p "$vault"
: >"$vault/vault.cryptomator"

render() {
  sed -e "s|@VAULT@|$(printf '%q' "$1")|; s|@MOUNTER@|test.mounter|" \
    -e "/@PLATFORM@/{r ${2:-$platform_linux}" -e 'd;}' "$script_src" >"$work/vault"
}

render "$vault"
set +e
out=$(printf 'pw\n' | bash "$work/vault" 2>&1)
status=$?
set -e
[ "$status" -eq 2 ] || fail "usage exit status $status, want 2 (output: $out)"

plain="$work/not-a-vault"
mkdir -p "$plain"
render "$plain"
set +e
out=$(printf 'pw\n' | bash "$work/vault" true 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "non-vault exit status $status, want 1 (output: $out)"
case $out in
  *"not a Cryptomator vault"*) ;;
  *) fail "expected the refusal to name the vault, got: $out" ;;
esac

# No cryptomator-cli on PATH, so this exercises the failure branch: it must surface, not hang.
render "$vault"
set +e
out=$(printf 'pw\n' | timeout 60 bash "$work/vault" true 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "failed unlock exit status $status, want 1 (output: $out)"
case $out in
  *"exited before mounting"*) ;;
  *) fail "expected the unlock failure to be reported, got: $out" ;;
esac

# Fake mount tools: a mount is a line in $state/mounts, so each platform half sees its own
# probe succeed and its own unmount command run.
state="$work/state"
fakes="$work/fakes"
mkdir -p "$state" "$fakes" "$work/tmp"
write_fake() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$fakes/$1"
  chmod +x "$fakes/$1"
}
write_fake cryptomator-cli '
IFS= read -r pw
printf "cli %s\n" "$*" >>"$STATE/log"
[ "$pw" = secret ] || exit 1
for a in "$@"; do case $a in --mountPoint=*) mp=${a#*=} ;; esac; done
printf "%s\n" "$mp" >"$STATE/mounted"
printf "fuse-t:/vault on %s (nfs)\n" "$(cd "$mp" && pwd -P)" >"$STATE/mounts"
while [ -e "$STATE/mounted" ]; do sleep 0.1; done'
write_fake mountpoint '[ -e "$STATE/mounted" ]'
write_fake mount 'cat "$STATE/mounts" 2>/dev/null || true'
write_fake fusermount3 'echo "fusermount3 $*" >>"$STATE/log"
[ "$1" = -uz ] || [ -z "${FAKE_BUSY:-}" ] || exit 1
rm -f "$STATE/mounted" "$STATE/mounts"'
write_fake umount 'echo "umount $*" >>"$STATE/log"
[ -z "${FAKE_BUSY:-}" ] || exit 1
rm -f "$STATE/mounted" "$STATE/mounts"'
write_fake diskutil 'echo "diskutil $*" >>"$STATE/log"
rm -f "$STATE/mounted" "$STATE/mounts"'

run_fake() { # platform half, then extra env
  render "$vault" "$1"
  shift
  : >"$state/log"
  rm -f "$state/mounted" "$state/mounts" "$state/cwd"
  env "$@" STATE="$state" TMPDIR="$work/tmp" PATH="$fakes:$PATH" \
    bash "$work/vault" sh -c 'pwd -P >"$STATE/cwd"; ls "$STATE/mounted" >/dev/null' <<<'secret'
}

expect_log() {
  grep -q -- "$1" "$state/log" || fail "$2: expected '$1' in: $(cat "$state/log")"
}

check_platform() { # name half unmount-cmd force-cmd
  run_fake "$2" FAKE=1 >/dev/null || fail "$1: command did not run through the fake mount"
  [ "$(dirname "$(cat "$state/cwd")")" = "$(cd "$work/tmp" && pwd -P)" ] \
    || fail "$1: command did not run inside the mountpoint"
  expect_log "^$3" "$1 unmount"
  expect_log "--mounter=test.mounter" "$1 mounter"
  [ -z "$(ls -A "$work/tmp")" ] || fail "$1: mountpoint left behind"
  if grep -q secret "$state/log"; then fail "$1: password reached a command line"; fi
  run_fake "$2" FAKE_BUSY=1 >/dev/null || fail "$1: busy unmount must still clean up"
  expect_log "^$4" "$1 forced unmount"
  [ -z "$(ls -A "$work/tmp")" ] || fail "$1: busy mountpoint left behind"
}

check_platform linux "$platform_linux" 'fusermount3 -u ' 'fusermount3 -uz '
check_platform darwin "$platform_darwin" 'umount ' 'diskutil unmount force '
if grep -q 'fusermount3\|mountpoint' "$platform_darwin"; then fail "darwin half must not use Linux tools"; fi

grep -q -- '--password:stdin' "$script_src" || fail "password must be passed on stdin"
grep -q -- '"$pass" | cryptomator-cli' "$script_src" || fail "the password must be piped into cryptomator-cli"
if grep -q -- '--password ' "$script_src"; then
  fail "the password must never be an argument"
fi

echo "ok"
