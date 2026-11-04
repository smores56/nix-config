"""Export the registry and a matching FalkorDB snapshot; verify and restore them.

One export is three files in the export root, each replaced atomically; restic
owns history and integrity:

- ``registry.sqlite``: a consistent copy of the registry, taken with SQLite's
  online backup API, so it works while the wrapper keeps writing under WAL;
- ``episodes.jsonl``: every episode with its typed provenance and content, so
  memory is readable without SQLite or this code;
- ``graph.rdb``: a FalkorDB snapshot, when ``BGSAVE`` finished.

The registry is the system of record and the graph a derived index, so the
graph step is best-effort: if FalkorDB does not answer, the registry files are
still written, any previous ``graph.rdb`` is gone (it would not match), and the
command exits non-zero so the timer run is visibly failed.

Only the optional ``redis`` client (imported lazily) is outside the standard
library, so export and restore run on a machine without the MCP dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import pwd
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence

from .registry import REGISTRY_FILE, SCHEMA_VERSION, STATUSES

EPISODES_FILE = "episodes.jsonl"
GRAPH_FILE = "graph.rdb"

DEFAULT_ROOT = "/var/lib/data/memory-export"
DEFAULT_STATE_DIR = "/var/lib/memory"
DEFAULT_GRAPH_DIR = "/var/lib/memory/falkordb"
DEFAULT_GRAPH_URL = "redis://127.0.0.1:6379"
DEFAULT_GRAPH_TIMEOUT = 120.0
# Services that write the registry or own the graph files, stopped writers first. `memory-falkordb`
# must stop too: its AOF rewrite would recreate the data being replaced.
GRAPH_UNIT = "memory-falkordb"
MEMORY_UNITS = ("memory-mcp", "memory-graphiti-mcp", "memory-llm-proxy", GRAPH_UNIT)
DEFAULT_OWNER = "memory:memory"
# Written first by restore; an export refuses to snapshot a registry being swapped.
RESTORE_LOCK = ".restore-in-progress"
# FalkorDB runs `appendonly yes` and Redis prefers the AOF, so a restored `dump.rdb` needs the old AOF moved away.
AOF_NAMES = ("appendonlydir", "appendonly.aof")
BGSAVE_POLL_INTERVAL = 0.5

TIMESTAMP_FORMAT = "%Y-%m-%dT%H-%M-%SZ"

# Registry column -> episode JSON key (`group_id` is the registry's spelling).
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
    ("queued_at", "queued_at"),
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


def _adopt_sidecars(path: Path) -> None:
    """Give WAL side files we may have created back to the registry's owner.

    The fallback below opens read/write, and SQLite writes: the first statement
    creates `-wal`/`-shm` if the wrapper had no connection open at that instant,
    and closing the handle checkpoints the WAL. Those files inherit root's
    ownership, which would leave the `memory` user unable to write the
    database. Root hands them to the database's owner immediately, so the
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
    between connections. The fallback opens read/write, which does write: the
    statement below creates ``-wal``/``-shm`` and the close checkpoints the WAL.
    Sidecar ownership is repaired only once those files exist, so the order
    here matters.
    """
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
        return conn
    except sqlite3.Error:
        conn = sqlite3.connect(f"file:{path}?mode=rw", uri=True, timeout=30)
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
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


def integrity_check(db: Path) -> str:
    """`ok`, or the first problem SQLite reports."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        return str(conn.execute("PRAGMA integrity_check").fetchone()[0])
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
    """`INFO` returns `# Section` headers and `key:value` lines.

    redis-py answers `INFO` with a parsed mapping; raw protocol replies (and
    the fakes in the tests) are bulk strings. Both shapes are accepted, because
    reading only the string shape made every snapshot claim the server was not
    FalkorDB.
    """
    if isinstance(reply, Mapping):
        return {str(key): str(value) for key, value in reply.items()}
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


def _last_save(fields: Mapping[str, str]) -> int:
    """The server's timestamp of its last successful RDB save."""
    raw = fields.get("rdb_last_save_time")
    if raw is None:
        raise GraphSnapshotError("the server reports no rdb_last_save_time; is this FalkorDB?")
    try:
        return int(raw)
    except ValueError as exc:
        raise GraphSnapshotError(f"rdb_last_save_time is not a number: {raw!r}") from exc


def _rdb_last_save(client: Any) -> int:
    try:
        fields = parse_info(client.execute_command("INFO", "persistence"))
    except Exception as exc:
        raise GraphSnapshotError(f"INFO persistence failed: {exc}") from exc
    return _last_save(fields)


def _start_bgsave(client: Any) -> None:
    """Ask FalkorDB to write a point-in-time RDB. AOF is never touched."""
    try:
        client.execute_command("BGSAVE")
    except Exception as exc:
        # A save already running is fine: wait for it.
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
) -> dict[str, str]:
    """Poll `INFO persistence` until the save finishes; return its last fields."""
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
            return fields
        if clock() >= deadline:
            raise GraphSnapshotError(f"BGSAVE did not finish within {timeout:g}s")
        sleep(poll)


def _copy_atomic(source: Path, dest: Path) -> None:
    staging = dest.with_name(dest.name + ".tmp")
    shutil.copyfile(source, staging)
    os.replace(staging, dest)


def snapshot_graph(
    *,
    graph_dir: Path | str,
    dest: Path | str,
    url: str = DEFAULT_GRAPH_URL,
    timeout: float = DEFAULT_GRAPH_TIMEOUT,
    client: object | None = None,
    poll: float = BGSAVE_POLL_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> None:
    """BGSAVE the graph, wait for it, and copy `dump.rdb` to `dest`."""
    dump = Path(graph_dir) / "dump.rdb"
    handle = client if client is not None else _redis(url)
    # The save timestamp, not mtime: only a save completing after this point rewrote dump.rdb.
    saved_before = _rdb_last_save(handle)
    _start_bgsave(handle)
    fields = _wait_for_bgsave(handle, timeout=timeout, poll=poll, sleep=sleep, clock=clock)
    if _last_save(fields) <= saved_before:
        raise GraphSnapshotError(
            f"dump.rdb was not rewritten by this BGSAVE (rdb_last_save_time stayed at {saved_before})"
        )
    try:
        dump.stat()
    except OSError as exc:
        raise GraphSnapshotError(f"{dump} is not readable: {exc}") from exc
    try:
        _copy_atomic(dump, Path(dest))
    except OSError as exc:
        raise GraphSnapshotError(f"copying {dump} failed: {exc}") from exc


@dataclass(frozen=True)
class ExportConfig:
    root: Path = Path(DEFAULT_ROOT)
    state_dir: Path = Path(DEFAULT_STATE_DIR)
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
    counts: Mapping[str, int]
    graph: bool
    graph_error: str | None = None


def run_export(config: ExportConfig) -> ExportResult:
    """Take one export. The registry decides success; the graph is best-effort."""
    lock = config.state_dir / RESTORE_LOCK
    if lock.exists():
        raise ExportError(
            f"{lock} exists: a restore is in progress or failed and left the lock; "
            "refusing to snapshot a registry that is being replaced"
        )
    config.root.mkdir(parents=True, exist_ok=True)
    for stale in config.root.glob(".staging-*"):
        shutil.rmtree(stale, ignore_errors=True)
    # Staged beside the targets (same filesystem, so the renames are atomic); the directory
    # also takes the SQLite sidecars the checks below leave behind.
    with tempfile.TemporaryDirectory(dir=config.root, prefix=".staging-") as staging_dir:
        staging = Path(staging_dir) / REGISTRY_FILE
        snapshot_registry(config.registry_path, staging)
        schema = schema_version(staging)
        if schema != SCHEMA_VERSION:
            found = "unversioned" if schema == 0 else str(schema)
            raise ExportError(
                f"{config.registry_path} has schema version {found}, expected {SCHEMA_VERSION}; "
                "refusing to export a registry this code cannot read"
            )
        episodes = Path(staging_dir) / EPISODES_FILE
        write_episodes(staging, episodes)
        counts = status_counts(staging)
        os.replace(episodes, config.root / EPISODES_FILE)
        # Dropped only now, so a failed registry snapshot leaves the previous pair intact and a
        # failed graph snapshot never leaves a graph that predates the new registry.
        (config.root / GRAPH_FILE).unlink(missing_ok=True)
        os.replace(staging, config.root / REGISTRY_FILE)
    graph_error: str | None = None
    if config.graph_dir is not None:
        try:
            snapshot_graph(
                graph_dir=config.graph_dir,
                dest=config.root / GRAPH_FILE,
                url=config.graph_url,
                timeout=config.graph_timeout,
                client=config.graph_client,
            )
        except GraphSnapshotError as exc:
            graph_error = str(exc)
    return ExportResult(
        directory=config.root,
        counts=counts,
        graph=config.graph_dir is not None and graph_error is None,
        graph_error=graph_error,
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
    schema_version: int
    counts: Mapping[str, int]
    graph: GraphDecision


def verify_export(directory: Path | str) -> VerifiedExport:
    """Check that the registry is a readable database at this code's schema.

    A bad registry invalidates the whole export; a missing graph only drops the
    graph, which can be replayed from the registry.
    """
    root = Path(directory)
    registry = root / REGISTRY_FILE
    if not registry.is_file():
        raise ExportInvalid(f"{registry} is missing: not a memory export")
    try:
        schema = schema_version(registry)
        counts = status_counts(registry)
        integrity = integrity_check(registry)
    except sqlite3.Error as exc:
        raise ExportInvalid(f"{REGISTRY_FILE} is not a readable registry: {exc}") from exc
    if integrity != "ok":
        raise ExportInvalid(f"{REGISTRY_FILE} fails PRAGMA integrity_check: {integrity}")
    if schema != SCHEMA_VERSION:
        word = "newer" if schema > SCHEMA_VERSION else "older"
        raise ExportInvalid(
            f"the export's registry schema is {schema}, this code writes {SCHEMA_VERSION}; "
            f"refusing to restore a {word} schema"
        )
    graph = root / GRAPH_FILE
    decision = (
        GraphDecision(path=graph)
        if graph.is_file()
        else GraphDecision(reason="the export holds no graph snapshot")
    )
    return VerifiedExport(directory=root, schema_version=schema, counts=counts, graph=decision)


@dataclass(frozen=True)
class RestoreConfig:
    export_dir: Path
    state_dir: Path = Path(DEFAULT_STATE_DIR)
    graph_dir: Path = Path(DEFAULT_GRAPH_DIR)
    units: tuple[str, ...] = MEMORY_UNITS
    stop_services: bool = True
    start_services: bool = False
    dry_run: bool = False
    # `None` leaves the file owned by the caller; the CLI passes the service account, and its absence is a hard error.
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


def _fix_owner(path: Path, owner: str | None, *, mode: int = 0o640) -> None:
    """The wrapper writes the registry as its own user; a root copy must match.

    This runs on the staging copy, before it replaces anything: an ownership
    failure has to abort the restore while the previous registry is still in
    place, not leave a file the `memory` user cannot write. `owner=None` skips
    it (a non-root verification against temp dirs). Directories use 0700 so the
    rootless FalkorDB can write its AOF.
    """
    if not owner:
        return
    user, _, group = owner.partition(":")
    try:
        uid = pwd.getpwnam(user).pw_uid
    except KeyError as exc:
        raise ExportError(f"owner {user!r} does not exist; refusing to install {path}") from exc
    try:
        import grp

        gid = grp.getgrnam(group or user).gr_gid
    except (KeyError, ImportError):
        gid = -1
    try:
        os.chmod(path, mode)
        os.chown(path, uid, gid)
    except OSError as exc:
        raise ExportError(f"could not hand {path} to {owner}: {exc}") from exc


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


def _park_registry(registry_path: Path, snapshot: str) -> tuple[Path, ...]:
    """Copy the live registry and its WAL sidecars aside before the swap.

    A safety net for a bad restore, not a backup: the operator gets the file
    back if the install fails or the restored registry turns out to be the wrong
    one. The `-wal`/`-shm` pair is copied with it, because the registry alone
    can be missing the writes the WAL still holds. Nothing here is deleted.
    """
    if not registry_path.is_file():
        return ()
    target = registry_path.with_name(f"{registry_path.name}.pre-restore-{snapshot}")
    counter = 1
    while target.exists():
        target = registry_path.with_name(f"{registry_path.name}.pre-restore-{snapshot}.{counter}")
        counter += 1
    try:
        shutil.copy2(registry_path, target)
    except OSError as exc:
        raise ExportError(f"parking {registry_path} before the restore failed: {exc}") from exc
    parked: list[Path] = [target]
    for suffix in ("-wal", "-shm"):
        source = registry_path.with_name(registry_path.name + suffix)
        if not source.exists():
            continue
        copy = target.with_name(target.name + suffix)
        try:
            shutil.copy2(source, copy)
        except OSError:
            # The registry copy is the safety net; the sidecar may be gone again.
            continue
        parked.append(copy)
    return tuple(parked)


def _stage_copy(source: Path, staging: Path) -> None:
    """Copy into a fresh file, never through a symlink planted in the memory-owned directory.

    Root runs this inside directories the `memory` user can write: the old name is
    unlinked (a symlink is removed, not followed) and the new one is created
    exclusively without following links.
    """
    staging.unlink(missing_ok=True)
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as out, source.open("rb") as handle:
        shutil.copyfileobj(handle, out)


def _install(source: Path, target: Path, *, owner: str | None) -> None:
    """Stage the copy, hand it to its owner, then replace in one rename."""
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(target.name + ".restore-tmp")
    _stage_copy(source, staging)
    try:
        _fix_owner(staging, owner)
        os.replace(staging, target)
    except BaseException:
        staging.unlink(missing_ok=True)
        raise


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
    parked_registry: tuple[Path, ...] = ()
    restarted: tuple[str, ...] = ()


def restore(config: RestoreConfig) -> RestoreReport:
    """Verify an export and put the registry (and a matching graph) back.

    Order matters: verification, including the schema check, runs before anything
    is stopped or the live registry is touched.
    The live registry is parked first, replaced atomically, and only then are
    its WAL sidecars dropped: they belong to the database that was replaced.
    """
    verified = verify_export(config.export_dir)
    snapshot = timestamp()
    registry_path = config.state_dir / REGISTRY_FILE
    report = RestoreReport(
        export_dir=verified.directory,
        snapshot=snapshot,
        schema_version=verified.schema_version,
        counts=verified.counts,
        registry_path=registry_path,
        graph=verified.graph,
        restored=False,
        graph_restored=False,
    )
    if config.dry_run:
        return report
    lock = _write_restore_lock(config.state_dir, snapshot)
    if config.stop_services and config.units:
        config.run(("systemctl", "stop", *config.units))
    parked_registry = _park_registry(registry_path, snapshot)
    try:
        _install(
            verified.directory / REGISTRY_FILE,
            registry_path,
            owner=config.owner,
        )
    except (ExportError, OSError) as exc:
        parked_note = (
            f"the previous registry is parked at {parked_registry[0]}; copy it back over "
            f"{registry_path.name} to undo"
            if parked_registry
            else f"there was no previous registry at {registry_path} to park"
        )
        raise ExportError(
            f"installing the restored registry failed: {exc}; {parked_note}; "
            f"{lock} stays in place until the state is reconciled"
        ) from exc
    for suffix in ("-wal", "-shm"):
        stale = registry_path.with_name(registry_path.name + suffix)
        try:
            stale.unlink(missing_ok=True)
        except OSError as exc:
            raise ExportError(
                f"removing the replaced registry's {suffix} file failed: {exc}; "
                f"the previous registry is parked at {parked_registry[0] if parked_registry else registry_path}"
            ) from exc
    graph_restored = False
    parked: tuple[str, ...] = ()
    if verified.graph.accepted and verified.graph.path is not None:
        try:
            # FalkorDB runs rootless as `memory`; root-owned data would be unreadable.
            if config.owner:
                config.graph_dir.mkdir(parents=True, exist_ok=True)
                _fix_owner(config.graph_dir, config.owner, mode=0o700)
            _install(verified.graph.path, config.graph_dir / "dump.rdb", owner=config.owner)
        except (ExportError, OSError) as exc:
            raise ExportError(
                f"the registry is restored but installing the graph snapshot failed: {exc}; "
                f"{lock} stays in place; the graph is a derived index and "
                "is replayed from the restored registry with `memory reindex --all`"
            ) from exc
        try:
            parked = _park_aof(config.graph_dir, snapshot)
        except OSError as exc:
            raise ExportError(
                f"the registry and graph snapshot are restored but the old AOF could not be "
                f"moved aside in {config.graph_dir}: {exc}; FalkorDB loads it in preference to "
                f"the RDB, so move it yourself before starting {GRAPH_UNIT}; {lock} stays in place"
            ) from exc
        graph_restored = True
    restarted = _restart_units(config, graph_restored=graph_restored)
    lock.unlink(missing_ok=True)
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
        parked_registry=parked_registry,
        restarted=restarted,
    )


def _write_restore_lock(state_dir: Path, snapshot: str) -> Path:
    """Claim the state dir for this restore; exports refuse while it exists."""
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = state_dir / RESTORE_LOCK
    try:
        handle = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise ExportError(
            f"{lock} exists: another restore is running, or one failed and left it; "
            "remove it once the state is reconciled"
        ) from exc
    with os.fdopen(handle, "w", encoding="utf-8") as text:
        text.write(f"{snapshot}\n")
    return lock


def _restart_units(config: RestoreConfig, *, graph_restored: bool) -> tuple[str, ...]:
    """Start what the restore itself needs running again, in reverse stop order.

    FalkorDB reads `dump.rdb` at startup, so a restored snapshot is inert until
    its unit starts: that restart is part of the graph restore, not an optional
    courtesy, and `graph: restored` is only reported after it. `--start` also
    brings the writers back; without it they stay down so the restored registry
    can be inspected before retrieval touches it.
    """
    if not (config.stop_services and config.units):
        return ()
    wanted = list(reversed(config.units)) if config.start_services else []
    if graph_restored and GRAPH_UNIT in config.units:
        wanted = [GRAPH_UNIT, *(unit for unit in wanted if unit != GRAPH_UNIT)]
    if not wanted:
        return ()
    config.run(("systemctl", "start", *wanted))
    return tuple(wanted)


def graph_advice(report: RestoreReport) -> str:
    """What the operator does about the graph after a registry restore."""
    if report.graph_restored:
        live = (
            f" and restarted {GRAPH_UNIT}, so the restored snapshot is loaded"
            if GRAPH_UNIT in report.restarted
            else f"; start {GRAPH_UNIT} to load it"
        )
        parked = (
            f"; the previous AOF is parked at {', '.join(report.parked_aof)}"
            " (FalkorDB loads it in preference to the RDB) — delete it once the graph checks out"
            if report.parked_aof
            else ""
        )
        writers = (
            ""
            if all(unit in report.restarted for unit in MEMORY_UNITS)
            else "; start the memory services"
        )
        return f"graph: restored the matching snapshot{live}{parked}{writers}."
    return (
        f"graph: not restored ({report.graph.reason}). The graph is a derived index and this "
        "registry can replay into it: `memory reindex --all` returns the active rows FalkorDB "
        "no longer holds to pending, and the reconciler extracts them again."
    )


def _report_lines(report: RestoreReport, *, dry_run: bool) -> Iterator[str]:
    counts = " ".join(f"{key}={report.counts.get(key, 0)}" for key in (*STATUSES, "total"))
    verb = "verified" if dry_run else "restored"
    yield f"{verb} {report.export_dir} (schema {report.schema_version})"
    yield f"registry: {report.registry_path} ({counts})"
    if report.parked_registry:
        yield (
            f"previous registry: {report.parked_registry[0]}"
            " (kept; delete it once the restore checks out)"
        )
    if dry_run and report.graph.accepted and report.graph.path is not None:
        # A dry run leaves `graph_restored` false; without this a good export printed the "cannot be rebuilt" warning.
        yield f"graph: would restore {report.graph.path.name}"
        return
    yield graph_advice(report)


def add_export_parser(subparsers: Any) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "export", help="Snapshot the registry and the graph into the export root"
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
        "restore", help="Verify an export and restore the registry and its graph snapshot"
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
        "--owner",
        default=DEFAULT_OWNER,
        help=(
            f"Owner for the restored registry, user:group (default {DEFAULT_OWNER}); "
            "an empty value leaves it owned by the caller"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Verify the export and print the plan; write nothing",
    )
    parser.add_argument(
        "--no-stop",
        action="store_true",
        help=(
            "With --dry-run only: print the plan without the systemctl stop a real "
            "restore performs; any real restore stops the services"
        ),
    )
    parser.add_argument(
        "--start",
        action="store_true",
        help="Start the memory services after restoring, not just FalkorDB",
    )
    return parser


def export_command(args: argparse.Namespace) -> int:
    result = run_export(
        ExportConfig(
            root=Path(args.root),
            state_dir=Path(args.state_dir),
            graph_dir=Path(args.graph_dir) if args.graph_dir else None,
            graph_url=args.graph_url,
            graph_timeout=args.graph_timeout,
        )
    )
    counts = " ".join(f"{key}={result.counts.get(key, 0)}" for key in (*STATUSES, "total"))
    print(f"exported {result.directory} ({counts})")
    print(f"graph: {GRAPH_FILE}" if result.graph else "graph: none")
    if result.graph_error:
        # The registry export stands; the missing graph still fails so the timer's onFailure alert fires.
        print(f"memory-export: the graph snapshot failed: {result.graph_error}", file=sys.stderr)
        return 1
    return 0


def restore_command(args: argparse.Namespace) -> int:
    if args.no_stop and not args.dry_run:
        raise ExportError(
            "--no-stop would swap the registry and graph under running services; "
            "it is only accepted with --dry-run, which writes nothing"
        )
    report = restore(
        RestoreConfig(
            export_dir=Path(args.directory),
            state_dir=Path(args.state_dir),
            graph_dir=Path(args.graph_dir),
            stop_services=not args.no_stop,
            start_services=args.start,
            dry_run=args.dry_run,
            owner=args.owner or None,
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
        prog=prog, description="Export and restore the memory registry"
    )
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
