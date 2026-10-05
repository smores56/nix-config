#!/usr/bin/env bash
# Runs the generated allowed_signers writer against scratch keys, then checks
# ssh signatures verify for the right principal only, and that a host without
# the work key still gets the personal entry.
#
# Usage: ssh_allowed_signers.sh <writer>, with PERSONAL_EMAIL and WORK_EMAIL.
set -euo pipefail

writer=$1
export HOME=$PWD/home
mkdir -p "$HOME/.ssh"
for key in id_personal id_work; do
  ssh-keygen -q -t ed25519 -N "" -C "$key" -f "$HOME/.ssh/$key"
done
signers=$HOME/.ssh/allowed_signers
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

verifies() {
  local key=$1 principal=$2
  echo payload >msg
  rm -f msg.sig
  ssh-keygen -q -Y sign -f "$HOME/.ssh/$key" -n git msg
  ssh-keygen -q -Y verify -f "$signers" -I "$principal" -n git -s msg.sig <msg >/dev/null 2>&1
}

"$writer"
verifies id_personal "$PERSONAL_EMAIL" || fail "personal key does not verify as $PERSONAL_EMAIL"
verifies id_work "$WORK_EMAIL" || fail "work key does not verify as $WORK_EMAIL"
verifies id_work "$PERSONAL_EMAIL" && fail "work key verifies as $PERSONAL_EMAIL"
verifies id_personal "$WORK_EMAIL" && fail "personal key verifies as $WORK_EMAIL"

# A hand-pasted .pub often lacks the trailing newline.
printf '%s' "$(cat "$HOME/.ssh/id_work.pub")" >"$HOME/.ssh/id_work.pub.tmp"
mv "$HOME/.ssh/id_work.pub.tmp" "$HOME/.ssh/id_work.pub"
"$writer" || fail "writer failed on a .pub without a trailing newline"
verifies id_work "$WORK_EMAIL" || fail "work key without trailing newline does not verify"

rm "$HOME/.ssh/id_work.pub"
"$writer"
verifies id_personal "$PERSONAL_EMAIL" || fail "personal entry lost without the work key"
[[ $(grep -c . "$signers") == 1 ]] || fail "expected one entry without the work key"

if ((failures)); then
  echo "$failures allowed_signers expectation(s) failed"
  exit 1
fi
echo "ssh allowed signers: ok"
