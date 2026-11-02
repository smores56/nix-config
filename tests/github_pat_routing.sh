#!/usr/bin/env bash
# Each GitHub account's PAT is chosen by the owner of the repository a command
# targets, never by the directory it runs in, and from the same sops files on
# every platform:
# - github-token-file maps an owner to its PAT file (work only for the exact
#   work owners, case-insensitively) and refuses an owner that is not a GitHub
#   name;
# - the git credential helper answers only https://github.com, takes the owner
#   from the request path, refuses dot segments, and stops git with quit=1
#   instead of a password prompt when there is no token;
# - the gh wrapper takes the owner from -R/--repo, GH_REPO, GitHub URLs,
#   `repo <verb> owner/name` and `api repos/owner/...` before the cwd's origin,
#   and fails closed naming the owner when there is no token.
#
# Usage: github_pat_routing.sh <github-token-file> <gh-pat>
#          <github-credential-helper> <personal-pat-file> <work-pat-file>,
#        with PERSONAL_OWNER, WORK_OWNER, WORK_OWNER_2 and LOOKALIKE_WORK_OWNER.
set -euo pipefail

token_file=$1
gh_pat=$2
helper=$3
personal_pat=$4
work_pat=$5
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

for script in "$token_file" "$gh_pat" "$helper"; do
  if grep -qF -- 'find-generic-password' "$script"; then
    fail "$(basename "$script") still reads Keychain"
  fi
done

# Owner -> PAT file.
want() {
  local owner=$1 expected=$2 got
  got=$("$token_file" "$owner") || { fail "github-token-file refused '$owner'"; return; }
  [ "$got" = "$expected" ] || fail "github-token-file '$owner': want $expected, got $got"
}
want "$PERSONAL_OWNER" "$personal_pat"
want "$WORK_OWNER" "$work_pat"
want "$WORK_OWNER_2" "$work_pat"
want "${WORK_OWNER_2^^}" "$work_pat"
want "$LOOKALIKE_WORK_OWNER" "$personal_pat"
want NixOS "$personal_pat"
for bad in "" .. . "-lead" "a/b" "a b" "$WORK_OWNER*"; do
  if "$token_file" "$bad" >/dev/null 2>&1; then
    fail "github-token-file accepted '$bad'"
  fi
done

# The build sandbox cannot read the real token files; when it can (a run
# outside the sandbox), the missing-token cases below do not apply.
if [ -r "$personal_pat" ] || [ -r "$work_pat" ]; then
  echo "token files readable here; skipping missing-token cases"
else
  ask() {
    printf '%s\n' "$@" "" | "$helper" get 2>"$work/helper.err"
  }

  for owner in "$PERSONAL_OWNER" "$WORK_OWNER"; do
    out=$(ask protocol=https host=github.com "path=$owner/routing.git") || fail "helper exited non-zero for $owner"
    [ "$out" = quit=1 ] || fail "helper without a token for $owner said: $out"
    grep -qF "'$owner'" "$work/helper.err" || fail "helper did not name owner $owner"
  done

  # Requests the helper must decline outright: they are not GitHub over HTTPS.
  out=$(ask protocol=http host=github.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for http"
  [ -z "$out" ] || fail "helper answered a plain-http request"
  out=$(ask protocol=https host=example.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for a non-GitHub host"
  [ -z "$out" ] || fail "helper answered a non-GitHub host"

  # Requests aimed at GitHub whose owner cannot be trusted stop git cold.
  out=$(ask protocol=https host=GitHub.com "path=$WORK_OWNER/x.git")
  [ "$out" = quit=1 ] || fail "helper mishandled an upper-case host: $out"
  for path in "/$WORK_OWNER/x.git" "$WORK_OWNER/../$PERSONAL_OWNER/x.git" "$WORK_OWNER/./x" ""; do
    out=$(ask protocol=https host=github.com "path=$path")
    [ "$out" = quit=1 ] || fail "helper answered suspicious path '$path': $out"
  done

  # gh: which owner did the wrapper resolve? With no token it says.
  repo="$work/personal-checkout"
  git init -q "$repo"
  git -C "$repo" remote add origin "https://github.com/$PERSONAL_OWNER/notes.git"
  gh_owner() {
    local status=0 err
    err=$(cd "$repo" && env -u GH_TOKEN "$@" 2>&1 >/dev/null) || status=$?
    [ "$status" -eq 1 ] || { echo "<exit $status>"; return; }
    printf '%s' "$err" | sed -n "s/^gh: no token for owner '\\(.*\\)'$/\\1/p"
  }
  check_gh() {
    local expected=$1 got
    shift
    got=$(gh_owner "$@")
    [ "$got" = "$expected" ] || fail "gh $* resolved '$got', want '$expected'"
  }
  check_gh "$PERSONAL_OWNER" "$gh_pat" pr list
  check_gh "$WORK_OWNER" "$gh_pat" -R "$WORK_OWNER/svc" pr list
  check_gh "$WORK_OWNER_2" "$gh_pat" pr list --repo "$WORK_OWNER_2/svc"
  check_gh "$WORK_OWNER_2" "$gh_pat" issue list --repo="$WORK_OWNER_2/svc"
  check_gh "$WORK_OWNER" "$gh_pat" repo clone "$WORK_OWNER/svc"
  check_gh "$WORK_OWNER_2" "$gh_pat" repo view "https://github.com/$WORK_OWNER_2/svc"
  check_gh "$WORK_OWNER" "$gh_pat" pr view "https://github.com/$WORK_OWNER/svc/pull/7"
  check_gh "$WORK_OWNER" "$gh_pat" api "repos/$WORK_OWNER/svc/pulls"
  check_gh "$WORK_OWNER" env "GH_REPO=$WORK_OWNER/svc" "$gh_pat" pr list
  check_gh "<none>" "$gh_pat" -R "../$WORK_OWNER" pr list
fi

if ((failures)); then
  exit 1
fi
echo "github-pat-routing: ok"
