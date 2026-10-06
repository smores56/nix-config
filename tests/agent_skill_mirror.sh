#!/usr/bin/env bash
# agent-skill-mirror links tool-installed Claude skills (real dirs with a
# SKILL.md) into the shared agents dir, skips store-managed links and
# non-skills, leaves foreign entries alone, and prunes its own dead links.
#
# Usage: agent_skill_mirror.sh <agent-skill-mirror>
set -euo pipefail

mirror=$1
src=$PWD/claude/skills
dst=$PWD/agents/skills
failures=0

check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

mkdir -p "$src/team-review" "$src/team-old" "$src/not-a-skill" "$PWD/store/managed" "$dst/foreign"
touch "$src/team-review/SKILL.md" "$src/team-old/SKILL.md" "$PWD/store/managed/SKILL.md"
ln -s "$PWD/store/managed" "$src/managed"
ln -s "$PWD/store/managed" "$dst/managed"
mkdir -p "$src/foreign" && touch "$src/foreign/SKILL.md"

out=$("$mirror" "$src" "$dst" 2>&1) && rc=0 || rc=$?
check exit "$rc" 0
check mirrored "$(readlink "$dst/team-review")" "$src/team-review"
check not-a-skill "$([ -e "$dst/not-a-skill" ] && echo yes || echo no)" no
check managed-untouched "$(readlink "$dst/managed")" "$PWD/store/managed"
check foreign-kept "$([ -d "$dst/foreign" ] && [ ! -L "$dst/foreign" ] && echo yes)" yes
check foreign-warned "$(grep -c -- "$dst/foreign exists" <<<"$out")" 1

rm -r "$src/team-old"
"$mirror" "$src" "$dst" 2>/dev/null
check pruned "$([ -L "$dst/team-old" ] && echo yes || echo no)" no
check kept "$(readlink "$dst/team-review")" "$src/team-review"

check missing-src "$("$mirror" "$PWD/nope" "$dst" 2>&1; echo "rc=$?")" "rc=0"

if ((failures)); then exit 1; fi
echo "agent skill mirror: ok"
