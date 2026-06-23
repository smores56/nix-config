#!/usr/bin/env bash
# Accepts a bash script from stdin or as a file argument, writes it to a temp
# file, and executes with bash. Ensures bash quoting rules apply regardless of
# the caller's shell (zsh, fish, etc.).
set -euo pipefail

if [[ $# -gt 0 && -f "$1" ]]; then
	script="$1"
	shift
else
	script=$(mktemp /tmp/gh-cmd.XXXXXX.sh)
	cat >"$script"
	trap "rm -f '$script'" EXIT
fi

bash "$script" "$@"
