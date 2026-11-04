#!/usr/bin/env bash
# Restore-drill guard for `memory export` and `memory restore`; runs against temp dirs with a fake
# `systemctl` that records what restore asks systemd to do.
#
# Usage: bash tests/memory_export_restore.sh <memory-package-src>
set -euo pipefail

SRC=${1:?usage: memory_export_restore.sh <memory-package-src>}
export PYTHONPATH="$SRC"

ROOT=$(mktemp -d)
WRITER=""
cleanup() {
  [ -n "$WRITER" ] && kill "$WRITER" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

memory() { python3 -m memory_mcp.export "$@"; }

# systemctl is never real here: the log is how this drill sees the stop/start order.
FAKE_BIN="$ROOT/bin"
SYSTEMCTL_LOG="$ROOT/systemctl.log"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
SH
chmod +x "$FAKE_BIN/systemctl"
export SYSTEMCTL_LOG
export PATH="$FAKE_BIN:$PATH"
: >"$SYSTEMCTL_LOG"

copy_export() { # <source-export> <destination> -> prints the copy
  mkdir -p "$2"
  cp -a "$1/." "$2/"
  printf '%s\n' "$2"
}

seed_registry() { # <state-dir> -> writes a marker registry plus stale sidecars
  mkdir -p "$1"
  python3 - "$1" <<'PY'
import pathlib, sqlite3, sys

state = pathlib.Path(sys.argv[1])
conn = sqlite3.connect(state / "registry.sqlite")
conn.execute("CREATE TABLE marker (value TEXT)")
conn.execute("INSERT INTO marker VALUES ('previous registry')")
conn.commit()
conn.close()
for suffix in ("-wal", "-shm"):
    (state / f"registry.sqlite{suffix}").write_text(f"stale{suffix}")
PY
}

STATE="$ROOT/state"
mkdir -p "$STATE"
READY="$ROOT/ready"

python3 - "$STATE" "$READY" <<'PY' &
import pathlib, sqlite3, sys, time

state, ready = sys.argv[1], sys.argv[2]
from memory_mcp.registry import Registry

Registry(state)
conn = sqlite3.connect(f"{state}/registry.sqlite")
conn.execute("PRAGMA journal_mode=WAL")
conn.execute(
    "INSERT INTO episodes (group_id, content_hash, uuid, name, content, kind, origin,"
    " origin_ref, actor, cwd, tags, valid_at, created_at, status, graphiti_uuid)"
    " VALUES ('owner--repo', 'aaa', 'uuid-1', 'episode 1', 'content 1', 'text', 'sdlc',"
    " 'issue-1', 'cli', '/home/smores/code/x', '[\"decision\"]', '2026-10-01T00:00:00Z',"
    " '2026-10-01T00:00:00Z', 'active', 'graph-1')"
)
conn.commit()
conn.execute("BEGIN IMMEDIATE")
conn.execute(
    "INSERT INTO episodes (group_id, content_hash, uuid, name, content, valid_at, created_at)"
    " VALUES ('owner--repo', 'uncommitted', 'uuid-2', 'episode 2', 'content 2',"
    " '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')"
)
pathlib.Path(ready).write_text("ready")
time.sleep(120)
PY
WRITER=$!

for _ in $(seq 100); do
  [ -f "$READY" ] && break
  sleep 0.1
done
[ -f "$READY" ] || fail "the WAL writer never became ready"

EXPORT="$ROOT/exports"

memory export --root "$EXPORT" --state-dir "$STATE" >"$ROOT/export.log" 2>&1 ||
  { cat "$ROOT/export.log" >&2; fail "export failed while the writer was live"; }

[ -s "$EXPORT/registry.sqlite" ] || fail "the export has no registry snapshot"
[ "$(wc -l <"$EXPORT/episodes.jsonl")" -eq 1 ] ||
  fail "episodes.jsonl does not hold exactly the committed episode"
grep -q '"origin_ref": "issue-1"' "$EXPORT/episodes.jsonl" || fail "typed provenance is missing"
grep -q '"content": "content 1"' "$EXPORT/episodes.jsonl" || fail "episode content is missing"
grep -q '"graphiti_uuid": "graph-1"' "$EXPORT/episodes.jsonl" || fail "graph identity is missing"
[ ! -e "$EXPORT/graph.rdb" ] || fail "a graph-less export left a graph snapshot"

memory restore "$EXPORT" --state-dir "$ROOT/dry" --graph-dir "$ROOT/graph-dry" --dry-run \
  >"$ROOT/verify.log" 2>&1 || { cat "$ROOT/verify.log" >&2; fail "verification failed"; }
grep -q '^verified ' "$ROOT/verify.log" || fail "verify did not report success"
[ ! -d "$ROOT/dry" ] || fail "a dry run wrote the registry"
[ ! -s "$SYSTEMCTL_LOG" ] || fail "a dry run called systemctl"

# A real restore may not skip the stop: swapping files under running services
# is what the stop exists to prevent.
rc=0
memory restore "$EXPORT" --state-dir "$ROOT/no-stop" --no-stop >"$ROOT/no-stop.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "--no-stop without --dry-run was not refused (exit $rc)"
grep -q -- '--no-stop' "$ROOT/no-stop.log" || { cat "$ROOT/no-stop.log" >&2; fail "--no-stop refusal is unclear"; }
[ ! -e "$ROOT/no-stop/registry.sqlite" ] || fail "--no-stop still wrote the registry"

# A second export replaces the first in place; the writer stays live throughout.
memory export --root "$EXPORT" --state-dir "$STATE" >/dev/null 2>&1 || fail "repeated export failed"
[ "$(find "$EXPORT" -mindepth 1 -maxdepth 1 | grep -v -e '-wal$' -e '-shm$' | wc -l)" -eq 2 ] ||
  fail "a repeated export did not replace the files in place"

CORRUPT=$(copy_export "$EXPORT" "$ROOT/corrupt")
printf 'not a database' >"$CORRUPT/registry.sqlite"
rm -f "$CORRUPT/registry.sqlite-wal" "$CORRUPT/registry.sqlite-shm"
rc=0
memory restore "$CORRUPT" --state-dir "$ROOT/corrupt-state" >"$ROOT/corrupt.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a corrupt registry was not refused (exit $rc)"
[ ! -e "$ROOT/corrupt-state/registry.sqlite" ] || fail "a refused export still wrote the registry"

for version in 99 1; do
  BAD=$(copy_export "$EXPORT" "$ROOT/schema-$version")
  python3 - "$BAD/registry.sqlite" "$version" <<'PY'
import sqlite3, sys

conn = sqlite3.connect(sys.argv[1])
conn.execute(f"PRAGMA user_version = {sys.argv[2]}")
conn.commit()
conn.close()
PY
  rc=0
  memory restore "$BAD" --state-dir "$ROOT/schema-$version-state" >"$ROOT/schema.log" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "schema $version was not refused (exit $rc)"
  grep -q 'schema' "$ROOT/schema.log" || { cat "$ROOT/schema.log" >&2; fail "the schema refusal is unclear"; }
  [ ! -e "$ROOT/schema-$version-state/registry.sqlite" ] || fail "a refused schema still wrote the registry"
done

# Without a graph snapshot the registry restores alone and the advice is a reindex.
memory restore "$EXPORT" --state-dir "$ROOT/nograph-state" --graph-dir "$ROOT/nograph-graph" --owner '' \
  >"$ROOT/nograph.log" 2>&1 || { cat "$ROOT/nograph.log" >&2; fail "a graph-less export failed to restore"; }
grep -q 'memory reindex --all' "$ROOT/nograph.log" ||
  { cat "$ROOT/nograph.log" >&2; fail "the reindex advice is missing"; }
[ ! -e "$ROOT/nograph-graph/dump.rdb" ] || fail "a graph appeared from nowhere"
[ -s "$ROOT/nograph-state/registry.sqlite" ] || fail "the registry was not restored"

MATCHING=$(copy_export "$EXPORT" "$ROOT/matching")
printf 'RDBmatch' >"$MATCHING/graph.rdb"
: >"$SYSTEMCTL_LOG"
memory restore "$MATCHING" --state-dir "$ROOT/matching-state" --graph-dir "$ROOT/matching-graph" --owner '' \
  >"$ROOT/matching.log" 2>&1 || { cat "$ROOT/matching.log" >&2; fail "a graph export failed to restore"; }
grep -q 'graph: restored the matching snapshot' "$ROOT/matching.log" ||
  { cat "$ROOT/matching.log" >&2; fail "the graph snapshot was not restored"; }
grep -q 'restarted memory-falkordb' "$ROOT/matching.log" ||
  { cat "$ROOT/matching.log" >&2; fail "the graph restore did not restart FalkorDB"; }
cmp -s "$ROOT/matching-graph/dump.rdb" "$MATCHING/graph.rdb" ||
  fail "the restored dump.rdb does not match the export's graph snapshot"

# The stop must reach FalkorDB (a running instance rewrites its AOF over the
# restored data) and the restart must follow the stop.
stop_line=$(grep -n '^stop ' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
start_line=$(grep -n '^start ' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
[ -n "$stop_line" ] || { cat "$SYSTEMCTL_LOG" >&2; fail "the restore never stopped the services"; }
[ -n "$start_line" ] || { cat "$SYSTEMCTL_LOG" >&2; fail "the graph restore never restarted FalkorDB"; }
[ "$stop_line" -lt "$start_line" ] || fail "the services started before they were stopped"
sed -n "${stop_line}p" "$SYSTEMCTL_LOG" | grep -q 'memory-falkordb' ||
  fail "the stop set omits memory-falkordb"
sed -n "${start_line}p" "$SYSTEMCTL_LOG" | grep -q 'memory-falkordb' ||
  fail "the restart does not start memory-falkordb"
[ ! -e "$ROOT/matching-state/.restore-in-progress" ] ||
  fail "a successful restore left the restore lock behind"

python3 - "$ROOT/matching-state/registry.sqlite" <<'PY'
import sqlite3, sys

conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
count = conn.execute("SELECT count(*) FROM episodes").fetchone()[0]
assert count >= 1, "restored registry is empty"
PY

PARK_STATE="$ROOT/park-state"
seed_registry "$PARK_STATE"
cp "$PARK_STATE/registry.sqlite" "$ROOT/seed-registry.sqlite"
memory restore "$MATCHING" --state-dir "$PARK_STATE" --graph-dir "$ROOT/park-graph" --owner '' \
  >"$ROOT/park.log" 2>&1 || { cat "$ROOT/park.log" >&2; fail "restore over a live registry failed"; }
PARKED_REGISTRY=$(find "$PARK_STATE" -maxdepth 1 -name 'registry.sqlite.pre-restore-*' ! -name '*-wal' ! -name '*-shm')
[ -f "$PARKED_REGISTRY" ] || fail "the live registry was not parked before the swap"
cmp -s "$PARKED_REGISTRY" "$ROOT/seed-registry.sqlite" ||
  fail "the parked registry is not the previous one"
[ "$(cat "$PARKED_REGISTRY-wal")" = "stale-wal" ] || fail "the parked registry's -wal is missing"
[ "$(cat "$PARKED_REGISTRY-shm")" = "stale-shm" ] || fail "the parked registry's -shm is missing"
[ ! -e "$PARK_STATE/registry.sqlite-wal" ] || fail "the replaced registry's -wal survived the swap"
[ ! -e "$PARK_STATE/registry.sqlite-shm" ] || fail "the replaced registry's -shm survived the swap"
grep -q 'previous registry:' "$ROOT/park.log" ||
  { cat "$ROOT/park.log" >&2; fail "the restore did not report where the previous registry went"; }

OWNER_STATE="$ROOT/owner-state"
seed_registry "$OWNER_STATE"
cp "$OWNER_STATE/registry.sqlite" "$ROOT/owner-registry.sqlite"
rc=0
memory restore "$MATCHING" --state-dir "$OWNER_STATE" --graph-dir "$ROOT/owner-graph" \
  --owner memory-pre-restore-does-not-exist >"$ROOT/owner.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a failed ownership step did not exit non-zero (exit $rc)"
grep -q 'does not exist' "$ROOT/owner.log" || { cat "$ROOT/owner.log" >&2; fail "the ownership failure was not named"; }
grep -q 'pre-restore' "$ROOT/owner.log" || { cat "$ROOT/owner.log" >&2; fail "the parked registry was not offered"; }
cmp -s "$OWNER_STATE/registry.sqlite" "$ROOT/owner-registry.sqlite" ||
  fail "a failed ownership step replaced the previous registry"
[ -e "$OWNER_STATE/registry.sqlite-wal" ] || fail "the previous registry's -wal was dropped after a failed install"
[ ! -e "$OWNER_STATE/registry.sqlite.restore-tmp" ] || fail "a failed install left its staging file behind"
[ -e "$OWNER_STATE/.restore-in-progress" ] ||
  fail "a failed restore removed the lock that marks it unreconciled"

: >"$STATE/.restore-in-progress"
rc=0
memory export --root "$EXPORT" --state-dir "$STATE" >"$ROOT/locked.log" 2>&1 || rc=$?
rm -f "$STATE/.restore-in-progress"
[ "$rc" -eq 1 ] || fail "an export ran while a restore held the lock (exit $rc)"
grep -q 'restore' "$ROOT/locked.log" || { cat "$ROOT/locked.log" >&2; fail "the lock refusal was not explained"; }

# A failed graph snapshot fails the export but keeps the registry files, and
# drops the previous graph so it never pairs with the new registry.
FAIL_EXPORT="$ROOT/exports-fail"
GRAPH_FAIL="$ROOT/graph-fail"
mkdir -p "$GRAPH_FAIL" "$FAIL_EXPORT"
printf 'RDBfake' >"$GRAPH_FAIL/dump.rdb"
printf 'RDBprevious' >"$FAIL_EXPORT/graph.rdb"
rc=0
memory export --root "$FAIL_EXPORT" --state-dir "$STATE" \
  --graph-dir "$GRAPH_FAIL" --graph-url "redis://127.0.0.1:1" >"$ROOT/graph-fail.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { cat "$ROOT/graph-fail.log" >&2; fail "a failed graph snapshot did not fail the export (exit $rc)"; }
grep -q 'graph' "$ROOT/graph-fail.log" || { cat "$ROOT/graph-fail.log" >&2; fail "the graph failure was not reported"; }
[ -s "$FAIL_EXPORT/registry.sqlite" ] || fail "the registry snapshot is missing after a graph failure"
[ ! -e "$FAIL_EXPORT/graph.rdb" ] || fail "a failed graph snapshot left the previous graph beside the new registry"

echo "OK: live export, schema and corruption refusal, graph restore, parking, ownership, and the restore lock behave"
