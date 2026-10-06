#!/usr/bin/env bash
# `worktrees new --dry-run` branch naming: templates come from the repo's
# git config (smores.branchTemplate / smores.branchTemplateUnticketed), with
# {ticket} {type} {slug} placeholders; tickets come from --ticket or the
# first Jira-shaped key in --task/--slug. Templates here are set per repo, so
# the mechanics are tested independently of any employer's values; the
# generated config's values are covered by git_work_routing.sh.
#
# Usage: worktrees_branch_template.sh <worktrees>, with PERSONAL_BRANCH_TEMPLATE
# (the build-time fallback when the repo's git config sets nothing).
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME=$PWD/home
worktrees=$1
mkdir -p "$HOME"
failures=0

# repo <dir> [template [unticketed]]
repo() {
  git init -q "$1"
  git -C "$1" remote add origin "git@github.com:acme/$1.git"
  [ -z "${2:-}" ] || git -C "$1" config smores.branchTemplate "$2"
  [ -z "${3:-}" ] || git -C "$1" config smores.branchTemplateUnticketed "$3"
}

# run <dir> <args...>: prints the dry-run JSON; stderr folded in on failure
run() {
  local dir=$1
  shift
  (cd "$dir" && "$worktrees" new --dry-run "$@" 2>&1) || echo "EXIT $?"
}

field() {
  sed -nE "s/.*\"$1\":(\"([^\"]*)\"|null).*/\2/p"
}

check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

check_fails() {
  local out
  out=$(run "${@:2}")
  if [[ $out != *"EXIT "* ]]; then
    echo "FAIL $1: want an error, got '$out'"
    failures=$((failures + 1))
  fi
}

fallback=${PERSONAL_BRANCH_TEMPLATE//\{slug\}/fix-auth}

repo plain
check fallback "$(run plain --slug fix-auth | field branch)" "$fallback"
check fallback-dir "$(run plain --slug fix-auth | field path)" "$PWD/plain/.worktrees/fix-auth"
check fallback-ticket-null "$(run plain --slug fix-auth | grep -c '"ticket":null')" 1
# A Jira-shaped word in a task for a template without {ticket} stays text.
check fallback-task-key "$(run plain --task "Fix ABK-12 auth" | field branch)" "${PERSONAL_BRANCH_TEMPLATE//\{slug\}/fix-abk-12-auth}"
check_fails fallback-explicit-ticket plain --slug fix-auth --ticket ABK-12

repo prefixed 'me/{slug}'
check prefixed "$(run prefixed --slug 'Fix Auth' | field branch)" "me/fix-auth"

repo team '{ticket}-{slug}' '{type}/{slug}'
check ticket "$(run team --slug fix-auth --ticket ABK-1234 | field branch)" "ABK-1234-fix-auth"
check ticket-field "$(run team --slug fix-auth --ticket ABK-1234 | field ticket)" "ABK-1234"
check ticket-dir "$(run team --slug fix-auth --ticket ABK-1234 | field path)" "$PWD/team/.worktrees/ABK-1234-fix-auth"
check ticket-upcased "$(run team --slug fix-auth --ticket arui-7 | field branch)" "ARUI-7-fix-auth"
check ticket-from-task "$(run team --task "ABK-99: gate the readiness endpoint" | field branch)" "ABK-99-gate-the-readiness-endpoint"
check ticket-from-slug "$(run team --slug ABK-99-readiness-gate | field branch)" "ABK-99-readiness-gate"
check ticket-explicit-wins "$(run team --task "ABK-1 old" --ticket ABK-2 | field branch)" "ABK-2-abk-1-old"
check unticketed "$(run team --slug readiness-gate | field branch)" "fix/readiness-gate"
check unticketed-dir "$(run team --slug readiness-gate | field path)" "$PWD/team/.worktrees/readiness-gate"
check unticketed-type "$(run team --slug readiness-gate --type feat | field branch)" "feat/readiness-gate"
check lowercase-is-text "$(run team --task "bump utf-8 handling" | field branch)" "fix/bump-utf-8-handling"
check_fails bad-ticket team --slug x --ticket 1234
check_fails bad-type team --slug x --type 'Feat!'

repo ticket-only '{ticket}-{slug}'
check_fails ticket-required ticket-only --slug fix-auth

repo bad-placeholder '{user}/{slug}'
check_fails unknown-placeholder bad-placeholder --slug fix-auth

if ((failures)); then
  echo "$failures branch template expectation(s) failed"
  exit 1
fi
echo "worktrees branch template: ok"
