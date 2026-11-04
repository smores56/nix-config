#!/usr/bin/env bash
# Each account's sops signing key is trusted for its own principal only; no retired key keeps trust.
#
# Usage: ssh_allowed_signers.sh <writer>, with WORK_EMAIL, PERSONAL_EMAIL,
# PERSONAL_SIGNING_PUB and WORK_SIGNING_PUB.
set -euo pipefail

writer=$1
export HOME=$PWD/home
mkdir -p "$HOME/.config/ssh"
signers=$HOME/.config/ssh/allowed_signers
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

has_entry() {
  grep -qxF "$1 namespaces=\"git\" $2" "$signers"
}

"$writer"

has_entry "$PERSONAL_EMAIL" "$PERSONAL_SIGNING_PUB" || fail "personal signing key not trusted as $PERSONAL_EMAIL"
has_entry "$WORK_EMAIL" "$WORK_SIGNING_PUB" || fail "work signing key not trusted as $WORK_EMAIL"
has_entry "$WORK_EMAIL" "$PERSONAL_SIGNING_PUB" && fail "personal signing key trusted as $WORK_EMAIL"
has_entry "$PERSONAL_EMAIL" "$WORK_SIGNING_PUB" && fail "work signing key trusted as $PERSONAL_EMAIL"

[ "$(grep -c . "$signers")" = 2 ] || fail "allowed_signers trusts more than the two account keys"

# Every line parses: a broken quote or key would silently drop trust.
while read -r principal options type body; do
  printf '%s %s\n' "$type" "$body" | ssh-keygen -l -f - >/dev/null 2>&1 || fail "unparsable key for $principal"
done <"$signers"

if ((failures)); then
  echo "$failures allowed_signers expectation(s) failed"
  exit 1
fi
echo "ssh-allowed-signers ok"
