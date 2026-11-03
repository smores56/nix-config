#!/usr/bin/env bash
# The vault helper must fail closed: usage without a command, refuse a directory
# that is not a vault, surface a cryptomator-cli failure instead of hanging, and
# never hand the password to a command line.
# Usage: vault.sh <modules/features/vault.sh>
set -euo pipefail

script_src=$1
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
  sed "s|@VAULT@|$(printf '%q' "$1")|; s|@MOUNTER@|test.mounter|" "$script_src" >"$work/vault"
}

# 1. No command is a usage error.
render "$vault"
set +e
out=$(printf 'pw\n' | bash "$work/vault" 2>&1)
status=$?
set -e
[ "$status" -eq 2 ] || fail "usage exit status $status, want 2 (output: $out)"

# 2. A directory that is not a vault is refused.
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

# 3. A cryptomator-cli that cannot start must surface, not hang. No cryptomator-cli
#    is on PATH here, so this exercises exactly the failure branch.
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

# 4. The password travels on stdin, never on a command line.
grep -q -- '--password:stdin' "$script_src" || fail "password must be passed on stdin"
grep -q -- '"$pass" | cryptomator-cli' "$script_src" || fail "the password must be piped into cryptomator-cli"
if grep -q -- '--password ' "$script_src"; then
  fail "the password must never be an argument"
fi

echo "ok"
