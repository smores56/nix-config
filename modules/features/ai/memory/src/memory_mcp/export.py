"""Export the registry and a matching FalkorDB snapshot; verify and restore them.

One export is one timestamped directory under the export root:

- ``registry.sqlite``: a consistent copy of the registry, taken with SQLite's
  online backup API, so it works while the wrapper keeps writing under WAL;
- ``episodes.jsonl``: every episode with its typed provenance *and* its content,
  so memory is readable even without SQLite or this code;
- ``manifest.json``: creation time, schema version, per-status counts, and the
  sha256 of every file (plus the graph snapshot, when one was taken);
- ``graph-<same timestamp>.rdb``: a FalkorDB snapshot, when ``BGSAVE`` finished.

The registry is the system of record and the graph is a derived index, so the
graph step is best-effort: if FalkorDB does not answer, the export still
succeeds and the manifest records why the graph is missing. Restore prefers the
registry, and accepts a graph snapshot only when it was taken at the same
timestamp; otherwise it refuses it and tells the operator to rebuild the graph.

Only the optional ``redis`` client (imported lazily) is outside the standard
library, so export and restore run on a machine without the MCP dependencies.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence

from .registry import SCHEMA_VERSION, STATUSES

REGISTRY_FILE = "registry.sqlite"
EPISODES_FILE = "episodes.jsonl"
MANIFEST_FILE = "manifest.json"
GRAPH_FILE = "graph-{snapshot}.rdb"

DEFAULT_ROOT = "/var/lib/memory/export"
DEFAULT_STATE_DIR = "/var/lib/memory"
DEFAULT_GRAPH_DIR = "/var/lib/memory/falkordb"
DEFAULT_GRAPH_URL = "redis://127.0.0.1:6379"
DEFAULT_KEEP = 7
DEFAULT_GRAPH_TIMEOUT = 120.0
# The services that write the registry or talk to the graph. Restore stops them
# so nothing holds the database open or writes into the graph mid-restore.
MEMORY_UNITS = ("memory-mcp", "memory-graphiti-mcp", "memory-llm-proxy")
DEFAULT_OWNER = "memory:memory"
# FalkorDB runs with `appendonly yes`; Redis loads the AOF in preference to the
# RDB, so a restored `dump.rdb` needs the old AOF out of the way to be loaded.
AOF_NAMES = ("appendonlydir", "appendonly.aof")
# A dump.rdb older than this below the BGSAVE start means the save did not
# actually rewrite it (clock skew between us and FalkorDB is not a factor: both
# are the same host).
DUMP_MTIME_SLACK = 2.0
BGSAVE_POLL_INTERVAL = 0.5

TIMESTAMP_FORMAT = "%Y-%m-%dT%H-%M-%SZ"
TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z$")
GRAPH_NAME_PATTERN = re.compile(r"^graph-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)\.rdb$")

# Registry column -> episode JSON key. `group_id` is the registry's spelling;
# the export speaks the same vocabulary as the MCP surface.
EPISODE_COLUMNS: tuple[tuple[str, str], ...] = (
    ("group_id", "group"),
    ("uuid", "uuid"),
    ("content_hash", "content_hash"),
    ("name", "name"),
    ("kind", "kind"),
    ("origin", "origin"),
    ("origin_ref", "origin_ref"),
    ("actor", "actor"),
    ("cwd", "cwd"),
    ("tags", "tags"),
    ("valid_at", "valid_at"),
    ("created_at", "created_at"),
    ("status", "status"),
    ("graphiti_uuid", "graphiti_uuid"),
    ("promoted_from_group", "promoted_from_group"),
    ("promoted_by", "promoted_by"),
    ("promoted_at", "promoted_at"),
    ("tombstoned_at", "tombstoned_at"),
    ("tombstone_reason", "tombstone_reason"),
    ("content", "content"),
)


class ExportError(RuntimeError):
    """The export could not be taken or restored."""


class GraphSnapshotError(RuntimeError):
    """The graph could not be snapshotted; the registry export still stands."""


class ExportInvalid(RuntimeError):
    """An export directory failed verification and must not be restored."""


def timestamp(now: datetime | None = None) -> str:
    """A sortable, filename-safe UTC timestamp (``2026-10-22T03-00-00Z``)."""
    moment = now or datetime.now(timezone.utc)
    return moment.astimezone(timezone.utc).strftime(TIMESTAMP_FORMAT)


def is_snapshot_name(name: str) -> bool:
    """Only these names are export directories; retention never touches others."""
    return TIMESTAMP_PATTERN.match(name) is not None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _adopt_sidecars(path: Path) -> None:
    """Give WAL side files we may have created back to the registry's owner.

    The fallback below opens read/write, and SQLite then creates `-wal`/`-shm`
    if the wrapper had no connection open at that instant. Those files inherit
    root's ownership, which would leave the `memory` user unable to write the
    database. Root can hand them to the database's owner immediately, so the
    wrapper never notices the exporter ran.
    """
    if os.geteuid() != 0:
        return
    try:
        stat = path.stat()
    except OSError:
        return
    for suffix in ("-wal", "-shm"):
        sidecar = path.with_name(path.name + suffix)
        try:
            os.chown(sidecar, stat.st_uid, stat.st_gid)
        except OSError:
            continue


def _open_source(path: Path) -> sqlite3.Connection:
    """Open the live registry read-only, falling back to a read/write handle.

    A read-only open of a WAL database needs the ``-shm`` file; it exists while
    the wrapper has the database open, but a read-only handle cannot create it
    between connections. The fallback opens read/write (the exporter runs as
    root) without writing anything: the backup API only reads.
    """
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
        return conn
    except sqlite3.Error:
        conn = sqlite3.connect(f"file:{path}?mode=rw", uri=True, timeout=30)
        _adopt_sidecars(path)
        return conn


def snapshot_registry(source: Path, dest: Path) -> None:
    """Copy the live registry with SQLite's backup API (consistent under WAL).

    One backup step reads the database in a single transaction, so the
    snapshot is a point-in-time image even while the wrapper writes.
    """
    if not source.is_file():
        raise ExportError(f"no registry at {source}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    for stale in (dest, dest.with_name(dest.name + "-wal"), dest.with_name(dest.name + "-shm")):
        if stale.exists():
            stale.unlink()
    src = _open_source(source)
    dst = sqlite3.connect(dest)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()


def schema_version(db: Path) -> int:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        return int(conn.execute("PRAGMA user_version").fetchone()[0])
    finally:
        conn.close()


def status_counts(db: Path) -> dict[str, int]:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = conn.execute(
            "SELECT "
            + ", ".join(f"SUM(CASE WHEN status = '{status}' THEN 1 ELSE 0 END)" for status in STATUSES)
            + ", COUNT(*) FROM episodes"
        ).fetchone()
    finally:
        conn.close()
    counts = {status: int(row[index] or 0) for index, status in enumerate(STATUSES)}
    counts["total"] = int(row[len(STATUSES)] or 0)
    return counts


def _row_record(row: sqlite3.Row) -> dict[str, Any]:
    record: dict[str, Any] = {}
    for column, key in EPISODE_COLUMNS:
        value = row[column]
        if key == "tags":
            try:
                value = [str(tag) for tag in json.loads(value or "[]")]
            except (json.JSONDecodeError, TypeError):
                value = []
        record[key] = value
    return record


def write_episodes(db: Path, dest: Path) -> int:
    """Write every episode, provenance and content, one JSON object per line.

    Read from the snapshot, not the live database, so the two files describe the
    same instant. The content is included: an export restores memory even if
    SQLite is unavailable to whatever reads it.
    """
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    columns = ", ".join(column for column, _ in EPISODE_COLUMNS)
    written = 0
    try:
        with dest.open("w", encoding="utf-8") as handle:
            cursor = conn.execute(
                f"SELECT {columns} FROM episodes ORDER BY created_at, group_id"
            )
            for row in cursor:
                handle.write(json.dumps(_row_record(row), sort_keys=True, ensure_ascii=False) + "\n")
                written += 1
    finally:
        conn.close()
    return written


def _text(value: object) -> str:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def parse_info(reply: object) -> dict[str, str]:
    """`INFO` returns `# Section` headers and `key:value` lines."""
    fields: dict[str, str] = {}
    for line in _text(reply).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def _redis(url: str) -> Any:
    try:
        import redis
    except ImportError as exc:  # pragma: no cover - the package depends on redis
        raise GraphSnapshotError("the redis client is not available") from exc
    return redis.Redis.from_url(url, socket_connect_timeout=5, socket_timeout=10)


def _start_bgsave(client: Any) -> None:
    """Ask FalkorDB to write a point-in-time RDB. AOF is never touched."""
    try:
        client.execute_command("BGSAVE")
    except Exception as exc:
        # A save already running is fine: we wait for it like one we started.
        if "in progress" in str(exc).lower():
            return
        raise GraphSnapshotError(f"BGSAVE failed: {exc}") from exc


def _wait_for_bgsave(
    client: Any,
    *,
    timeout: float,
    poll: float,
    sleep: Callable[[float], None],
    clock: Callable[[], float],
) -> None:
    deadline = clock() + timeout
    while True:
        try:
            fields = parse_info(client.execute_command("INFO", "persistence"))
        except GraphSnapshotError:
            raise
        except Exception as exc:
            raise GraphSnapshotError(f"INFO persistence failed: {exc}") from exc
        if "rdb_bgsave_in_progress" not in fields:
            raise GraphSnapshotError("the server reports no rdb_bgsave_in_progress; is this FalkorDB?")
        if fields["rdb_bgsave_in_progress"] == "0":
            status = fields.get("rdb_last_bgsave_status", "ok")
            if status != "ok":
                raise GraphSnapshotError(f"the last BGSAVE failed: {fields.get('rdb_last_bgsave_err') or status}")
            return
        if clock() >= deadline:
            raise GraphSnapshotError(f"BGSAVE did not finish within {timeout:g}s")
        sleep(poll)


@dataclass(frozen=True)
class GraphSnapshot:
    file: str
    snapshot: str
    sha256: str
    bytes: int

    def as_manifest(self) -> dict[str, object]:
        return {
            "file": self.file,
            "timestamp": self.snapshot,
            "sha256": self.sha256,
            "bytes": self.bytes,
        }


def snapshot_graph(
    *,
    graph_dir: Path | str,
    dest_dir: Path | str,
    snapshot: str,
    url: str = DEFAULT_GRAPH_URL,
    timeout: float = DEFAULT_GRAPH_TIMEOUT,
    client: object | None = None,
    poll: float = BGSAVE_POLL_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> GraphSnapshot:
    """BGSAVE the graph, wait for it, and copy `dump.rdb` into the export.

    The RDB lands next to the registry snapshot but under its own name, so a
    graph from a different run can never be mistaken for this one's.
    """
    source = Path(graph_dir)
    target_dir = Path(dest_dir)
    filename = GRAPH_FILE.format(snapshot=snapshot)
    dump = source / "dump.rdb"
    handle = client if client is not None else _redis(url)
    started = time.time()
    _start_bgsave(handle)
    _wait_for_bgsave(handle, timeout=timeout, poll=poll, sleep=sleep, clock=clock)
    try:
        stat = dump.stat()
    except OSError as exc:
        raise GraphSnapshotError(f"{dump} is not readable: {exc}") from exc
    if stat.st_mtime < started - DUMP_MTIME_SLACK:
        raise GraphSnapshotError(f"{dump} was not rewritten by this BGSAVE")
    target = target_dir / filename
    try:
        shutil.copyfile(dump, target)
    except OSError as exc:
        raise GraphSnapshotError(f"copying {dump} failed: {exc}") from exc
    return GraphSnapshot(
        file=filename,
        snapshot=snapshot,
        sha256=file_sha256(target),
        bytes=target.stat().st_size,
    )


def prune_exports(root: Path | str, keep: int) -> tuple[Path, ...]:
    """Keep the newest `keep` timestamped export directories, nothing else.

    Only directories whose names are export timestamps are candidates: a stray
    file, a symlink, or an operator's directory under the root is never removed.
    """
    if keep < 1:
        raise ValueError("keep must be at least 1")
    base = Path(root)
    if not base.is_dir():
        return ()
    candidates = sorted(
        (
            path
            for path in base.iterdir()
            if is_snapshot_name(path.name) and path.is_dir() and not path.is_symlink()
        ),
        key=lambda path: path.name,
        reverse=True,
    )
    stale = candidates[keep:]
    for path in stale:
        shutil.rmtree(path)
    return tuple(stale)


@dataclass(frozen=True)
class ExportConfig:
    root: Path = Path(DEFAULT_ROOT)
    state_dir: Path = Path(DEFAULT_STATE_DIR)
    keep: int = DEFAULT_KEEP
    graph_dir: Path | None = None
    graph_url: str = DEFAULT_GRAPH_URL
    graph_timeout: float = DEFAULT_GRAPH_TIMEOUT
    graph_client: object | None = None

    @property
    def registry_path(self) -> Path:
        return self.state_dir / REGISTRY_FILE


@dataclass(frozen=True)
class ExportResult:
    directory: Path
    manifest: Mapping[str, object]
    pruned: tuple[Path, ...]


def build_manifest(
    *,
    snapshot: str,
    created_at: str,
    schema: int,
    counts: Mapping[str, int],
    files: Mapping[str, Path],
    graph: GraphSnapshot | None,
    graph_error: str | None,
) -> dict[str, object]:
    manifest: dict[str, object] = {
        "created_at": created_at,
        "snapshot": snapshot,
        "schema_version": schema,
        "counts": dict(counts),
        "files": {
            name: {"sha256": file_sha256(path), "bytes": path.stat().st_size}
            for name, path in files.items()
        },
        "graph": graph.as_manifest() if graph is not None else None,
    }
    if graph_error is not None:
        manifest["graph_error"] = graph_error
    return manifest


def run_export(config: ExportConfig) -> ExportResult:
    """Take one export. The registry decides success; the graph is best-effort."""
    if config.keep < 1:
        raise ExportError("keep must be at least 1; retention never deletes the export it just took")
    stamp = timestamp()
    directory = config.root / stamp
    if directory.exists():
        raise ExportError(f"{directory} already exists; one export per second")
    config.root.mkdir(parents=True, exist_ok=True)
    directory.mkdir()
    try:
        registry = directory / REGISTRY_FILE
        snapshot_registry(config.registry_path, registry)
        schema = schema_version(registry)
        if schema != SCHEMA_VERSION:
            found = "unversioned" if schema == 0 else str(schema)
            raise ExportError(
                f"{config.registry_path} has schema version {found}, expected {SCHEMA_VERSION}; "
                "refusing to export a registry this code cannot read"
            )
        write_episodes(registry, directory / EPISODES_FILE)
        graph: GraphSnapshot | None = None
        graph_error: str | None = None
        if config.graph_dir is not None:
            try:
                graph = snapshot_graph(
                    graph_dir=config.graph_dir,
                    dest_dir=directory,
                    snapshot=stamp,
                    url=config.graph_url,
                    timeout=config.graph_timeout,
                    client=config.graph_client,
                )
            except GraphSnapshotError as exc:
                graph_error = str(exc)
        manifest = build_manifest(
            snapshot=stamp,
            created_at=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            schema=schema,
            counts=status_counts(registry),
            files={REGISTRY_FILE: registry, EPISODES_FILE: directory / EPISODES_FILE},
            graph=graph,
            graph_error=graph_error,
        )
        (directory / MANIFEST_FILE).write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except Exception:
        # A half-written directory must never look like a restorable export.
        shutil.rmtree(directory, ignore_errors=True)
        raise
    return ExportResult(
        directory=directory,
        manifest=manifest,
        pruned=prune_exports(config.root, config.keep),
    )


@dataclass(frozen=True)
class GraphDecision:
    """What restore will do with the graph snapshot in an export."""

    path: Path | None = None
    reason: str | None = None

    @property
    def accepted(self) -> bool:
        return self.path is not None


@dataclass(frozen=True)
class VerifiedExport:
    directory: Path
    manifest: Mapping[str, Any]
    snapshot: str
    schema_version: int
    counts: Mapping[str, int]
    graph: GraphDecision


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ExportInvalid(f"{path} is unreadable: {exc}") from exc


def _member(directory: Path, name: object) -> Path:
    """Resolve a manifest file name inside the export, never outside it."""
    text = str(name)
    if not text or Path(text).name != text or text in (".", ".."):
        raise ExportInvalid(f"manifest names an unsafe path: {text!r}")
    return directory / text


def verify_export(directory: Path | str) -> VerifiedExport:
    """Check every checksum in the manifest and decide about the graph.

    A registry or episode checksum mismatch invalidates the whole export. A
    broken graph snapshot only drops the graph: the registry is what matters,
    and the graph can be rebuilt.
    """
    root = Path(directory)
    if not root.is_dir():
        raise ExportInvalid(f"{root} is not an export directory")
    if not is_snapshot_name(root.name):
        raise ExportInvalid(f"{root.name} is not an export timestamp")
    manifest = _read_json(root / MANIFEST_FILE)
    if not isinstance(manifest, dict):
        raise ExportInvalid(f"{root / MANIFEST_FILE} is not a JSON object")
    snapshot = str(manifest.get("snapshot") or root.name)
    if snapshot != root.name:
        raise ExportInvalid(f"manifest snapshot {snapshot} does not match the directory {root.name}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ExportInvalid("manifest has no file checksums")
    for name in (REGISTRY_FILE, EPISODES_FILE):
        if name not in files:
            raise ExportInvalid(f"manifest has no checksum for {name}")
    for name, meta in files.items():
        path = _member(root, name)
        if not path.is_file():
            raise ExportInvalid(f"{name} is missing from the export")
        recorded = str((meta or {}).get("sha256") or "")
        actual = file_sha256(path)
        if recorded != actual:
            raise ExportInvalid(f"{name} does not match its manifest sha256 (tampered or corrupt)")
        size = (meta or {}).get("bytes")
        if size is not None and int(size) != path.stat().st_size:
            raise ExportInvalid(f"{name} does not match its recorded size")
    try:
        schema = schema_version(root / REGISTRY_FILE)
    except sqlite3.Error as exc:
        raise ExportInvalid(f"{REGISTRY_FILE} is not a readable database: {exc}") from exc
    counts = manifest.get("counts")
    if not isinstance(counts, dict):
        raise ExportInvalid("manifest has no status counts")
    return VerifiedExport(
        directory=root,
        manifest=manifest,
        snapshot=snapshot,
        schema_version=schema,
        counts={str(key): int(value) for key, value in counts.items()},
        graph=_graph_decision(root, manifest, snapshot),
    )


def _graph_decision(root: Path, manifest: Mapping[str, Any], snapshot: str) -> GraphDecision:
    """Accept the graph snapshot only when it belongs to this registry snapshot."""
    entry = manifest.get("graph")
    if entry is None:
        error = manifest.get("graph_error")
        reason = "the export holds no graph snapshot"
        if error:
            reason = f"{reason}: {error}"
        return GraphDecision(reason=reason)
    if not isinstance(entry, dict):
        return GraphDecision(reason="the manifest's graph entry is malformed")
    name = str(entry.get("file") or "")
    match = GRAPH_NAME_PATTERN.match(name)
    if match is None:
        return GraphDecision(reason=f"graph file name {name!r} is not a graph snapshot name")
    timestamp_in_name = match.group(1)
    if timestamp_in_name != snapshot:
        return GraphDecision(
            reason=f"graph snapshot {timestamp_in_name} does not belong to registry snapshot {snapshot}"
        )
    path = _member(root, name)
    if not path.is_file():
        return GraphDecision(reason=f"{name} is missing from the export")
    if str(entry.get("sha256") or "") != file_sha256(path):
        return GraphDecision(reason=f"{name} does not match its manifest sha256")
    return GraphDecision(path=path)


@dataclass(frozen=True)
class RestoreConfig:
    export_dir: Path
    state_dir: Path = Path(DEFAULT_STATE_DIR)
    graph_dir: Path = Path(DEFAULT_GRAPH_DIR)
    units: tuple[str, ...] = MEMORY_UNITS
    stop_services: bool = True
    start_services: bool = False
    dry_run: bool = False
    schema_version: int = SCHEMA_VERSION
    owner: str | None = DEFAULT_OWNER
    run: Callable[[Sequence[str]], None] | None = None

    def __post_init__(self) -> None:
        if self.run is None:
            object.__setattr__(self, "run", _systemctl)


def _systemctl(command: Sequence[str]) -> None:
    result = subprocess.run(list(command), check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise ExportError(
            f"{' '.join(command)} failed: {(result.stderr or result.stdout).strip()}"
        )


def _fix_owner(path: Path, owner: str | None) -> None:
    """The wrapper writes the registry as its own user; a root copy must match."""
    if not owner or os.geteuid() != 0:
        # Only root can hand a file to the service user; a non-root run is a
        # verification against temp dirs, where the current user is correct.
        return
    user, _, group = owner.partition(":")
    try:
        uid = pwd.getpwnam(user).pw_uid
    except KeyError:
        print(f"memory: warning: user {user!r} does not exist; {path} keeps its owner", file=sys.stderr)
        return
    try:
        import grp

        gid = grp.getgrnam(group or user).gr_gid
    except (KeyError, ImportError):
        gid = -1
    try:
        os.chmod(path, 0o640)
        os.chown(path, uid, gid)
    except OSError as exc:
        print(f"memory: warning: could not hand {path} to {owner}: {exc}", file=sys.stderr)


def _park_aof(graph_dir: Path, snapshot: str) -> tuple[str, ...]:
    """Rename the AOF aside so the restored RDB is what FalkorDB loads.

    FalkorDB runs with `appendonly yes`, and Redis prefers the AOF over the RDB
    at startup. Leaving the old AOF in place would silently keep the graph the
    export did not match. The AOF is derived data: it is kept under a
    pre-restore name, never deleted, and the export never rewrites it.
    """
    parked: list[str] = []
    for name in AOF_NAMES:
        source = graph_dir / name
        if not source.exists():
            continue
        target = graph_dir / f"{name}.pre-restore-{snapshot}"
        counter = 1
        while target.exists():
            target = graph_dir / f"{name}.pre-restore-{snapshot}.{counter}"
            counter += 1
        source.rename(target)
        parked.append(target.name)
    return tuple(parked)


def _install(source: Path, target: Path, *, owner: str | None) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(target.name + ".restore-tmp")
    shutil.copyfile(source, staging)
    _fix_owner(staging, owner)
    os.replace(staging, target)


@dataclass(frozen=True)
class RestoreReport:
    export_dir: Path
    snapshot: str
    schema_version: int
    counts: Mapping[str, int]
    registry_path: Path
    graph: GraphDecision
    restored: bool
    graph_restored: bool
    parked_aof: tuple[str, ...] = ()


def restore(config: RestoreConfig) -> RestoreReport:
    """Verify an export and put the registry (and a matching graph) back.

    Order matters: verification runs before anything is stopped, and the schema
    is checked before the live registry is touched. A newer schema is refused
    outright: this code cannot read it, and migrating in place is not a thing.
    """
    verified = verify_export(config.export_dir)
    if verified.schema_version > config.schema_version:
        raise ExportInvalid(
            f"the export's registry schema is {verified.schema_version}, "
            f"this code writes {config.schema_version}; refusing to restore a newer schema"
        )
    if verified.schema_version < config.schema_version:
        raise ExportInvalid(
            f"the export's registry schema is {verified.schema_version}, "
            f"this code writes {config.schema_version}; the wrapper refuses to open it, "
            "so restore it with the matching release instead"
        )
    registry_path = config.state_dir / REGISTRY_FILE
    report = RestoreReport(
        export_dir=verified.directory,
        snapshot=verified.snapshot,
        schema_version=verified.schema_version,
        counts=verified.counts,
        registry_path=registry_path,
        graph=verified.graph,
        restored=False,
        graph_restored=False,
    )
    if config.dry_run:
        return report
    if config.stop_services and config.units:
        config.run(("systemctl", "stop", *config.units))
    # A WAL/SHM pair belongs to the database that wrote it; a restored copy must
    # never be replayed over.
    for suffix in ("-wal", "-shm"):
        stale = registry_path.with_name(registry_path.name + suffix)
        if stale.exists():
            stale.unlink()
    _install(verified.directory / REGISTRY_FILE, registry_path, owner=config.owner)
    graph_restored = False
    parked: tuple[str, ...] = ()
    if verified.graph.accepted and verified.graph.path is not None:
        _install(verified.graph.path, config.graph_dir / "dump.rdb", owner=None)
        parked = _park_aof(config.graph_dir, verified.snapshot)
        graph_restored = True
    if config.start_services and config.units:
        config.run(("systemctl", "start", *config.units))
    return RestoreReport(
        export_dir=report.export_dir,
        snapshot=report.snapshot,
        schema_version=report.schema_version,
        counts=report.counts,
        registry_path=report.registry_path,
        graph=report.graph,
        restored=True,
        graph_restored=graph_restored,
        parked_aof=parked,
    )


def graph_advice(report: RestoreReport) -> str:
    """What the operator does about the graph after a registry restore."""
    if report.graph_restored:
        moved = (
            f"; moved the previous AOF aside ({', '.join(report.parked_aof)}), because"
            " FalkorDB loads it in preference to the RDB"
            if report.parked_aof
            else ""
        )
        return f"graph: restored the matching snapshot{moved}; start the memory services."
    return (
        f"graph: not restored ({report.graph.reason}). The graph is a derived index; "
        "rebuild it from the restored registry: stop memory-mcp and memory-graphiti-mcp, "
        "empty /var/lib/memory/falkordb, start them, then run `just memory-ingest`."
    )


def _report_lines(report: RestoreReport, *, dry_run: bool) -> Iterator[str]:
    counts = " ".join(f"{key}={report.counts.get(key, 0)}" for key in (*STATUSES, "total"))
    verb = "verified" if dry_run else "restored"
    yield f"{verb} {report.export_dir} (snapshot {report.snapshot}, schema {report.schema_version})"
    yield f"registry: {report.registry_path} ({counts})"
    yield graph_advice(report)


def add_export_parser(subparsers: Any) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "export", help="Snapshot the registry (and the graph) into one timestamped directory"
    )
    parser.add_argument(
        "--root",
        default=os.environ.get("MEMORY_EXPORT_ROOT", DEFAULT_ROOT),
        help=f"Export root (default {DEFAULT_ROOT})",
    )
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("MEMORY_STATE_DIR", DEFAULT_STATE_DIR),
        help=f"Registry directory (default {DEFAULT_STATE_DIR})",
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=int(os.environ.get("MEMORY_EXPORT_KEEP", DEFAULT_KEEP)),
        help=f"Export directories to keep (default {DEFAULT_KEEP})",
    )
    parser.add_argument(
        "--graph-dir",
        default=None,
        help="FalkorDB data directory; enables the graph snapshot",
    )
    parser.add_argument(
        "--graph-url",
        default=os.environ.get("MEMORY_REDIS_URL", DEFAULT_GRAPH_URL),
        help=f"FalkorDB URL (default {DEFAULT_GRAPH_URL})",
    )
    parser.add_argument(
        "--graph-timeout",
        type=float,
        default=DEFAULT_GRAPH_TIMEOUT,
        help=f"Seconds to wait for BGSAVE (default {DEFAULT_GRAPH_TIMEOUT:g})",
    )
    return parser


def add_restore_parser(subparsers: Any) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "restore", help="Verify an export and restore the registry and a matching graph snapshot"
    )
    parser.add_argument("directory", help="Export directory to restore")
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("MEMORY_STATE_DIR", DEFAULT_STATE_DIR),
        help=f"Registry directory (default {DEFAULT_STATE_DIR})",
    )
    parser.add_argument(
        "--graph-dir",
        default=DEFAULT_GRAPH_DIR,
        help=f"FalkorDB data directory (default {DEFAULT_GRAPH_DIR})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Verify the export and print the plan; write nothing",
    )
    parser.add_argument(
        "--no-stop",
        action="store_true",
        help="Do not stop the memory services (verification only; the live store must be idle)",
    )
    parser.add_argument(
        "--start",
        action="store_true",
        help="Start the memory services after restoring",
    )
    return parser


def export_command(args: argparse.Namespace) -> int:
    result = run_export(
        ExportConfig(
            root=Path(args.root),
            state_dir=Path(args.state_dir),
            keep=args.keep,
            graph_dir=Path(args.graph_dir) if args.graph_dir else None,
            graph_url=args.graph_url,
            graph_timeout=args.graph_timeout,
        )
    )
    if getattr(args, "json", False):
        print(json.dumps(result.manifest, indent=2, sort_keys=True))
        return 0
    counts = " ".join(f"{key}={result.manifest['counts'].get(key, 0)}" for key in (*STATUSES, "total"))
    graph = result.manifest.get("graph")
    graph_note = (
        f"graph: {graph['file']}" if isinstance(graph, dict) else "graph: none"
    )
    if result.manifest.get("graph_error"):
        graph_note = f"{graph_note} ({result.manifest['graph_error']})"
    print(f"exported {result.directory} ({counts})")
    print(graph_note)
    for path in result.pruned:
        print(f"pruned {path.name}")
    return 0


def restore_command(args: argparse.Namespace) -> int:
    report = restore(
        RestoreConfig(
            export_dir=Path(args.directory),
            state_dir=Path(args.state_dir),
            graph_dir=Path(args.graph_dir),
            stop_services=not args.no_stop,
            start_services=args.start,
            dry_run=args.dry_run,
        )
    )
    for line in _report_lines(report, dry_run=args.dry_run):
        print(line)
    return 0


def dispatch(args: argparse.Namespace) -> int:
    if args.command == "export":
        return export_command(args)
    if args.command == "restore":
        return restore_command(args)
    raise ExportError(f"unknown command {args.command!r}")


def build_parser(prog: str = "memory-export") -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=prog, description="Export, verify, and restore the memory registry"
    )
    parser.add_argument("--json", action="store_true", help="Emit the manifest as JSON")
    subparsers = parser.add_subparsers(dest="command", required=True)
    add_export_parser(subparsers)
    add_restore_parser(subparsers)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return dispatch(args)
    except (ExportError, ExportInvalid, GraphSnapshotError) as exc:
        print(f"memory-export: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":  # pragma: no cover - exercised through the entry points
    raise SystemExit(main())
