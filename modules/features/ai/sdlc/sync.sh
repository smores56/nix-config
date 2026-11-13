#!/usr/bin/env bash
# Re-vendor the pinned upstream `smores56/sdlc` source into this directory.
#
# The repo is private, so `package.nix` builds the vendored tree instead of fetching it.
# Run this after an upstream change, review the diff like any other code change, and commit
# the updated files together with UPSTREAM_REV.
#
#   sync.sh <git-rev>        # e.g. sync.sh 6f6dde8caf7c7049fc5bb1009261410fa8f0eb44
set -euo pipefail

rev=${1:?usage: sync.sh <git-rev>}
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=${SDLC_REPO:-smores56/sdlc}
tests=${dir}/../../../tests/test_sdlc_issues.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() {
  mkdir -p "$(dirname "${work}/$1")"
  gh api "repos/${repo}/contents/$1?ref=${rev}" --jq .content | base64 -d >"${work}/$1"
}

fetch pyproject.toml
fetch sdlc_issues.py
fetch tests/test_sdlc_issues.py

install -m 0644 "$work/pyproject.toml" "$dir/pyproject.toml"
install -m 0644 "$work/sdlc_issues.py" "$dir/sdlc_issues.py"

# The vendored suite is upstream's, with the CLI path pointed at this checkout.
sed 's#^MODULE_DIR = os.path.join(HERE, "..")$#MODULE_DIR = os.path.join(HERE, "..", "modules", "features", "ai", "sdlc")#' \
  "$work/tests/test_sdlc_issues.py" >"$work/test_sdlc_issues.py"
install -m 0644 "$work/test_sdlc_issues.py" "$tests"

printf '%s\n' "$rev" >"$dir/UPSTREAM_REV"
printf 'vendored %s at %s\n' "$repo" "$rev"
