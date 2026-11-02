#!/usr/bin/env bash
# Runs the generated allowed_signers writer: each account's sops signing key is
# trusted for its own principal only, nothing else is (no retired key keeps any
# trust), and a stray software key verifies for nobody.
#
# Usage: ssh_allowed_signers.sh <writer>, with WORK_EMAIL, PERSONAL_EMAIL,
# PERSONAL_SIGNING_PUB and WORK_SIGNING_PUB.
set -euo pipefail

writer=$1
export HOME=$PWD/home
mkdir -p "$HOME/.config/ssh"
ssh-keygen -q -t ed25519 -N "" -C id_personal -f "$HOME/.config/ssh/id_personal"
signers=$HOME/.config/ssh/allowed_signers
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

has_entry() {
  grep -qxF "$1 namespaces=\"git\" $2" "$signers"
}

verifies() {
  local key=$1 principal=$2
  echo payload >msg
  rm -f msg.sig
  ssh-keygen -q -Y sign -f "$HOME/.config/ssh/$key" -n git msg
  ssh-keygen -q -Y verify -f "$signers" -I "$principal" -n git -s msg.sig <msg >/dev/null 2>&1
}

"$writer"

has_entry "$PERSONAL_EMAIL" "$PERSONAL_SIGNING_PUB" || fail "personal signing key not trusted as $PERSONAL_EMAIL"
has_entry "$WORK_EMAIL" "$WORK_SIGNING_PUB" || fail "work signing key not trusted as $WORK_EMAIL"
has_entry "$WORK_EMAIL" "$PERSONAL_SIGNING_PUB" && fail "personal signing key trusted as $WORK_EMAIL"
has_entry "$PERSONAL_EMAIL" "$WORK_SIGNING_PUB" && fail "work signing key trusted as $PERSONAL_EMAIL"

# With no YubiKey public halves on disk, the two sops keys are the whole list.
[ "$(grep -c . "$signers")" = 2 ] || fail "allowed_signers trusts more than the two account keys"

verifies id_personal "$PERSONAL_EMAIL" && fail "retired personal key verifies as $PERSONAL_EMAIL"
verifies id_personal "$WORK_EMAIL" && fail "retired personal key verifies as $WORK_EMAIL"

# Every line parses: a broken quote or key would silently drop trust.
while read -r principal options type body; do
  printf '%s %s\n' "$type" "$body" | ssh-keygen -l -f - >/dev/null 2>&1 || fail "unparsable key for $principal"
done <"$signers"

if ((failures)); then
  echo "$failures allowed_signers expectation(s) failed"
  exit 1
fi
echo "ssh-allowed-signers ok"
