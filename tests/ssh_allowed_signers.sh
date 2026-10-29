#!/usr/bin/env bash
# Runs the generated allowed_signers writer against scratch keys: the work
# software identity verifies for its own principal only, the retired personal
# key verifies for nobody, and a missing work key leaves no software entries.
#
# Usage: ssh_allowed_signers.sh <writer>, with WORK_EMAIL.
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
verifies id_work "$WORK_EMAIL" || fail "work key does not verify as $WORK_EMAIL"
verifies id_personal "$WORK_EMAIL" && fail "retired personal key still verifies as $WORK_EMAIL"
verifies id_work "sam@sammohr.dev" && fail "work key verifies as the personal principal"
verifies id_personal "sam@sammohr.dev" && fail "retired personal key still verifies"

# A hand-pasted .pub often lacks the trailing newline.
printf '%s' "$(cat "$HOME/.ssh/id_work.pub")" >"$HOME/.ssh/id_work.pub.tmp"
mv "$HOME/.ssh/id_work.pub.tmp" "$HOME/.ssh/id_work.pub"
"$writer" || fail "writer failed on a .pub without a trailing newline"
verifies id_work "$WORK_EMAIL" || fail "work key without trailing newline does not verify"

rm "$HOME/.ssh/id_work.pub"
"$writer"
verifies id_work "$WORK_EMAIL" && fail "work key still verifies without its .pub"
[[ $(grep -c . "$signers" || true) == 0 ]] || fail "expected no software entries without the work key"

if ((failures)); then
  echo "$failures allowed_signers expectation(s) failed"
  exit 1
fi
echo "ssh-allowed-signers ok"
