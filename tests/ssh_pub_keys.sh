#!/usr/bin/env bash
# The public keys are committed in Nix now: the work software identity is
# written, parses with ssh-keygen, and allowed_signers trusts its principal. A
# stale file is replaced, a rerun is idempotent, and there is no vault/pass-cli
# dependency. The retired personal software key must not be written.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>, with WORK_KEY and WORK_EMAIL.
set -euo pipefail

script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

dest() {
  printf '%s/%s.pub' "$work" "${1#\~/}"
}

# A stale/invalid file must be replaced, not kept.
mkdir -p "$work/.config/ssh"
printf 'ssh-ed25519 AAAAstale stale\n' >"$(dest "$WORK_KEY")"

HOME="$work" "$script" || fail "script exited non-zero"

file=$(dest "$WORK_KEY")
if [ "${WORK_HOST:-0}" = 1 ]; then
  [ -s "$file" ] || fail "missing $file"
  ssh-keygen -l -f "$file" >/dev/null 2>&1 || fail "unparsable $file"
  grep -q "$WORK_EMAIL namespaces=\"git\" ssh-ed25519 " "$work/.config/ssh/allowed_signers" ||
    fail "allowed_signers lacks the $WORK_EMAIL principal"
else
  # Non-work hosts have no work private key; do not stage or trust it.
  [ ! -e "$file" ] || fail "work public key written on a non-work host"
  ! grep -q "$WORK_EMAIL namespaces=\"git\" ssh-ed25519 " "$work/.config/ssh/allowed_signers" ||
    fail "allowed_signers trusts the work software key on a non-work host"
fi
[ ! -e "$work/.config/ssh/id_personal.pub" ] || fail "the retired personal key was written"

# Idempotent: a second run produces identical files.
before=$(sha256sum "$work/.config/ssh/allowed_signers"; if [ -f "$file" ]; then sha256sum "$file"; fi)
HOME="$work" "$script" >/dev/null 2>&1 || fail "second run exited non-zero"
after=$(sha256sum "$work/.config/ssh/allowed_signers"; if [ -f "$file" ]; then sha256sum "$file"; fi)
[ "$before" = "$after" ] || fail "second run changed the files"

if (($failures)); then
  exit 1
fi
echo "ssh-pub-keys ok"
