#!/usr/bin/env bash
# `repos list` with org directories that are symlinks into one flat folder
# (dotfiles.work.flatRepos): every repo is listed once, under the owner its
# origin remote names, and plain repos are unaffected.
#
# Usage: repos_list_links.sh <repos>
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repos=$1
root=$PWD/code
flat=$PWD/flat
failures=0

clone() {
  git init -q "$1"
  git -C "$1" remote add origin "$2"
}

mkdir -p "$root/github.com/me" "$flat"
clone "$root/github.com/me/notes" git@github.com:me/notes.git
ln -s "$flat" "$root/github.com/team-a"
ln -s "$flat" "$root/github.com/team-b"
clone "$flat/api" git@github.com:team-a/api.git
clone "$flat/engine" git@github.com:Team-B/engine.git
# Not a repo: the flat folder can hold the tooling's own state.
mkdir -p "$flat/envs"
# Origin owner isn't one of the linked orgs: still listed, exactly once.
clone "$flat/stray" git@github.com:elsewhere/stray.git

got=$(REPOS_CODE_ROOT=$root "$repos" list)
want=$(printf '%s\n' \
  "$root/github.com/me/notes" \
  "$root/github.com/team-a/api" \
  "$root/github.com/team-a/stray" \
  "$root/github.com/team-b/engine" | sort)
if [[ $got != "$want" ]]; then
  echo "FAIL list: want"
  echo "$want"
  echo "got"
  echo "$got"
  failures=$((failures + 1))
fi

if ((failures)); then exit 1; fi
echo "repos list links: ok"
