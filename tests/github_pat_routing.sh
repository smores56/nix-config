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
# - the gh wrapper follows a small, predictable rule: -R/--repo or GH_REPO,
#   else the `api` endpoint, else the remote gh itself would use, else the
#   personal account; positional arguments are never guessed at (name another
#   account's repo with -R or GH_REPO), and an explicit target that is no
#   account name gets no token.
#
# Usage: github_pat_routing.sh <github-token-file> <gh-pat>
#          <github-credential-helper> <personal-pat-file> <work-pat-file>
#          <absent-pat-file>,
#        with PERSONAL_OWNER, WORK_OWNER, WORK_OWNER_2 and LOOKALIKE_WORK_OWNER.
set -euo pipefail

token_file=$1
gh_pat=$2
helper=$3
personal_pat=$4
work_pat=$5
absent_pat=$6
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
  local h=$1
  shift
  printf '%s\n' "$@" "" | "$h" get 2>"$work/helper.err"
}

# Requests the helper must decline outright: they are not GitHub over HTTPS.
out=$(ask "$helper" protocol=http host=github.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for http"
[ -z "$out" ] || fail "helper answered a plain-http request"
out=$(ask "$helper" protocol=https host=example.com "path=$PERSONAL_OWNER/x.git") || fail "helper exited non-zero for a non-GitHub host"
[ -z "$out" ] || fail "helper answered a non-GitHub host"

# `www.github.com` (a spelling insteadOf rewrites, modules/features/github-credentials.nix)
# is the same service, so an untrusted path there stops git cold like the bare
# host. Plain `http` is declined above, before any rewrite matters.
out=$(ask "$helper" protocol=https host=www.github.com "path=/$WORK_OWNER/x.git")
[ "$out" = quit=1 ] || fail "helper answered suspicious path on www.github.com: $out"

# Requests aimed at GitHub whose owner cannot be trusted stop git cold,
# before any token file is read.
for path in "/$WORK_OWNER/x.git" "$WORK_OWNER/../$PERSONAL_OWNER/x.git" "$WORK_OWNER/./x" ""; do
  out=$(ask "$helper" protocol=https host=github.com "path=$path")
  [ "$out" = quit=1 ] || fail "helper answered suspicious path '$path': $out"
done

# Without a token the helper names the owner and stops git instead of letting
# it prompt. The real PATs are readable on the work Mac, so a copy of the
# helper resolves every owner to a deliberately absent path: the matrix runs
# everywhere, not only in a sandboxed Linux build.
if [ -r "$absent_pat" ]; then
  fail "the absent PAT path '$absent_pat' is readable"
fi
mkdir -p "$work/absent/bin"
# The stub answers every owner with the absent path. It runs under the shell the
# check itself runs in: a build sandbox has no /usr/bin/env to shebang through.
cat >"$work/absent/bin/github-token-file" <<EOF
#!$BASH
printf '%s\n' "$absent_pat"
EOF
chmod +x "$work/absent/bin/github-token-file"
missing_helper=$work/helper-missing-token
sed "s|$token_file|$work/absent/bin/github-token-file|g" "$helper" >"$missing_helper"
chmod +x "$missing_helper"
grep -qF "$work/absent/bin/github-token-file" "$missing_helper" || fail "could not point the helper at an absent token"
for host in github.com GitHub.com github.com:443; do
  for owner in "$PERSONAL_OWNER" "$WORK_OWNER"; do
    out=$(ask "$missing_helper" protocol=https "host=$host" "path=$owner/routing.git") || fail "helper exited non-zero for $owner@$host"
    [ "$out" = quit=1 ] || fail "helper without a token for $owner@$host said: $out"
    grep -qF "'$owner'" "$work/helper.err" || fail "helper did not name owner $owner"
  done
done

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
mkrepo "$work/sole" mirror "https://github.com/$WORK_OWNER/svc/"
mkrepo "$work/resolved-name" origin "https://github.com/$PERSONAL_OWNER/svc.git"
git -C "$work/resolved-name" config remote.origin.gh-resolved "$WORK_OWNER_2/svc"
mkrepo "$work/ranked" github "https://github.com/$PERSONAL_OWNER/svc.git" upstream "ssh://git@github.com:22/$WORK_OWNER/svc.git"
mkrepo "$work/unknown" one "https://github.com/$WORK_OWNER/a.git" two "https://github.com/$WORK_OWNER/b.git"
mkrepo "$work/bare"
mkrepo "$work/ghe" origin "https://acme.ghe.com/$WORK_OWNER/svc.git"
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
check_gh resolved-name "$WORK_OWNER_2" "$gh_pat" pr list
check_gh sole "$WORK_OWNER" "$gh_pat" pr list
check_gh ranked "$WORK_OWNER" "$gh_pat" pr list
check_gh unknown "$PERSONAL_OWNER" "$gh_pat" pr list
check_gh bare "$PERSONAL_OWNER" "$gh_pat" pr list
# Another host never gets either account's token.
check_gh ghe "<other-host>" "$gh_pat" pr list
check_gh personal "<other-host>" env GH_HOST=acme.ghe.com "$gh_pat" pr list
check_gh personal "<other-host>" "$gh_pat" api --hostname acme.ghe.com user
check_gh personal "<other-host>" "$gh_pat" api https://acme.ghe.com/api/v3/user
check_gh personal "$PERSONAL_OWNER" "$gh_pat" api --hostname github.com user
check_gh personal "$PERSONAL_OWNER" "$gh_pat" pr comment 3 --body https://evil.example/x
# Nothing targeted and no checkout: the personal account, not a failure.
check_gh outside "$PERSONAL_OWNER" "$gh_pat" auth status
check_gh outside "$PERSONAL_OWNER" "$gh_pat" api user
# Explicit targets win over the checkout.
check_gh personal "$WORK_OWNER" "$gh_pat" -R "$WORK_OWNER/svc" pr list
check_gh personal "$WORK_OWNER_2" "$gh_pat" pr list --repo "$WORK_OWNER_2/svc"
check_gh personal "$WORK_OWNER_2" "$gh_pat" issue list --repo="$WORK_OWNER_2/svc"
check_gh personal "$WORK_OWNER" env "GH_REPO=$WORK_OWNER/svc" "$gh_pat" pr list
check_gh personal "$WORK_OWNER" "$gh_pat" pr list "-R$WORK_OWNER/svc"
check_gh personal "$WORK_OWNER_2" env "GH_REPO=$WORK_OWNER/svc" "$gh_pat" -R "$WORK_OWNER_2/svc" pr list
check_gh outside "$WORK_OWNER_2" env "GH_REPO=github.com/$WORK_OWNER_2/svc" "$gh_pat" repo view
check_gh personal "$WORK_OWNER" "$gh_pat" api -X POST "repos/$WORK_OWNER/svc/pulls"
check_gh personal "$WORK_OWNER" "$gh_pat" api "https://api.github.com/orgs/$WORK_OWNER/repos" --jq .name
check_gh personal "$WORK_OWNER" "$gh_pat" api "orgs/$WORK_OWNER?per_page=1"
# Positional arguments are never guessed at, and placeholders or URLs that are
# not the target leave the checkout in charge.
check_gh personal "$PERSONAL_OWNER" "$gh_pat" repo view "$WORK_OWNER/svc"
check_gh outside "$PERSONAL_OWNER" "$gh_pat" pr view "https://github.com/$WORK_OWNER/svc/pull/7"
check_gh work "$WORK_OWNER" "$gh_pat" api "repos/{owner}/{repo}/pulls"
check_gh personal "$PERSONAL_OWNER" "$gh_pat" pr comment 3 --body "https://github.com/$WORK_OWNER/svc/pull/1"
check_gh personal "$PERSONAL_OWNER" "$gh_pat" api graphql -f "query=https://github.com/$WORK_OWNER"
# An explicit target that is not an account name gets no token at all.
check_gh personal "<none>" "$gh_pat" -R "../$WORK_OWNER" pr list

if ((failures)); then
  exit 1
fi
echo "github-pat-routing: ok"
