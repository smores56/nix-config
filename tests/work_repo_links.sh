#!/usr/bin/env bash
# work-repo-links points <code-root>/<org> at the flat work folder, accepts
# links that are already right, replaces empty org dirs, and only warns
# (never moves data) about anything else.
#
# Usage: work_repo_links.sh <work-repo-links>
set -euo pipefail

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

mkdir -p "$root/empty" "$root/full/repo" "$PWD/other"
ln -s "$PWD/other" "$root/elsewhere"

out=$("$links" "$flat" "$root" fresh empty full elsewhere 2>&1)
check flat-created "$([ -d "$flat" ] && echo yes)" yes
check fresh "$(readlink "$root/fresh")" "$flat"
check empty-replaced "$(readlink "$root/empty")" "$flat"
check full-kept "$([ -d "$root/full/repo" ] && [ ! -L "$root/full" ] && echo yes)" yes
check full-warned "$(grep -c "full" <<<"$out")" 1
check elsewhere-kept "$(readlink "$root/elsewhere")" "$PWD/other"
check elsewhere-warned "$(grep -c "elsewhere" <<<"$out")" 1

again=$("$links" "$flat" "$root" fresh 2>&1)
check idempotent "$again" ""

if ((failures)); then exit 1; fi
echo "work repo links: ok"
