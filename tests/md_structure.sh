#!/usr/bin/env bash
# md-structure must hand the dictation to the runner its AI profile names, with every tool
# denied, and fail without output (Helix `:pipe` then leaves the selection alone).
# Usage: md_structure.sh <md-structure.sh> <md-structure.prompt.md>
set -euo pipefail

script_src=$1
prompt=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

render() { # runner model
  sed -e "s|@PROMPT_FILE@|$prompt|; s|@RUNNER@|$1|; s|@MODEL@|$2|" "$script_src" >"$work/md-structure"
}

fakes="$work/fakes"
mkdir -p "$fakes"
for runner in maki claude; do
  cat >"$fakes/$runner" <<EOS
#!$BASH
echo "$runner \$*" >"$work/argv"
cat >"$work/stdin"
printf '%s\n' "\${FAKE_REPLY-# Structured}"
EOS
  chmod +x "$fakes/$runner"
done

run() {
  env HOME="$work/home" PATH="$fakes:$PATH" "$@" bash "$work/md-structure" <<<'one two three four five'
}

render maki personal/model
run >"$work/out"
grep -q '^maki .*-m personal/model' "$work/argv" || fail "personal profile must run maki with its model: $(cat "$work/argv")"
grep -q -- '--disallowed-tools' "$work/argv" || fail "maki must run with tools denied"
grep -q 'one two three four five' "$work/stdin" || fail "the dictation must reach the runner"
[ "$(cat "$work/out")" = "# Structured" ] || fail "reply not passed through"

render claude work-model
run >"$work/out"
grep -q '^claude -p .*--model work-model' "$work/argv" || fail "work profile must run claude with its model: $(cat "$work/argv")"
grep -q -- '--tools ' "$work/argv" || fail "claude must run with no tools"
grep -q 'one two three four five' "$work/stdin" || fail "the dictation must reach claude"

run MD_STRUCTURE_MODEL=override >/dev/null
grep -q -- '--model override' "$work/argv" || fail "MD_STRUCTURE_MODEL must override the profile model"

set +e
run FAKE_REPLY= >"$work/out" 2>/dev/null
status=$?
set -e
[ "$status" -eq 4 ] || fail "an empty reply exited $status, want 4"
[ ! -s "$work/out" ] || fail "an empty reply must print nothing"

set +e
bash "$work/md-structure" <<<'hi' >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 3 ] || fail "one-word input exited $status, want 3"

echo "ok"
