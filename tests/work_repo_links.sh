#!/usr/bin/env bash
# work-repo-links points <host-dir>/<org> at the flat work folder. Default
# mode (activation) links missing paths and empty dirs, accepts links that
# already resolve there, only warns about anything else, and always exits 0.
# --migrate moves a real org dir's checkouts into the flat folder, refusing
# name collisions and repairing worktree links, then links it.
#
# Usage: work_repo_links.sh <work-repo-links>
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
links=$1
root=$PWD/code/github.com
flat=$PWD/flat
failures=0

check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

mkdir -p "$root/empty" "$root/litter" "$root/full/repo" "$PWD/other" "$flat"
touch "$root/litter/.DS_Store" "$root/afile"
ln -s "$PWD/other" "$root/elsewhere"
ln -s "$flat/" "$root/slashed"

out=$("$links" "$flat" "$root" fresh empty litter full elsewhere slashed afile 2>&1) && rc=0 || rc=$?
check default-exit "$rc" 0
check fresh "$(readlink "$root/fresh")" "$flat"
check empty-replaced "$(readlink "$root/empty")" "$flat"
check litter-replaced "$(readlink "$root/litter")" "$flat"
check full-kept "$([ -d "$root/full/repo" ] && [ ! -L "$root/full" ] && echo yes)" yes
check full-warned "$(grep -c -- "$root/full is a real directory" <<<"$out")" 1
check elsewhere-kept "$(readlink "$root/elsewhere")" "$PWD/other"
check elsewhere-warned "$(grep -c -- "$root/elsewhere points to" <<<"$out")" 1
check slashed-accepted "$(grep -c -- "$root/slashed" <<<"$out" || true)" 0
check afile-warned "$(grep -c -- "$root/afile exists and is not a directory" <<<"$out")" 1
check idempotent "$("$links" "$flat" "$root" fresh empty 2>&1)" ""

# The flat path is a file: warn, skip, still exit 0.
touch "$PWD/notadir"
out=$("$links" "$PWD/notadir" "$root" other-org 2>&1) && rc=0 || rc=$?
check unusable-flat-exit "$rc" 0
check unusable-flat-warned "$(grep -c "could not create" <<<"$out")" 1

# --migrate: a real org dir with a repo (plus a worktree) and a collision.
mkdir -p "$root/legacy"
git init -q "$root/legacy/app"
git -C "$root/legacy/app" commit -q --allow-empty -m init
git -C "$root/legacy/app" worktree add -q "$root/legacy/app/.worktrees/topic" -b topic
mkdir -p "$root/legacy/clash" "$flat/clash"
out=$("$links" --migrate "$flat" "$root" legacy 2>&1) && rc=0 || rc=$?
check migrate-collision-exit "$rc" 1
check migrate-collision-warned "$(grep -c -- "$flat/clash already exists" <<<"$out")" 1
check migrate-moved "$([ -d "$flat/app/.git" ] && echo yes)" yes
check migrate-kept-clash "$([ -d "$root/legacy/clash" ] && [ ! -L "$root/legacy" ] && echo yes)" yes
check migrate-worktree-repaired "$(git -C "$flat/app/.worktrees/topic" rev-parse --abbrev-ref HEAD 2>&1)" topic
check migrate-worktree-listed "$(git -C "$flat/app" worktree list --porcelain | grep -c "^worktree $flat/app/.worktrees/topic$")" 1

rmdir "$root/legacy/clash"
out=$("$links" --migrate "$flat" "$root" legacy 2>&1) && rc=0 || rc=$?
check migrate-done-exit "$rc" 0
check migrate-linked "$(readlink "$root/legacy")" "$flat"

if ((failures)); then exit 1; fi
echo "work repo links: ok"
