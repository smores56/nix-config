#!/usr/bin/env bash
# The public keys are committed in Nix now: both identities are written, parse
# with ssh-keygen, and allowed_signers trusts both principals. A stale file is
# replaced, a rerun is idempotent, and there is no vault/pass-cli dependency.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>, with PERSONAL_KEY, WORK_KEY,
# PERSONAL_EMAIL and WORK_EMAIL.
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
printf 'ssh-ed25519 AAAAstale stale\n' >"$(dest "$PERSONAL_KEY")"

HOME="$work" "$script" || fail "script exited non-zero"

for pair in "$PERSONAL_KEY:$PERSONAL_EMAIL" "$WORK_KEY:$WORK_EMAIL"; do
  key=${pair%%:*}
  email=${pair#*:}
  file=$(dest "$key")
  [ -s "$file" ] || fail "missing $file"
  ssh-keygen -l -f "$file" >/dev/null 2>&1 || fail "unparsable $file"
  grep -q "$email namespaces=\"git\" ssh-ed25519 " "$work/.ssh/allowed_signers" ||
    fail "allowed_signers lacks the $email principal"
done

# Idempotent: a second run produces identical files.
before=$(sha256sum "$(dest "$PERSONAL_KEY")" "$(dest "$WORK_KEY")" "$work/.ssh/allowed_signers")
HOME="$work" "$script" >/dev/null 2>&1 || fail "second run exited non-zero"
after=$(sha256sum "$(dest "$PERSONAL_KEY")" "$(dest "$WORK_KEY")" "$work/.ssh/allowed_signers")
[ "$before" = "$after" ] || fail "second run changed the files"

if (($failures)); then
  exit 1
fi
echo "ssh-pub-keys ok"
