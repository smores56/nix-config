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
mkdir -p "$work/.ssh"
printf 'ssh-ed25519 AAAAstale stale\n' >"$(dest "$WORK_KEY")"

HOME="$work" "$script" || fail "script exited non-zero"

file=$(dest "$WORK_KEY")
[ -s "$file" ] || fail "missing $file"
ssh-keygen -l -f "$file" >/dev/null 2>&1 || fail "unparsable $file"
grep -q "$WORK_EMAIL namespaces=\"git\" ssh-ed25519 " "$work/.ssh/allowed_signers" ||
  fail "allowed_signers lacks the $WORK_EMAIL principal"
[ ! -e "$work/.ssh/id_personal.pub" ] || fail "the retired personal key was written"

# Idempotent: a second run produces identical files.
before=$(sha256sum "$file" "$work/.ssh/allowed_signers")
HOME="$work" "$script" >/dev/null 2>&1 || fail "second run exited non-zero"
after=$(sha256sum "$file" "$work/.ssh/allowed_signers")
[ "$before" = "$after" ] || fail "second run changed the files"

if (($failures)); then
  exit 1
fi
echo "ssh-pub-keys ok"
