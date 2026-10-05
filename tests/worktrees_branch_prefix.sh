#!/usr/bin/env bash
# `worktrees new --dry-run` against the generated git config: work-owner
# repos get the work branch prefix, everything else the personal one.
#
# Usage: worktrees_branch_prefix.sh <gitconfig> <worktrees>, with WORK_OWNER
# (a concrete owner matching the work glob), WORK_PREFIX, PERSONAL_OWNER and
# PERSONAL_PREFIX.
set -euo pipefail

export GIT_CONFIG_GLOBAL=$1 GIT_CONFIG_NOSYSTEM=1 HOME=$PWD/home
worktrees=$2
mkdir -p "$HOME"
failures=0

branch_for() {
  local dir=$1 url=$2
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  (cd "$dir" && "$worktrees" new --slug fix-auth --dry-run) | sed -E 's/.*"branch":"([^"]*)".*/\1/'
}

check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

check work "$(branch_for work "git@github.com:$WORK_OWNER/app.git")" "$WORK_PREFIX/fix-auth"
check personal "$(branch_for personal "git@github.com:$PERSONAL_OWNER/notes.git")" "$PERSONAL_PREFIX/fix-auth"
check third-party "$(branch_for third-party git@github.com:NixOS/nixpkgs.git)" "$PERSONAL_PREFIX/fix-auth"

if ((failures)); then
  echo "$failures branch prefix expectation(s) failed"
  exit 1
fi
echo "worktrees branch prefix: ok"
