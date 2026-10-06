#!/usr/bin/env bash
# Exercises the generated git config against scratch repos: work-owner
# remotes (every URL form and casing, worktrees, mixed remotes) pick up the
# work identity and ssh route, the personal owner gets the direct flow, and
# everything else keeps only the personal defaults.
#
# Usage: git_work_routing.sh <gitconfig>, with the expected values in
# WORK_EMAIL WORK_KEY WORK_SSH_CONFIG WORK_BRANCH_TEMPLATE
# WORK_BRANCH_UNTICKETED WORK_OWNER (a concrete owner matching the work glob)
# PERSONAL_EMAIL PERSONAL_KEY PERSONAL_BRANCH_TEMPLATE
# PERSONAL_BRANCH_UNTICKETED PERSONAL_OWNER, plus WORK_TICKET_PATTERN and
# PERSONAL_TICKET_PATTERN.
set -euo pipefail

export GIT_CONFIG_GLOBAL=$1 GIT_CONFIG_NOSYSTEM=1 HOME=$PWD/home
mkdir -p "$HOME"
failures=0

expect() {
  local dir=$1 key=$2 want=$3 got
  got=$(git -C "$dir" config --get "$key" || true)
  if [[ $got != "$want" ]]; then
    echo "FAIL $dir $key: want '$want', got '$got'"
    failures=$((failures + 1))
  fi
}

repo() {
  local dir=$1
  shift
  git init -q "$dir"
  local n=0 url
  for url in "$@"; do
    git -C "$dir" remote add "r$n" "$url"
    n=$((n + 1))
  done
}

expect_work() {
  expect "$1" user.email "$WORK_EMAIL"
  expect "$1" user.signingkey "$WORK_KEY.pub"
  expect "$1" core.sshCommand "ssh -F $WORK_SSH_CONFIG"
  expect "$1" smores.branchTemplate "$WORK_BRANCH_TEMPLATE"
  expect "$1" smores.branchTemplateUnticketed "$WORK_BRANCH_UNTICKETED"
  expect "$1" smores.ticketPattern "$WORK_TICKET_PATTERN"
  expect "$1" smores.flow pr
}

expect_personal() {
  expect "$1" user.email "$PERSONAL_EMAIL"
  expect "$1" user.signingkey "$PERSONAL_KEY.pub"
  expect "$1" core.sshCommand ""
  expect "$1" smores.branchTemplate "$PERSONAL_BRANCH_TEMPLATE"
  expect "$1" smores.branchTemplateUnticketed "$PERSONAL_BRANCH_UNTICKETED"
  expect "$1" smores.ticketPattern "$PERSONAL_TICKET_PATTERN"
  expect "$1" smores.flow "$2"
}

w=$WORK_OWNER
W=${WORK_OWNER^^}
repo scp "git@github.com:$w/app.git"
repo scp-slash "git@github.com:/$w/app.git"
repo scp-nouser "github.com:$w/app.git"
repo ssh "ssh://git@github.com/$w/infra.git"
repo ssh-port "ssh://git@github.com:22/$w/infra.git"
repo ssh-nouser "ssh://github.com/$w/infra"
repo https "https://github.com/$w/app"
repo https-user "https://someone@github.com/$w/app.git"
repo upper "git@github.com:$W/app.git"
repo mixed "git@github.com:$PERSONAL_OWNER/fork.git" "git@github.com:$w/app.git"
repo own "git@github.com:$PERSONAL_OWNER/notes.git"
repo third-party "git@github.com:NixOS/nixpkgs.git"
repo repo-named-like-work "git@github.com:$PERSONAL_OWNER/$w.git"
repo lookalike-owner "git@github.com:not$w/app.git"
repo lookalike-host "git@evilgithub.com:$w/app.git"
mkdir outside

for dir in scp scp-slash scp-nouser ssh ssh-port ssh-nouser https https-user upper mixed; do
  expect_work "$dir"
done
for dir in own repo-named-like-work; do expect_personal "$dir" direct; done
for dir in third-party lookalike-owner lookalike-host outside; do expect_personal "$dir" ""; done

git -C scp -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C scp worktree add -q ../scp-wt
expect_work scp-wt

if ((failures)); then
  echo "$failures routing expectation(s) failed"
  exit 1
fi
echo "git work routing: ok"
