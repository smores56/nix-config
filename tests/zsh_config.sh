#!/usr/bin/env bash
# Parses every generated zsh startup file (`zsh -n`), so a quoting slip in
# a Nix-rendered snippet fails the build instead of a login.
#
# Usage: zsh_config.sh <file>...
set -euo pipefail

for f in "$@"; do
  zsh -n "$f" || { echo "FAIL: $f does not parse"; exit 1; }
done
echo "zsh config: ok"
