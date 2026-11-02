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
# - the gh wrapper takes the owner from -R/--repo, GH_REPO, the command's own
#   target (`repo <verb> owner/name`, `pr|issue <verb> <URL>`, the `api`
#   endpoint), then the remote gh itself would use, then the personal account;
#   an explicit target that is no account name gets no token.
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

ask() {
  printf '%s\n' "$@" "" | "$helper" get 2>"$work/helper.err"
}

# Requests the helper must decline outright: they are not GitHub over HTTPS.
out=$(ask protocol=http host=github.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for http"
[ -z "$out" ] || fail "helper answered a plain-http request"
out=$(ask protocol=https host=example.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for a non-GitHub host"
[ -z "$out" ] || fail "helper answered a non-GitHub host"

# Requests aimed at GitHub whose owner cannot be trusted stop git cold,
# before any token file is read.
for path in "/$WORK_OWNER/x.git" "$WORK_OWNER/../$PERSONAL_OWNER/x.git" "$WORK_OWNER/./x" ""; do
  out=$(ask protocol=https host=github.com "path=$path")
  [ "$out" = quit=1 ] || fail "helper answered suspicious path '$path': $out"
done

# Without a token the helper names the owner and stops git instead of letting
# it prompt; only checkable where the real token files are unreadable (a
# sandboxed Linux build).
if [ -r "$personal_pat" ] || [ -r "$work_pat" ]; then
  echo "token files readable here; skipping the missing-token helper cases"
else
  for host in github.com GitHub.com github.com:443; do
    for owner in "$PERSONAL_OWNER" "$WORK_OWNER"; do
      out=$(ask protocol=https "host=$host" "path=$owner/routing.git") || fail "helper exited non-zero for $owner@$host"
      [ "$out" = quit=1 ] || fail "helper without a token for $owner@$host said: $out"
      grep -qF "'$owner'" "$work/helper.err" || fail "helper did not name owner $owner"
    done
  done
fi

# gh: which owner does the wrapper resolve? GH_PAT_RESOLVE_ONLY prints the
# owner (never a token) and exits, so these run everywhere.
mkrepo() {
  local dir=$1
  shift
  git init -q "$dir"
  while [ $# -gt 0 ]; do
    git -C "$dir" remote add "$1" "$2"
    shift 2
  done
}
mkrepo "$work/personal" origin "https://github.com/$PERSONAL_OWNER/notes.git"
mkrepo "$work/work" origin "git@github.com:$WORK_OWNER/svc.git"
mkrepo "$work/fork" origin "https://github.com/$PERSONAL_OWNER/svc.git" upstream "https://github.com/$WORK_OWNER_2/svc.git"
mkrepo "$work/resolved" origin "https://github.com/$WORK_OWNER/svc.git" mine "https://github.com/$PERSONAL_OWNER/svc.git"
git -C "$work/resolved" config remote.mine.gh-resolved base
mkdir -p "$work/outside"

check_gh() {
  local dir=$1 expected=$2 got
  shift 2
  got=$(cd "$work/$dir" && env -u GH_TOKEN -u GH_REPO -u GH_HOST GH_PAT_RESOLVE_ONLY=1 "$@" 2>&1) || true
  [ "$got" = "$expected" ] || fail "($dir) gh ${*:2}: resolved '$got', want '$expected'"
}
# The checkout's remote, as gh itself would choose it.
check_gh personal "$PERSONAL_OWNER" "$gh_pat" pr list
check_gh work "$WORK_OWNER" "$gh_pat" pr list
check_gh fork "$WORK_OWNER_2" "$gh_pat" pr create
check_gh resolved "$PERSONAL_OWNER" "$gh_pat" pr list
# Nothing targeted and no checkout: the personal account, not a failure.
check_gh outside "$PERSONAL_OWNER" "$gh_pat" auth status
check_gh outside "$PERSONAL_OWNER" "$gh_pat" api user
# Explicit targets win over the checkout.
check_gh personal "$WORK_OWNER" "$gh_pat" -R "$WORK_OWNER/svc" pr list
check_gh personal "$WORK_OWNER_2" "$gh_pat" pr list --repo "$WORK_OWNER_2/svc"
check_gh personal "$WORK_OWNER_2" "$gh_pat" issue list --repo="$WORK_OWNER_2/svc"
check_gh personal "$WORK_OWNER" env "GH_REPO=$WORK_OWNER/svc" "$gh_pat" pr list
check_gh outside "$WORK_OWNER" "$gh_pat" repo clone "$WORK_OWNER/svc" -- --depth 1
check_gh outside "$WORK_OWNER_2" "$gh_pat" repo view "https://GitHub.com/$WORK_OWNER_2/svc"
check_gh personal "$WORK_OWNER" "$gh_pat" pr view "https://github.com/$WORK_OWNER/svc/pull/7"
check_gh personal "$WORK_OWNER" "$gh_pat" api -X POST "repos/$WORK_OWNER/svc/pulls"
check_gh personal "$WORK_OWNER" "$gh_pat" api "https://api.github.com/orgs/$WORK_OWNER/repos" --jq .name
# Placeholders and URLs that are not the target leave the checkout in charge.
check_gh work "$WORK_OWNER" "$gh_pat" api "repos/{owner}/{repo}/pulls"
check_gh personal "$PERSONAL_OWNER" "$gh_pat" pr comment 3 --body "https://github.com/$WORK_OWNER/svc/pull/1"
check_gh personal "$PERSONAL_OWNER" "$gh_pat" api graphql -f "query=https://github.com/$WORK_OWNER"
# An explicit target that is not an account name gets no token at all.
check_gh personal "<none>" "$gh_pat" -R "../$WORK_OWNER" pr list

if ((failures)); then
  exit 1
fi
echo "github-pat-routing: ok"
