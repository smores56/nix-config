#!/usr/bin/env bash
# shellcheck disable=SC2088  # git stores the signing key as a literal ~ path
# Exercises the generated git config against scratch repos: work-org remotes
# (every URL form, worktrees) pick up the work identity and ssh route, and
# everything else stays personal. Usage: git_work_routing.sh <gitconfig>
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
  git init -q "$1"
  git -C "$1" remote add origin "$2"
}

expect_work() {
  expect "$1" user.email smohr@blitzy.com
  expect "$1" user.signingkey "~/.ssh/id_work.pub"
  expect "$1" core.sshCommand "ssh -F ~/.ssh/config.work"
  expect "$1" smores.branchPrefix smohr
  expect "$1" smores.flow pr
}

expect_personal() {
  expect "$1" user.email sam@sammohr.dev
  expect "$1" user.signingkey "~/.ssh/id_personal.pub"
  expect "$1" core.sshCommand ""
  expect "$1" smores.branchPrefix smores
  expect "$1" smores.flow direct
}

repo scp git@github.com:blitzy-ai/app.git
repo ssh ssh://git@github.com/blitzy-platform/infra.git
repo https https://github.com/blitzy-ai/app
repo personal git@github.com:smores56/blitzy-notes.git
repo lookalike git@github.com:notblitzy-ai/app.git
mkdir outside

for dir in scp ssh https; do expect_work "$dir"; done
for dir in personal lookalike outside; do expect_personal "$dir"; done

git -C scp -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C scp worktree add -q ../scp-wt
expect_work scp-wt

if ((failures)); then
  echo "$failures routing expectation(s) failed"
  exit 1
fi
echo "git work routing: ok"
