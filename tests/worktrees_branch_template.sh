#!/usr/bin/env bash
# `worktrees new --dry-run` branch naming: templates come from the repo's
# git config (smores.branchTemplate / smores.branchTemplateUnticketed /
# smores.ticketPattern), with {slug} {ticket} {type} placeholders; tickets
# only come from --ticket. Schemes are set per repo here, so the mechanics
# are tested independently of any employer's values; the generated config's
# values are covered by git_work_routing.sh.
#
# Usage: worktrees_branch_template.sh <worktrees>, with
# PERSONAL_BRANCH_TEMPLATE (the build-time fallback when the repo's git
# config sets nothing).
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME=$PWD/home
worktrees=$1
mkdir -p "$HOME"
failures=0
jira='[A-Z][A-Z0-9]*-[0-9]+'

# repo <dir> [template unticketed pattern]: with a template, sets all three
# keys the way git.nix does (an empty unticketed means ticket required).
repo() {
  git init -q "$1"
  git -C "$1" remote add origin "git@github.com:acme/$1.git"
  if [ $# -gt 1 ]; then
    git -C "$1" config smores.branchTemplate "$2"
    git -C "$1" config smores.branchTemplateUnticketed "$3"
    git -C "$1" config smores.ticketPattern "$4"
  fi
}

# run <dir> <args...>: prints the dry-run JSON, or stderr plus EXIT on failure
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

# check_fails <name> <message substring> <dir> <args...>
check_fails() {
  local name=$1 want=$2 out
  shift 2
  out=$(run "$@")
  if [[ $out != *"EXIT "* || $out != *"$want"* ]]; then
    echo "FAIL $name: want an error containing '$want', got '$out'"
    failures=$((failures + 1))
  fi
}

# The fallback scheme is whatever the personal default is; pass a ticket and
# type so any placeholder it uses has a value.
repo plain
want=$PERSONAL_BRANCH_TEMPLATE
want=${want//\{slug\}/fix-auth}
want=${want//\{ticket\}/ABC-1}
want=${want//\{type\}/fix}
check fallback "$(run plain --slug fix-auth --ticket ABC-1 --type fix | field branch)" "$want"

repo prefixed 'me/{slug}' '' "$jira"
check prefixed "$(run prefixed --slug 'Fix Auth' | field branch)" "me/fix-auth"
check prefixed-dir "$(run prefixed --slug fix-auth | field path)" "$PWD/prefixed/.worktrees/me-fix-auth"
check prefixed-task "$(run prefixed --task 'Fix the auth flow' | field branch)" "me/fix-the-auth-flow"
check prefixed-slug-wins "$(run prefixed --slug fix-auth --task 'ABC-9: other words' | field branch)" "me/fix-auth"
# Repos that don't name branches by ticket ignore it rather than failing.
check prefixed-ignores-ticket "$(run prefixed --slug fix-auth --ticket ABC-1 | field branch)" "me/fix-auth"
check prefixed-ticket-null "$(run prefixed --slug fix-auth --ticket ABC-1 | field ticket)" ""
check prefixed-ignores-type "$(run prefixed --slug fix-auth --type feat | field branch)" "me/fix-auth"

repo team '{ticket}-{slug}' '{type}/{slug}' "$jira"
check ticket "$(run team --slug fix-auth --ticket ABK-1234 | field branch)" "ABK-1234-fix-auth"
check ticket-field "$(run team --slug fix-auth --ticket ABK-1234 | field ticket)" "ABK-1234"
check ticket-dir "$(run team --slug fix-auth --ticket ABK-1234 | field path)" "$PWD/team/.worktrees/ABK-1234-fix-auth"
check ticket-not-repeated "$(run team --slug abk-1234-fix-auth --ticket ABK-1234 | field branch)" "ABK-1234-fix-auth"
# Jira-looking words in free text are text, never tickets.
check no-implicit-ticket "$(run team --task 'Handle UTF-8 in ABK-9' --type fix | field branch)" "fix/handle-utf-8-in-abk-9"
check unticketed "$(run team --slug readiness-gate --type fix | field branch)" "fix/readiness-gate"
check unticketed-dir "$(run team --slug readiness-gate --type feat | field path)" "$PWD/team/.worktrees/feat-readiness-gate"
check_fails type-required 'needs --type' team --slug readiness-gate
check_fails bad-type 'lowercase kebab' team --slug x --type 'Feat!'
check_fails multiline-type 'lowercase kebab' team --slug x --type $'fix\nx'
check_fails bad-ticket 'ticket pattern' team --slug x --ticket abk-12
check_fails multiline-ticket 'ticket pattern' team --slug x --ticket $'ABK-1\nx'
check_fails ticket-only-slug 'empty slug' team --slug ABK-7 --ticket ABK-7

repo ticket-only '{ticket}-{slug}' '' "$jira"
check_fails ticket-required 'needs --ticket' ticket-only --slug fix-auth --type fix

repo numbered '{slug}-{ticket}' '' '#?[0-9]+'
check custom-pattern "$(run numbered --slug fix-auth --ticket 42 | field branch)" "fix-auth-42"
check_fails custom-pattern-rejects 'ticket pattern' numbered --slug fix-auth --ticket ABK-42

repo bad-placeholder '{user}/{slug}' '' "$jira"
check_fails unknown-placeholder 'unknown placeholder' bad-placeholder --slug fix-auth

if ((failures)); then
  echo "$failures branch template expectation(s) failed"
  exit 1
fi
echo "worktrees branch template: ok"
