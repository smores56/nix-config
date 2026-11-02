#!/usr/bin/env bash
# The gh wrapper and the git credential helper pick an owner-scoped PAT from
# the same sops files on every platform (sops-nix /run/secrets on NixOS,
# home-manager sops on Darwin), never from Keychain. A missing token makes gh
# fail closed with the owner named, and the helper stay silent so git can fall
# through to the next helper.
#
# Usage: github_pat_routing.sh <gh-pat> <github-credential-helper>
#          <personal-pat-file> <work-pat-file>, with PERSONAL_OWNER and WORK_OWNER.
set -euo pipefail

gh_pat=$1
helper=$2
personal_pat=$3
work_pat=$4
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

for script in "$gh_pat" "$helper"; do
  name=$(basename "$script")
  grep -qF -- "$personal_pat" "$script" || fail "$name does not read $personal_pat"
  grep -qF -- "$work_pat" "$script" || fail "$name does not read $work_pat"
  if grep -qF -- 'find-generic-password' "$script"; then
    fail "$name still reads Keychain"
  fi
done

# The build sandbox cannot read the real token files; when it can (a run
# outside the sandbox), the missing-token cases below do not apply.
if [ -r "$personal_pat" ] || [ -r "$work_pat" ]; then
  echo "token files readable here; skipping missing-token cases"
else
  for owner in "$PERSONAL_OWNER" "$WORK_OWNER"; do
    repo="$work/$owner"
    git init -q "$repo"
    git -C "$repo" remote add origin "https://github.com/$owner/routing.git"
    status=0
    err=$(cd "$repo" && env -u GH_TOKEN "$gh_pat" --version 2>&1 >/dev/null) || status=$?
    [ "$status" -eq 1 ] || fail "gh-pat for $owner exited $status, want 1"
    [ "$err" = "gh: no token for owner '$owner'" ] || fail "gh-pat for $owner said: $err"

    out=$(printf 'protocol=https\nhost=github.com\npath=%s/routing.git\n\n' "$owner" | "$helper" get) ||
      fail "helper for $owner exited non-zero"
    [ -z "$out" ] || fail "helper for $owner answered without a token file"
  done
fi

out=$(printf 'protocol=https\nhost=example.com\npath=%s/routing.git\n\n' "$PERSONAL_OWNER" | "$helper" get) ||
  fail "helper for a non-GitHub host exited non-zero"
[ -z "$out" ] || fail "helper answered for a non-GitHub host"

[ "$failures" -eq 0 ] || exit 1
echo "github-pat-routing: ok"
