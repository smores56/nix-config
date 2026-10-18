#!/usr/bin/env bash
# work-repo-links points each existing <host-dir>/<owner> whose name matches
# the owner glob at the flat work folder. Default mode (activation) links
# empty dirs (and .DS_Store-only ones), accepts links that already resolve
# there, only warns about anything else, and always exits 0. --migrate moves
# a real org dir's checkouts into the flat folder, refusing name collisions
# and repairing worktree links, then links it. Owners not present yet are
# linked on demand by `repos get`, so the config names none of them.
#
# Usage: work_repo_links.sh <work-repo-links>
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
links=$1
root=$PWD/code/github.com
flat=$PWD/flat
glob='blitzy-*'
failures=0

check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

mkdir -p "$root/blitzy-empty" "$root/blitzy-litter" "$root/blitzy-full/repo" \
  "$root/other-org" "$PWD/other" "$flat"
touch "$root/blitzy-litter/.DS_Store" "$root/blitzy-afile"
ln -s "$PWD/other" "$root/blitzy-elsewhere"
ln -s "$flat/" "$root/blitzy-slashed"

out=$("$links" "$flat" "$root" "$glob" 2>&1) && rc=0 || rc=$?
check default-exit "$rc" 0
check empty-replaced "$(readlink "$root/blitzy-empty")" "$flat"
check litter-replaced "$(readlink "$root/blitzy-litter")" "$flat"
check full-kept "$([ -d "$root/blitzy-full/repo" ] && [ ! -L "$root/blitzy-full" ] && echo yes)" yes
check full-warned "$(grep -c -- "$root/blitzy-full is a real directory" <<<"$out")" 1
check elsewhere-kept "$(readlink "$root/blitzy-elsewhere")" "$PWD/other"
check elsewhere-warned "$(grep -c -- "$root/blitzy-elsewhere points to" <<<"$out")" 1
check slashed-accepted "$(grep -c -- "$root/blitzy-slashed" <<<"$out" || true)" 0
check afile-warned "$(grep -c -- "$root/blitzy-afile exists and is not a directory" <<<"$out")" 1
check other-untouched "$([ -d "$root/other-org" ] && [ ! -L "$root/other-org" ] && echo yes)" yes

# The owner glob is the only input: a rerun reproduces the same output.
out2=$("$links" "$flat" "$root" "$glob" 2>&1) && rc=0 || rc=$?
check idempotent-exit "$rc" 0
check idempotent-output "$([[ $out2 == "$out" ]] && echo same)" same

# The flat path is a file: warn, skip, still exit 0.
touch "$PWD/notadir"
out=$("$links" "$PWD/notadir" "$root" "$glob" 2>&1) && rc=0 || rc=$?
check unusable-flat-exit "$rc" 0
check unusable-flat-warned "$(grep -c "could not create" <<<"$out")" 1

# --migrate: a real org dir with a repo (plus a worktree) and a collision.
mkdir -p "$root/legacy-org"
git init -q "$root/legacy-org/app"
git -C "$root/legacy-org/app" commit -q --allow-empty -m init
git -C "$root/legacy-org/app" worktree add -q "$root/legacy-org/app/.worktrees/topic" -b topic
mkdir -p "$root/legacy-org/clash" "$flat/clash"
out=$("$links" --migrate "$flat" "$root" 'legacy-*' 2>&1) && rc=0 || rc=$?
check migrate-collision-exit "$rc" 1
check migrate-collision-warned "$(grep -c -- "$flat/clash already exists" <<<"$out")" 1
check migrate-all-or-nothing "$([ -d "$root/legacy-org/app/.git" ] && [ ! -e "$flat/app" ] && echo yes)" yes
check migrate-kept-clash "$([ -d "$root/legacy-org/clash" ] && [ ! -L "$root/legacy-org" ] && echo yes)" yes

rmdir "$root/legacy-org/clash"
out=$("$links" --migrate "$flat" "$root" 'legacy-*' 2>&1) && rc=0 || rc=$?
check migrate-done-exit "$rc" 0
check migrate-moved "$([ -d "$flat/app/.git" ] && echo yes)" yes
check migrate-linked "$(readlink "$root/legacy-org")" "$flat"
check migrate-worktree-repaired "$(git -C "$flat/app/.worktrees/topic" rev-parse --abbrev-ref HEAD 2>&1)" topic
check migrate-worktree-listed "$(git -C "$flat/app" worktree list --porcelain | grep -c "^worktree $flat/app/.worktrees/topic$")" 1

if ((failures)); then exit 1; fi
echo "work repo links: ok"
