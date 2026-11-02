#!/usr/bin/env bash
# The public keys are committed in Nix: no software SSH identity is written
# any more, a retired key's stale file is removed, a rerun is idempotent, and
# the retired personal software key is never written.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>.
set -euo pipefail

script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

# The employer SSH key is retired on every host: a stale public half is
# removed, never rewritten, and allowed_signers no longer trusts it.
mkdir -p "$work/.config/ssh"
file="$work/.config/ssh/id_work.pub"
printf 'ssh-ed25519 AAAAstale stale\n' >"$file"

HOME="$work" "$script" || fail "script exited non-zero"

[ ! -e "$file" ] || fail "retired work public key still present"
grep -q 'valid-before' "$work/.config/ssh/allowed_signers" && fail "allowed_signers keeps a retired key"
[ ! -e "$work/.config/ssh/id_personal.pub" ] || fail "the retired personal key was written"

# Idempotent: a second run produces identical files.
before=$(sha256sum "$work/.config/ssh/allowed_signers")
HOME="$work" "$script" >/dev/null 2>&1 || fail "second run exited non-zero"
after=$(sha256sum "$work/.config/ssh/allowed_signers")
[ "$before" = "$after" ] || fail "second run changed the files"

if (($failures)); then
  exit 1
fi
echo "ssh-pub-keys ok"
