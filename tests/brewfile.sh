#!/usr/bin/env bash
# The work Mac's Brewfile declares exactly the agreed set and never cleans up: `brew bundle` must
# only add, so the employer's own packages stay untouched.
# Usage: brewfile.sh <Brewfile>
set -euo pipefail

brewfile=$1

fail() {
  echo "FAIL $*" >&2
  exit 1
}

want=$(printf '%s\n' aerospace caffeine docker-desktop fuse-t gitify kitty nvidia-geforce-now steam tailscale-app)
have=$(sed -n 's/^\(cask\|brew\) "\([^"]*\)".*/\2/p' "$brewfile" | sed 's|.*/||' | sort)
[ "$have" = "$want" ] || fail "declared packages differ from the agreed set:
$have"

# `uv` comes from nix; nothing may reinstall it through brew.
if grep -q '"uv"' "$brewfile"; then fail "uv must not be a brew package"; fi

# `brew bundle cleanup` uninstalls whatever the file omits.
if grep -qi 'cleanup' "$brewfile"; then fail "the Brewfile must not clean up"; fi

echo "ok"
