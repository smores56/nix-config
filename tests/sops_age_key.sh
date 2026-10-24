#!/usr/bin/env bash
# The admin-key wrapper must hand sops an identity only when the
# passphrase-wrapped file is present, and must refuse when a retired plaintext
# identity would shadow it (sops loads that default even with KEY_CMD set).
set -euo pipefail

wrapper=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# No keys.age: fail closed, and name the path that must be provisioned.
mkdir -p "$tmp/empty"
if HOME="$tmp/empty" "$wrapper" >/dev/null 2>"$tmp/err"; then
  fail "wrapper accepted a missing keys.age"
fi
grep -q "keys.age is missing or unreadable" "$tmp/err" ||
  fail "unexpected message: $(cat "$tmp/err")"

# Leftover plaintext identity: refuse even though keys.age exists.
mkdir -p "$tmp/legacy/.config/sops/age"
printf 'stub\n' >"$tmp/legacy/.config/sops/keys.age"
printf 'AGE-SECRET-KEY-1STUB\n' >"$tmp/legacy/.config/sops/age/keys.txt"
if HOME="$tmp/legacy" "$wrapper" >/dev/null 2>"$tmp/err"; then
  fail "wrapper accepted a leftover keys.txt"
fi
grep -q "remove the retired plaintext identity" "$tmp/err" ||
  fail "unexpected message: $(cat "$tmp/err")"

# sops resolves ~/.config through XDG_CONFIG_HOME, so the guard must too.
mkdir -p "$tmp/xdg/sops"
printf 'stub\n' >"$tmp/xdg/sops/keys.age"
if HOME="$tmp/empty" XDG_CONFIG_HOME="$tmp/xdg" "$wrapper" >/dev/null 2>"$tmp/err"; then
  fail "wrapper ignored XDG_CONFIG_HOME"
fi
grep -q "keys.age is missing or unreadable" "$tmp/err" &&
  fail "guard looked at the wrong path"

echo "sops-age-key guards ok"
