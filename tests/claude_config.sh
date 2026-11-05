#!/usr/bin/env bash
# claude-config disables auto-memory in Claude's settings and registers MCP servers in
# ~/.claude.json, idempotently and without touching any other key.
# Usage: claude_config.sh <claude-config>
set -euo pipefail

bin=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
mkdir -p "$HOME/.claude"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

servers=$work/servers.json
echo '{"memory":{"type":"stdio","command":"/bin/shim","args":[],"env":{"A":"1"}}}' >"$servers"

echo '{"theme":"dark","env":{"X":"1"}}' >"$HOME/.claude/settings.json"
echo '{"numStartups":3,"mcpServers":{"other":{"command":"x"},"memory":{"command":"stale"}}}' >"$HOME/.claude.json"

"$bin" "$servers"

jq -e '.autoMemoryEnabled == false and .theme == "dark" and .env.X == "1"' "$HOME/.claude/settings.json" >/dev/null ||
  fail "settings.json: auto-memory not disabled or other keys lost"
jq -e '.numStartups == 3 and .mcpServers.other.command == "x" and .mcpServers.memory.command == "/bin/shim"' "$HOME/.claude.json" >/dev/null ||
  fail ".claude.json: memory not replaced or other keys lost"

before=$(cat "$HOME/.claude/settings.json" "$HOME/.claude.json")
"$bin" "$servers"
[ "$before" = "$(cat "$HOME/.claude/settings.json" "$HOME/.claude.json")" ] || fail "second run changed files"

# Fresh machine: neither file exists.
rm -rf "$HOME/.claude" "$HOME/.claude.json"
"$bin" "$servers"
jq -e '.autoMemoryEnabled == false' "$HOME/.claude/settings.json" >/dev/null || fail "fresh settings.json"
jq -e '.mcpServers.memory.env.A == "1"' "$HOME/.claude.json" >/dev/null || fail "fresh .claude.json"

# No servers: .claude.json untouched.
rm "$HOME/.claude.json"
echo '{}' >"$work/none.json"
"$bin" "$work/none.json"
[ ! -e "$HOME/.claude.json" ] || fail "created .claude.json with no servers"

# Unparseable files are left alone and the run fails.
echo 'not json' >"$HOME/.claude/settings.json"
if "$bin" "$servers" 2>/dev/null; then fail "accepted invalid settings.json"; fi
[ "$(cat "$HOME/.claude/settings.json")" = "not json" ] || fail "rewrote invalid settings.json"

echo ok
