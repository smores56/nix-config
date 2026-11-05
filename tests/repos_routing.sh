#!/usr/bin/env bash
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repos=$1
root=$PWD/repos
flat=$PWD/flat

clone() {
  git init -q "$1"
  git -C "$1" remote add origin "$2"
}

mkdir -p "$root/github.com/me" "$flat"
clone "$root/github.com/me/notes" git@github.com:me/notes.git
clone "$flat/api" git@github.com:team-a/api.git
clone "$flat/engine" git@github.com:team-b/engine.git
mkdir -p "$flat/envs" "$root/github.com/me/not-a-repo"
ln -s "$flat" "$root/github.com/team-a"
ln -s "$flat" "$root/github.com/team-b"
clone "$root/github.com/original/tool" git@github.com:original/tool.git
ln -s "$root/github.com/original" "$root/github.com/alias"
mkdir -p "$flat/linked"
printf 'gitdir: /somewhere\n' > "$flat/linked/.git"

got=$(REPOS_ROOT=$root REPOS_WORK_FLAT=$flat "$repos" list)
want=$(printf '%s\n' "$root/github.com/me/notes" "$root/github.com/original/tool" "$flat/api" "$flat/engine" "$flat/linked" | sort)
if [[ $got != "$want" ]]; then
  printf 'FAIL list: expected\n%s\ngot\n%s\n' "$want" "$got" >&2
  exit 1
fi

got=$(REPOS_ROOT=$root REPOS_WORK_FLAT=$PWD/missing "$repos" list)
[[ $got == *"$root/github.com/me/notes"* ]]
got=$(REPOS_ROOT=$PWD/missing REPOS_WORK_FLAT=$flat "$repos" list)
want=$(printf '%s\n' "$flat/api" "$flat/engine" "$flat/linked" | sort)
[[ $got == "$want" ]]

export GIT_CONFIG_GLOBAL="$PWD/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
git init -q --bare "$PWD/remote-foo"
git init -q --bare "$PWD/remote-bar"
git init -q --bare "$PWD/remote-other-host"
git init -q --bare "$PWD/remote-second-org"
git init -q --bare "$PWD/remote-lookalike"
git config --global --add url."$PWD/remote-foo".insteadOf "git@github.com:$WORK_OWNER/foo.git"
git config --global --add url."$PWD/remote-bar".insteadOf "git@github.com:someone/bar.git"
git config --global --add url."$PWD/remote-other-host".insteadOf "git@gitlab.example:$WORK_OWNER/other.git"
git config --global --add url."$PWD/remote-second-org".insteadOf "git@github.com:$WORK_OWNER_2/svc.git"
git config --global --add url."$PWD/remote-lookalike".insteadOf "git@github.com:$LOOKALIKE_WORK_OWNER/app.git"
root2=$PWD/repos2
flat2=$PWD/flat2
mkdir -p "$root2/github.com" "$flat2"
REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/foo" >/dev/null
[[ -d "$flat2/foo/.git" && ! -e "$root2/github.com/$WORK_OWNER" ]]
# Every listed work owner routes to the flat folder; a look-alike org does not.
REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER_2/svc" >/dev/null
[[ -d "$flat2/svc/.git" && ! -e "$root2/github.com/$WORK_OWNER_2" ]]
REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$LOOKALIKE_WORK_OWNER/app" >/dev/null
[[ -d "$root2/github.com/$LOOKALIKE_WORK_OWNER/app/.git" && ! -e "$flat2/app" ]]
REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get someone/bar >/dev/null
[[ -d "$root2/github.com/someone/bar/.git" ]]
REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "gitlab.example/$WORK_OWNER/other" >/dev/null
[[ -d "$root2/gitlab.example/$WORK_OWNER/other/.git" && ! -e "$flat2/other" ]]

# A pre-existing checkout in a real org directory must not be duplicated.
clone "$root2/github.com/${WORK_OWNER^^}/Old" "git@github.com:$WORK_OWNER/old.git"
if REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/OLD" >"$PWD/legacy" 2>&1; then
  echo 'FAIL: duplicated legacy checkout' >&2; exit 1
fi
[[ ! -e "$flat2/old" ]]
grep -q 'existing checkout or path' "$PWD/legacy"
if REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/FOO" >"$PWD/case-collision" 2>&1; then
  echo 'FAIL: accepted a case-insensitive flat collision' >&2; exit 1
fi
grep -q 'case-insensitive' "$PWD/case-collision"

# Existing paths, including a checkout from another org and dangling links,
# must never be overwritten.
git -C "$flat2/foo" remote set-url origin git@github.com:other/foo.git
if REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/foo" >"$PWD/collision" 2>&1; then
  echo 'FAIL: accepted a name collision' >&2; exit 1
fi
grep -q 'already a checkout of' "$PWD/collision"
ln -s "$PWD/missing" "$flat2/dangling"
if REPOS_ROOT=$root2 REPOS_WORK_FLAT=$flat2 "$repos" get "$WORK_OWNER/dangling" >/dev/null 2>&1; then
  echo 'FAIL: accepted a dangling link' >&2; exit 1
fi

echo 'repos list and routing: ok'
