#!/usr/bin/env bash
# Regression guard for the drill's database phase.
#
# Usage: bash tests/restore_drill.sh <path-to-restore-drill.sh>
#
# A dataset without a database has no current/db/*.dump. The glob is then
# empty, and taking the last element of an empty array used to abort the drill
# with `dumps: bad array subscript` instead of reporting a missing dump. The
# drill is driven in DB-only mode with rclone and runuser stubbed out, so no
# host lock, Proton remote, or Postgres is touched.
set -euo pipefail

DRILL=${1:?usage: restore_drill.sh <path-to-restore-drill.sh>}
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  [ -f "$ROOT/out" ] && { echo "--- drill output ---" >&2; cat "$ROOT/out" >&2; }
  exit 1
}

mkdir -p "$ROOT/src" "$ROOT/local"
# Exported functions are inherited by the drill's child bash, which avoids
# shebang paths that do not exist in a Nix build sandbox.
rclone() {
  if [ "${1:-}" = version ]; then echo "rclone v0.0.0-test"; return 0; fi
  return 1
}
runuser() { return 0; }
export -f rclone runuser

rc=0
MEDIA_BACKUP_LOCK=$ROOT/lock \
  SRC=$ROOT/src \
  LOC=$ROOT/local \
  DRILL_ONLY_DB=1 \
  DRILL_PG_DB=immich \
  bash "$DRILL" Music >"$ROOT/out" 2>&1 || rc=$?

[ "$rc" -eq 1 ] || fail "expected exit 1 for a dataset without a dump, got $rc"
grep -q 'bad array subscript' "$ROOT/out" && fail "empty dump glob still crashes the drill"
grep -qF "FAIL no dump under $ROOT/local/db" "$ROOT/out" ||
  fail "missing the explicit no-dump failure"
grep -q 'DRILL FAIL' "$ROOT/out" || fail "missing the drill summary"

echo "OK: an empty dump glob reports a missing dump without crashing"
