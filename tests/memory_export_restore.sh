#!/usr/bin/env bash
# Restore-drill guard for `memory export` and `memory restore`.
#
# Usage: bash tests/memory_export_restore.sh <memory-package-src>
#
# Runs entirely against temp directories: no root, no FalkorDB, no network. A
# fake `systemctl` on PATH records what restore asks systemd to do. It proves
# the properties the nightly export and the restore procedure rely on:
#
#   - a live WAL registry exports consistently (a concurrent, uncommitted write
#     is not half-copied into the snapshot, and the export does not need the
#     writer to stop);
#   - the manifest checksums verify, and a tampered file is refused;
#   - retention prunes only its own complete directories;
#   - a snapshot from a newer schema is refused;
#   - a graph snapshot from another run is rejected in favour of the
#     wipe-both-stores path, while a matching one is restored;
#   - a graph restore stops FalkorDB with the rest of the stack and restarts it;
#   - the live registry and its sidecars are parked before the swap, and a
#     failed ownership step leaves the previous registry in place;
#   - an export refuses to run while a restore holds its lock.
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

# `systemctl` is never real here: restore must ask for it, and the log is how
# this drill sees the stop/start order.
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

# A copy of an export directory under a new timestamp dir, so tampering and
# schema edits can be tested without destroying the original.
copy_export() { # <source-export> <destination-root> -> prints the copy
  local name dest
  name=$(basename "$1")
  dest="$2/$name"
  mkdir -p "$dest"
  cp -a "$1/." "$dest/"
  printf '%s\n' "$dest"
}

# Recompute the registry checksum in a copy's manifest after a schema bump, so
# the schema check (not the checksum) is what refuses it.
reseal_registry() { # <export-dir>
  python3 - "$1" <<'PY'
import hashlib, json, pathlib, sys

export = pathlib.Path(sys.argv[1])
manifest_path = export / "manifest.json"
db = export / "registry.sqlite"
manifest = json.loads(manifest_path.read_text())
manifest["files"]["registry.sqlite"] = {
    "sha256": hashlib.sha256(db.read_bytes()).hexdigest(),
    "bytes": db.stat().st_size,
}
manifest_path.write_text(json.dumps(manifest))
PY
}

# A registry that is not this export's, so a restore can be caught replacing it.
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

# ---------------------------------------------------------------- live export
STATE="$ROOT/state"
mkdir -p "$STATE"
READY="$ROOT/ready"

# The writer holds the database open in WAL mode with one committed episode and
# one uncommitted insert, exactly like the wrapper mid-write.
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

EXPORTS="$ROOT/exports"
# Not an export: retention must never touch it.
mkdir -p "$EXPORTS/operator-notes"
echo "keep me" >"$EXPORTS/notes.txt"
# A partial export: timestamp-shaped, but no manifest, so never a candidate.
mkdir -p "$EXPORTS/2020-01-01T00-00-00Z"

memory export --root "$EXPORTS" --state-dir "$STATE" --keep 2 >"$ROOT/export.log" 2>&1 ||
  { cat "$ROOT/export.log" >&2; fail "export failed while the writer was live"; }

EXPORT=$(find "$EXPORTS" -mindepth 1 -maxdepth 1 -type d -name '*-*-*T*-*-*Z' | sort | tail -1)
[ -n "$EXPORT" ] || fail "no timestamped export directory was created"
[ "$(basename "$EXPORT" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$')" = 1 ] ||
  fail "export directory $(basename "$EXPORT") is not a timestamp"

# The committed episode is there; the uncommitted one is not in the snapshot.
[ "$(wc -l <"$EXPORT/episodes.jsonl")" -eq 1 ] ||
  fail "episodes.jsonl does not hold exactly the committed episode"
grep -q '"origin_ref": "issue-1"' "$EXPORT/episodes.jsonl" || fail "typed provenance is missing"
grep -q '"content": "content 1"' "$EXPORT/episodes.jsonl" || fail "episode content is missing"
grep -q '"graphiti_uuid": "graph-1"' "$EXPORT/episodes.jsonl" || fail "graph identity is missing"
grep -q '"graph": null' "$EXPORT/manifest.json" || fail "a graph-less export must say so in the manifest"

# --------------------------------------------------------------- verification
memory restore "$EXPORT" --state-dir "$ROOT/dry" --graph-dir "$ROOT/graph-dry" --dry-run \
  >"$ROOT/verify.log" 2>&1 || { cat "$ROOT/verify.log" >&2; fail "checksum verification failed"; }
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

# ------------------------------------------------------------------ retention
for _ in 1 2; do
  sleep 1.1
  memory export --root "$EXPORTS" --state-dir "$STATE" --keep 2 >/dev/null 2>&1 ||
    fail "repeated export failed"
done
complete=$(find "$EXPORTS" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)
[ "$complete" -eq 2 ] || fail "retention kept $complete complete export directories, expected 2"
[ -d "$EXPORTS/operator-notes" ] || fail "retention deleted a directory that is not an export"
[ -f "$EXPORTS/notes.txt" ] || fail "retention deleted a file that is not an export"
[ -d "$EXPORTS/2020-01-01T00-00-00Z" ] || fail "retention deleted a partial export"

NEWEST=$(find "$EXPORTS" -mindepth 1 -maxdepth 1 -type d -name '*-*-*T*-*-*Z' | sort | tail -1)
# Every later export ran against the same live writer and still produced a
# snapshot; that is what "the service keeps running" means.
[ -s "$NEWEST/registry.sqlite" ] || fail "the newest export has no registry snapshot"

# ------------------------------------------------------------- tampered file
TAMPERED=$(copy_export "$NEWEST" "$ROOT/tampered")
echo '{"group": "injected"}' >>"$TAMPERED/episodes.jsonl"
rc=0
memory restore "$TAMPERED" --state-dir "$ROOT/tampered-state" \
  >"$ROOT/tampered.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a tampered export was not refused (exit $rc)"
grep -qi 'sha256' "$ROOT/tampered.log" || { cat "$ROOT/tampered.log" >&2; fail "tampering was not named"; }
[ ! -e "$ROOT/tampered-state/registry.sqlite" ] || fail "a refused export still wrote the registry"

# ------------------------------------------------------------- newer schema
NEWER=$(copy_export "$NEWEST" "$ROOT/newer")
python3 - "$NEWER/registry.sqlite" <<'PY'
import sqlite3, sys

conn = sqlite3.connect(sys.argv[1])
conn.execute("PRAGMA user_version = 99")
conn.commit()
conn.close()
PY
reseal_registry "$NEWER"
rc=0
memory restore "$NEWER" --state-dir "$ROOT/newer-state" >"$ROOT/newer.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a newer schema was not refused (exit $rc)"
grep -q 'newer schema' "$ROOT/newer.log" || { cat "$ROOT/newer.log" >&2; fail "the schema refusal is unclear"; }
[ ! -e "$ROOT/newer-state/registry.sqlite" ] || fail "a refused schema still wrote the registry"

# ------------------------------------------------------- graph: wipe both stores
MISMATCH=$(copy_export "$NEWEST" "$ROOT/mismatch")
STALE_NAME="graph-2026-01-01T00-00-00Z.rdb"
printf 'RDBstale' >"$MISMATCH/$STALE_NAME"
python3 - "$MISMATCH" "$STALE_NAME" <<'PY'
import hashlib, json, pathlib, sys

export = pathlib.Path(sys.argv[1])
graph = export / sys.argv[2]
manifest_path = export / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["graph"] = {
    "file": graph.name,
    "timestamp": "2026-01-01T00-00-00Z",
    "sha256": hashlib.sha256(graph.read_bytes()).hexdigest(),
    "bytes": graph.stat().st_size,
}
manifest_path.write_text(json.dumps(manifest))
PY
memory restore "$MISMATCH" --state-dir "$ROOT/mismatch-state" --graph-dir "$ROOT/mismatch-graph" --owner '' \
  >"$ROOT/mismatch.log" 2>&1 || { cat "$ROOT/mismatch.log" >&2; fail "a mismatched graph should not fail the restore"; }
grep -q 'does not belong to registry snapshot' "$ROOT/mismatch.log" ||
  { cat "$ROOT/mismatch.log" >&2; fail "the mismatched graph was not explained"; }
# A restored registry cannot re-extract: the advice is to wipe both stores.
grep -q 'memory-rebuild' "$ROOT/mismatch.log" ||
  { cat "$ROOT/mismatch.log" >&2; fail "the wipe-both-stores path was not offered"; }
grep -q 'wipe both stores' "$ROOT/mismatch.log" ||
  { cat "$ROOT/mismatch.log" >&2; fail "the rebuild advice does not say both stores go"; }
if grep -q 'rebuild it from the restored registry' "$ROOT/mismatch.log"; then
  cat "$ROOT/mismatch.log" >&2
  fail "the advice still claims a graph-only rebuild"
fi
[ ! -e "$ROOT/mismatch-graph/dump.rdb" ] || fail "a mismatched graph snapshot was restored anyway"
[ -s "$ROOT/mismatch-state/registry.sqlite" ] || fail "the registry was not restored from a mismatched export"

# ------------------------------------------------ matching: restore the graph
MATCHING=$(copy_export "$NEWEST" "$ROOT/matching")
SNAPSHOT=$(basename "$MATCHING")
printf 'RDBmatch' >"$MATCHING/graph-$SNAPSHOT.rdb"
python3 - "$MATCHING" "graph-$SNAPSHOT.rdb" <<'PY'
import hashlib, json, pathlib, sys

export = pathlib.Path(sys.argv[1])
graph = export / sys.argv[2]
manifest_path = export / "manifest.json"
manifest = json.loads(manifest_path.read_text())
snapshot = manifest["snapshot"]
manifest["graph"] = {
    "file": graph.name,
    "timestamp": snapshot,
    "sha256": hashlib.sha256(graph.read_bytes()).hexdigest(),
    "bytes": graph.stat().st_size,
}
manifest_path.write_text(json.dumps(manifest))
PY
: >"$SYSTEMCTL_LOG"
memory restore "$MATCHING" --state-dir "$ROOT/matching-state" --graph-dir "$ROOT/matching-graph" --owner '' \
  >"$ROOT/matching.log" 2>&1 || { cat "$ROOT/matching.log" >&2; fail "a matching export failed to restore"; }
grep -q 'graph: restored the matching snapshot' "$ROOT/matching.log" ||
  { cat "$ROOT/matching.log" >&2; fail "a matching graph snapshot was not restored"; }
grep -q 'restarted memory-falkordb' "$ROOT/matching.log" ||
  { cat "$ROOT/matching.log" >&2; fail "the graph restore did not restart FalkorDB"; }
cmp -s "$ROOT/matching-graph/dump.rdb" "$MATCHING/graph-$SNAPSHOT.rdb" ||
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

# The restored registry opens with the same rows as the export.
python3 - "$ROOT/matching-state/registry.sqlite" <<'PY'
import sqlite3, sys

conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
count = conn.execute("SELECT count(*) FROM episodes").fetchone()[0]
assert count >= 1, "restored registry is empty"
PY

# ------------------------------------------------- parking the live registry
PARK_STATE="$ROOT/park-state"
seed_registry "$PARK_STATE"
cp "$PARK_STATE/registry.sqlite" "$ROOT/seed-registry.sqlite"
memory restore "$MATCHING" --state-dir "$PARK_STATE" --graph-dir "$ROOT/park-graph" --owner '' \
  >"$ROOT/park.log" 2>&1 || { cat "$ROOT/park.log" >&2; fail "restore over a live registry failed"; }
PARKED_REGISTRY="$PARK_STATE/registry.sqlite.pre-restore-$SNAPSHOT"
[ -f "$PARKED_REGISTRY" ] || fail "the live registry was not parked before the swap"
cmp -s "$PARKED_REGISTRY" "$ROOT/seed-registry.sqlite" ||
  fail "the parked registry is not the previous one"
[ "$(cat "$PARKED_REGISTRY-wal")" = "stale-wal" ] || fail "the parked registry's -wal is missing"
[ "$(cat "$PARKED_REGISTRY-shm")" = "stale-shm" ] || fail "the parked registry's -shm is missing"
[ ! -e "$PARK_STATE/registry.sqlite-wal" ] || fail "the replaced registry's -wal survived the swap"
[ ! -e "$PARK_STATE/registry.sqlite-shm" ] || fail "the replaced registry's -shm survived the swap"
grep -q 'previous registry:' "$ROOT/park.log" ||
  { cat "$ROOT/park.log" >&2; fail "the restore did not report where the previous registry went"; }

# --------------------------------------------------- failed ownership aborts
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

# ---------------------------------------------- export refuses during restore
count_before=$(find "$EXPORTS" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)
: >"$STATE/.restore-in-progress"
rc=0
memory export --root "$EXPORTS" --state-dir "$STATE" --keep 2 >"$ROOT/locked.log" 2>&1 || rc=$?
rm -f "$STATE/.restore-in-progress"
[ "$rc" -eq 1 ] || fail "an export ran while a restore held the lock (exit $rc)"
grep -q 'restore' "$ROOT/locked.log" || { cat "$ROOT/locked.log" >&2; fail "the lock refusal was not explained"; }
count_after=$(find "$EXPORTS" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)
[ "$count_before" -eq "$count_after" ] || fail "a refused export still wrote a directory"

# ------------------------------------------------- a failed graph fails the run
FAIL_EXPORTS="$ROOT/exports-fail"
GRAPH_FAIL="$ROOT/graph-fail"
mkdir -p "$GRAPH_FAIL"
printf 'RDBfake' >"$GRAPH_FAIL/dump.rdb"
rc=0
memory export --root "$FAIL_EXPORTS" --state-dir "$STATE" --keep 1 \
  --graph-dir "$GRAPH_FAIL" --graph-url "redis://127.0.0.1:1" >"$ROOT/graph-fail.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { cat "$ROOT/graph-fail.log" >&2; fail "a failed graph snapshot did not fail the export (exit $rc)"; }
grep -q 'graph' "$ROOT/graph-fail.log" || { cat "$ROOT/graph-fail.log" >&2; fail "the graph failure was not reported"; }
FAILED_EXPORT=$(find "$FAIL_EXPORTS" -mindepth 1 -maxdepth 1 -type d -name '*-*-*T*-*-*Z' | head -1)
[ -n "$FAILED_EXPORT" ] || fail "a failed graph snapshot lost the registry export"
[ -s "$FAILED_EXPORT/registry.sqlite" ] || fail "the registry snapshot is missing after a graph failure"
[ -s "$FAILED_EXPORT/manifest.json" ] || fail "the manifest is missing after a graph failure"
grep -q '"graph_error"' "$FAILED_EXPORT/manifest.json" || fail "the manifest does not record the graph error"

echo "OK: live export, checksums, retention, schema, graph restore, parking, ownership, and the restore lock behave"
