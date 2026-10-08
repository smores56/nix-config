#!/usr/bin/env bash
# The brain skill and digest ship in this public repo while the vault they
# serve holds employer data. This guard fails the build when the brain files
# name the employer (identifiers derived from dotfiles.work), link a Slack or
# Jira workspace, or carry a ticket key that isn't an obvious placeholder.
# It first proves itself against planted fixtures, then scans the repo.
#
# Usage: brain_leak_guard.sh <repo-root> <employer-identifier>...
set -euo pipefail

root=$1
shift
identifiers=("$@")
failures=0

# Placeholder ticket prefixes the tests use, plus standards that look like
# keys (UTF-8, SHA-256, UTC-5) and `Z0-9` from the digest's own key regex.
synthetic_prefixes='^(FOO|BAR|ERR|SHA|UTC|UTF|Z0)-'

brain_files() {
  local base=$1
  for path in modules/features/ai/brain modules/features/ai/skills/brain tests/test_brain_digest.py tests/test_brain_commit.py; do
    [[ -e $base/$path ]] && find "$base/$path" -type f
  done
  return 0
}

# Prints one line per leak and returns non-zero if any were found.
scan() {
  local base=$1 leaks=0 files
  mapfile -t files < <(brain_files "$base")
  ((${#files[@]})) || return 0

  for id in "${identifiers[@]}"; do
    if grep -HnFi -e "$id" "${files[@]}"; then leaks=1; fi
  done
  if grep -HnEi '[a-z0-9-]+\.(slack\.com|atlassian\.net)' "${files[@]}"; then leaks=1; fi
  if grep -HnoE '\b[A-Z][A-Z0-9]{1,9}-[0-9]+\b' "${files[@]}" |
    awk -F: -v ok="$synthetic_prefixes" '$3 !~ ok { print; found = 1 } END { exit !found }'; then
    leaks=1
  fi
  return $leaks
}

expect() {
  local name=$1 want=$2 base=$3 got
  scan "$base" >/dev/null && got=pass || got=fail
  if [[ $got != "$want" ]]; then
    echo "FAIL self-test $name: want $want, got $got"
    failures=$((failures + 1))
  fi
}

fixture() {
  local base=$1 content=$2
  mkdir -p "$base/modules/features/ai/skills/brain"
  printf '%s\n' "$content" >"$base/modules/features/ai/skills/brain/SKILL.md"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixture "$work/clean" 'Pass --ticket-prefix <KEY>; cite FOO-123 style keys.'
expect clean pass "$work/clean"
for id in "${identifiers[@]}"; do
  fixture "$work/id-$id" "Harvest from the ${id^^} org."
  expect "identifier $id" fail "$work/id-$id"
done
fixture "$work/slack" 'See https://acme.slack.com/archives/C1'
expect slack-url fail "$work/slack"
fixture "$work/jira" 'See https://acme.atlassian.net/browse/X'
expect jira-url fail "$work/jira"
fixture "$work/ticket" 'Worked on QQX-4521 today.'
expect ticket-key fail "$work/ticket"

if ! scan "$root"; then
  echo "FAIL brain files above leak employer-specific data; move it to the vault's CLAUDE.md"
  failures=$((failures + 1))
fi

((failures == 0)) || exit 1
echo "brain leak guard: ok"
