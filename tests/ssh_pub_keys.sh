#!/usr/bin/env bash
# The public keys are committed in Nix: no software SSH identity is written
# any more, a retired key's stale file is removed, a rerun is idempotent, and
# the retired personal software key is never written.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>, with WORK_EMAIL and WORK_SIGNING_PUB.
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
# PIV public halves are still written (ssh's IdentityFile names them), but no
# YubiKey key is trusted for git: allowed_signers is exactly the two account
# keys. Nothing can create a FIDO2 signing.pub, so asserting its absence here
# could only fail on a hand-edit; `yubikey-lists` asserts the derivation's input
# list (keys.piv) instead.
[ -s "$work/.config/ssh-sk/piv-k1.pub" ] || fail "PIV public key not written"
[ "$(grep -c . "$work/.config/ssh/allowed_signers")" = 2 ] || fail "allowed_signers trusts more than the two account keys"

# The work email's only software (plain ed25519) key is the sops work key.
work_soft=$(grep -F "$WORK_EMAIL namespaces=\"git\" ssh-ed25519 " "$work/.config/ssh/allowed_signers" | cut -d' ' -f3,4 || true)
[ "$work_soft" = "$WORK_SIGNING_PUB" ] || fail "work email trusts software keys other than the sops work key: $work_soft"
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
