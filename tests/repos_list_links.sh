#!/usr/bin/env bash
# `repos list` with org directories that are symlinks into one flat folder
# (user.work.flatRepos): every repo is listed once, under the owner its
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

# `repos get` links a work owner's dir into the flat folder before cloning,
# so its checkout lands flat; a non-matching owner keeps its normal path.
export GIT_CONFIG_GLOBAL="$PWD/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
git init -q --bare "$PWD/remote-foo"
git init -q --bare "$PWD/remote-bar"
git config --global --add url."$PWD/remote-foo".insteadOf "git@github.com:$WORK_OWNER/foo.git"
git config --global --add url."$PWD/remote-bar".insteadOf "git@github.com:someone/bar.git"

root2=$PWD/code2
flat2=$PWD/flat2
mkdir -p "$root2/github.com" "$flat2"
REPOS_CODE_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/foo" >/dev/null
if [[ $(readlink "$root2/github.com/$WORK_OWNER") != "$flat2" ]]; then
  echo "FAIL get-link: want $flat2, got $(readlink "$root2/github.com/$WORK_OWNER")"
  failures=$((failures + 1))
fi
if [[ ! -d "$flat2/foo/.git" ]]; then
  echo "FAIL get-flat: $flat2/foo was not cloned flat"
  failures=$((failures + 1))
fi
REPOS_CODE_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get someone/bar >/dev/null
if [[ ! -d "$root2/github.com/someone/bar/.git" || -L "$root2/github.com/someone" ]]; then
  echo "FAIL get-plain: someone/bar should keep its normal path"
  failures=$((failures + 1))
fi

if ((failures)); then exit 1; fi
echo "repos list links: ok"
