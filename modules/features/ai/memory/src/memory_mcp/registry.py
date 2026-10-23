"""Typed SQLite registry: the system of record for every memory episode.

The graph is a derived, rebuildable index. This registry holds normalized
content, typed provenance, verification state, promotions, and the audit trail.
Identity is content-addressed (`uuid5(group, sha256(content))`) and lives only
here: graphiti-core 0.31.2 rejects a caller-supplied uuid for an episode that
does not exist yet, so the graph's own uuid is recorded separately as
`graphiti_uuid` once the reconciler sees the episode.
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Mapping

DB_NAME = "registry.sqlite"
# Bumped whenever the schema below changes. A database one or more versions
# behind is migrated in place on open (`_MIGRATIONS`); anything older, newer or
# unversioned is refused rather than guessed at.
SCHEMA_VERSION = 2
LOOKUP_CHUNK = 500

KINDS = ("text", "json", "message")
ORIGINS = ("sdlc", "notes", "docs", "session", "agent")
STATUSES = ("pending", "active", "failed", "tombstoned")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    group_id TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    uuid TEXT NOT NULL,
    name TEXT NOT NULL,
    content TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'text',
    origin TEXT NOT NULL DEFAULT 'agent',
    origin_ref TEXT NOT NULL DEFAULT '',
    actor TEXT NOT NULL DEFAULT 'unknown',
    cwd TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    valid_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    queued_at TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    graphiti_uuid TEXT,
    promoted_from_group TEXT,
    promoted_by TEXT,
    promoted_at TEXT,
    tombstoned_at TEXT,
    tombstone_reason TEXT,
    PRIMARY KEY (group_id, content_hash)
);
CREATE INDEX IF NOT EXISTS episodes_uuid ON episodes (uuid);
CREATE INDEX IF NOT EXISTS episodes_created ON episodes (group_id, created_at);
CREATE INDEX IF NOT EXISTS episodes_graphiti_uuid ON episodes (graphiti_uuid);
CREATE INDEX IF NOT EXISTS episodes_status ON episodes (status);
CREATE INDEX IF NOT EXISTS episodes_queue ON episodes (status, queued_at);

CREATE TABLE IF NOT EXISTS promotions (
    source_uuid TEXT NOT NULL,
    target_uuid TEXT NOT NULL,
    source_group TEXT NOT NULL,
    target_group TEXT NOT NULL,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (source_uuid, target_group)
);

CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    finished_at TEXT NOT NULL,
    actor TEXT NOT NULL,
    group_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    status TEXT NOT NULL,
    content_hash TEXT,
    uuid TEXT,
    details TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS audit_created ON audit (finished_at);
"""


def _migrate_1_to_2(conn: sqlite3.Connection) -> None:
    """Split the queue clock from the write time.

    `queued_at` is when a row entered the pending queue (the reconciler's grace,
    the pending order and the stale-write window read it); `created_at` stays
    the write time. Guarded by `table_info` so a re-entry after an interrupted
    run is a no-op.
    """
    columns = {row[1] for row in conn.execute("PRAGMA table_info(episodes)")}
    if "queued_at" not in columns:
        conn.execute("ALTER TABLE episodes ADD COLUMN queued_at TEXT NOT NULL DEFAULT ''")
    conn.execute("UPDATE episodes SET queued_at = created_at WHERE queued_at = ''")
    conn.execute("CREATE INDEX IF NOT EXISTS episodes_queue ON episodes (status, queued_at)")


# One entry per version a database may be at; each migrates exactly one hop.
_MIGRATIONS = {1: _migrate_1_to_2}


class SchemaVersionError(RuntimeError):
    """The registry database is not the schema version this code writes."""


class AmbiguousRef(ValueError):
    """A reference prefix matches more than one registry row."""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_timestamp(value: str | None) -> datetime | None:
    """Parse a stored ISO timestamp; None when it cannot be read."""
    if not value:
        return None
    try:
        moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def age_seconds(value: str | None, now: datetime) -> float | None:
    moment = parse_timestamp(value)
    return None if moment is None else (now - moment).total_seconds()


@dataclass(frozen=True)
class RegistryEpisode:
    group: str
    content_hash: str
    uuid: str
    name: str
    content: str
    kind: str
    origin: str
    origin_ref: str
    actor: str
    cwd: str
    tags: tuple[str, ...]
    valid_at: str
    created_at: str
    # "" on a row built in memory; the registry stores created_at instead
    queued_at: str = ""
    status: str = "pending"
    attempts: int = 0
    last_error: str | None = None
    graphiti_uuid: str | None = None
    promoted_from_group: str | None = None
    promoted_by: str | None = None
    promoted_at: str | None = None
    tombstoned_at: str | None = None
    tombstone_reason: str | None = None


@dataclass(frozen=True)
class Audit:
    """One tool or reconciler action, written in the same transaction as its state."""

    actor: str
    group: str
    tool: str
    status: str
    content_hash: str | None = None
    uuid: str | None = None
    details: Mapping[str, object] | None = None


def _json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _placeholders(values: tuple[str, ...] | list[str]) -> str:
    return ",".join("?" for _ in values)


def _ensure_schema(conn: sqlite3.Connection, db_path: Path) -> None:
    version = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if version == SCHEMA_VERSION:
        return
    has_tables = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'episodes'"
    ).fetchone()
    if version == 0 and has_tables is None:
        # DDL autocommits under sqlite3's legacy isolation, so the schema and
        # its version have to ride in one explicit transaction: otherwise a
        # kill before the PRAGMA leaves an unversioned database that this code
        # then refuses forever.
        conn.executescript(
            "BEGIN IMMEDIATE;\n" + _SCHEMA + f"\nPRAGMA user_version = {SCHEMA_VERSION};\nCOMMIT;"
        )
        return
    if has_tables is not None and 0 < version < SCHEMA_VERSION:
        conn.execute("BEGIN IMMEDIATE")
        while version < SCHEMA_VERSION:
            _MIGRATIONS[version](conn)
            version += 1
            conn.execute(f"PRAGMA user_version = {version}")
        return
    found = "unversioned" if version == 0 else str(version)
    raise SchemaVersionError(
        f"registry {db_path} has schema version {found}, expected {SCHEMA_VERSION}; "
        "refusing to use it. Delete the database to rebuild the registry from the graph."
    )


def migrate_registry(path: Path) -> None:
    """Migrate one registry file in place (a restore stages the export's copy)."""
    conn = sqlite3.connect(path, timeout=10)
    try:
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        _ensure_schema(conn, path)
        conn.commit()
    finally:
        conn.close()


class Registry:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = Path(state_dir)
        self.db_path = self.state_dir / "registry.sqlite"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            self._ensure_schema(conn)

    def _ensure_schema(self, conn: sqlite3.Connection) -> None:
        _ensure_schema(conn, self.db_path)

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def _row(row: sqlite3.Row | None) -> RegistryEpisode | None:
        if row is None:
            return None
        try:
            tags = tuple(str(tag) for tag in json.loads(row["tags"] or "[]"))
        except (json.JSONDecodeError, TypeError):
            tags = ()
        return RegistryEpisode(
            group=row["group_id"],
            content_hash=row["content_hash"],
            uuid=row["uuid"],
            name=row["name"],
            content=row["content"],
            kind=row["kind"],
            origin=row["origin"],
            origin_ref=row["origin_ref"],
            actor=row["actor"],
            cwd=row["cwd"],
            tags=tags,
            valid_at=row["valid_at"],
            created_at=row["created_at"],
            queued_at=row["queued_at"] or row["created_at"],
            status=row["status"],
            attempts=row["attempts"],
            last_error=row["last_error"],
            graphiti_uuid=row["graphiti_uuid"],
            promoted_from_group=row["promoted_from_group"],
            promoted_by=row["promoted_by"],
            promoted_at=row["promoted_at"],
            tombstoned_at=row["tombstoned_at"],
            tombstone_reason=row["tombstone_reason"],
        )

    @staticmethod
    def _audit(conn: sqlite3.Connection, audit: Audit | None) -> None:
        if audit is None:
            return
        now = utcnow()
        conn.execute(
            """
            INSERT INTO audit
                (started_at, finished_at, actor, group_id, tool, status,
                 content_hash, uuid, details)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                now,
                now,
                audit.actor,
                audit.group,
                audit.tool,
                audit.status,
                audit.content_hash,
                audit.uuid,
                _json(audit.details or {}),
            ),
        )

    def lookup(self, group: str, digest: str) -> RegistryEpisode | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND content_hash = ?",
                (group, digest),
            ).fetchone()
        return self._row(row)

    @staticmethod
    def _insert(conn: sqlite3.Connection, entry: RegistryEpisode) -> None:
        conn.execute(
            """
            INSERT INTO episodes
                (group_id, content_hash, uuid, name, content, kind, origin, origin_ref,
                 actor, cwd, tags, valid_at, created_at, queued_at, status, attempts,
                 last_error, graphiti_uuid, promoted_from_group, promoted_by, promoted_at,
                 tombstoned_at, tombstone_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                entry.group,
                entry.content_hash,
                entry.uuid,
                entry.name,
                entry.content,
                entry.kind,
                entry.origin,
                entry.origin_ref,
                entry.actor,
                entry.cwd,
                _json(list(entry.tags)),
                entry.valid_at,
                entry.created_at,
                entry.queued_at or entry.created_at,
                entry.status,
                entry.attempts,
                entry.last_error,
                entry.graphiti_uuid,
                entry.promoted_from_group,
                entry.promoted_by,
                entry.promoted_at,
                entry.tombstoned_at,
                entry.tombstone_reason,
            ),
        )

    def _write(self, conn: sqlite3.Connection, entry: RegistryEpisode) -> None:
        conn.execute(
            """
            UPDATE episodes SET
                uuid = ?, name = ?, content = ?, kind = ?, origin = ?, origin_ref = ?,
                actor = ?, cwd = ?, tags = ?, valid_at = ?, queued_at = ?,
                status = ?, attempts = ?, last_error = ?, graphiti_uuid = ?,
                promoted_from_group = ?,
                promoted_by = ?, promoted_at = ?, tombstoned_at = ?, tombstone_reason = ?
            WHERE group_id = ? AND content_hash = ?
            """,
            (
                entry.uuid,
                entry.name,
                entry.content,
                entry.kind,
                entry.origin,
                entry.origin_ref,
                entry.actor,
                entry.cwd,
                _json(list(entry.tags)),
                entry.valid_at,
                entry.queued_at or entry.created_at,
                entry.status,
                entry.attempts,
                entry.last_error,
                entry.graphiti_uuid,
                entry.promoted_from_group,
                entry.promoted_by,
                entry.promoted_at,
                entry.tombstoned_at,
                entry.tombstone_reason,
                entry.group,
                entry.content_hash,
            ),
        )

    def queue(self, entry: RegistryEpisode, *, audit: Audit | None = None) -> RegistryEpisode:
        """Insert or replace a row as pending, clearing any prior graph identity."""
        # A row that never left the queue was queued when it was written.
        pending = replace(
            entry,
            queued_at=entry.queued_at or entry.created_at,
            status="pending",
            attempts=0,
            last_error=None,
            graphiti_uuid=None,
            tombstoned_at=None,
            tombstone_reason=None,
        )
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT promoted_from_group, promoted_by, promoted_at FROM episodes "
                "WHERE group_id = ? AND content_hash = ?",
                (pending.group, pending.content_hash),
            ).fetchone()
            if existing is None:
                self._insert(conn, pending)
            else:
                if pending.promoted_from_group is None:
                    pending = replace(
                        pending,
                        promoted_from_group=existing["promoted_from_group"],
                        promoted_by=existing["promoted_by"],
                        promoted_at=existing["promoted_at"],
                    )
                self._write(conn, pending)
            self._audit(conn, audit)
            stored = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND content_hash = ?",
                (pending.group, pending.content_hash),
            ).fetchone()
        return self._row(stored) or pending

    def record_attempt(
        self,
        group: str,
        digest: str,
        *,
        error: str | None = None,
        from_statuses: tuple[str, ...] = ("pending",),
        audit: Audit | None = None,
    ) -> RegistryEpisode | None:
        """Count one submission attempt and remember the latest error.

        The status guard keeps a concurrent tombstone authoritative: a row that
        changed under the caller is left alone and no audit row is written.
        """
        with self._connect() as conn:
            cursor = conn.execute(
                "UPDATE episodes SET attempts = attempts + 1, last_error = ? "
                "WHERE group_id = ? AND content_hash = ? "
                f"AND status IN ({_placeholders(from_statuses)})",
                (error, group, digest, *from_statuses),
            )
            if cursor.rowcount == 0:
                return None
            self._audit(conn, audit)
            row = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND content_hash = ?",
                (group, digest),
            ).fetchone()
        return self._row(row)

    def mark_active(
        self,
        group: str,
        digest: str,
        graphiti_uuid: str,
        *,
        from_statuses: tuple[str, ...] = ("pending",),
        audit: Audit | None = None,
    ) -> bool:
        """Resolve a row to active; False when the row is no longer in `from_statuses`."""
        with self._connect() as conn:
            cursor = conn.execute(
                "UPDATE episodes SET status = 'active', graphiti_uuid = ?, last_error = NULL "
                "WHERE group_id = ? AND content_hash = ? "
                f"AND status IN ({_placeholders(from_statuses)})",
                (graphiti_uuid, group, digest, *from_statuses),
            )
            if cursor.rowcount == 0:
                return False
            self._audit(conn, audit)
        return True

    def mark_failed(
        self,
        group: str,
        digest: str,
        error: str,
        *,
        from_statuses: tuple[str, ...] = ("pending",),
        audit: Audit | None = None,
    ) -> bool:
        """Resolve a row to failed; False when the row is no longer in `from_statuses`."""
        with self._connect() as conn:
            cursor = conn.execute(
                "UPDATE episodes SET status = 'failed', last_error = ? "
                "WHERE group_id = ? AND content_hash = ? "
                f"AND status IN ({_placeholders(from_statuses)})",
                (error, group, digest, *from_statuses),
            )
            if cursor.rowcount == 0:
                return False
            self._audit(conn, audit)
        return True

    def tombstone(
        self,
        entry: RegistryEpisode,
        *,
        reason: str,
        audit: Audit | None = None,
    ) -> RegistryEpisode | None:
        """Mark the row tombstoned and return the stored row; None if it vanished."""
        at = utcnow()
        with self._connect() as conn:
            conn.execute(
                "UPDATE episodes SET status = 'tombstoned', tombstoned_at = ?, "
                "tombstone_reason = ? WHERE group_id = ? AND content_hash = ?",
                (at, reason, entry.group, entry.content_hash),
            )
            self._audit(conn, audit)
            row = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND content_hash = ?",
                (entry.group, entry.content_hash),
            ).fetchone()
        return self._row(row)

    def requeue_many(
        self, entries: Sequence[RegistryEpisode], *, actor: str, tool: str = "memory_reindex"
    ) -> int:
        """Return active rows whose graph episode is gone to pending, in one transaction.

        `queued_at` is the queue clock: the reconciler measures its grace from it
        and `pending()` orders by it, so a requeued row has to re-enter the queue
        now or it would be resubmitted and marked failed within minutes of a
        restore, while its extraction is still waiting upstream. `created_at`,
        the write time, is left alone.

        The status and graph-uuid guards keep a row that changed under the
        caller (a concurrent write re-extracted it, or a tombstone landed)
        untouched. Returns how many rows were requeued.
        """
        at = utcnow()
        applied = 0
        with self._connect() as conn:
            for entry in entries:
                cursor = conn.execute(
                    "UPDATE episodes SET status = 'pending', attempts = 0, last_error = NULL, "
                    "graphiti_uuid = NULL, queued_at = ? "
                    "WHERE group_id = ? AND content_hash = ? AND status = 'active' "
                    "AND graphiti_uuid IS ?",
                    (at, entry.group, entry.content_hash, entry.graphiti_uuid),
                )
                if cursor.rowcount == 0:
                    continue
                self._audit(
                    conn,
                    Audit(
                        actor=actor,
                        group=entry.group,
                        tool=tool,
                        status="requeued",
                        content_hash=entry.content_hash,
                        uuid=entry.uuid,
                        details={
                            "graphiti_uuid": entry.graphiti_uuid,
                            "written_at": entry.created_at,
                        },
                    ),
                )
                applied += 1
        return applied

    def active_page(
        self,
        *,
        after: tuple[str, str, str] | None,
        limit: int,
        group: str | None = None,
    ) -> list[RegistryEpisode]:
        """One page of active rows in `(created_at, content_hash, group_id)` order.

        The cursor tuple orders deterministically and survives rows leaving the
        page: requeued rows drop out of `active`, so a walk that keeps the last
        seen row continues past them.
        """
        clauses = ["status = 'active'"]
        params: list[object] = []
        if group is not None:
            clauses.append("group_id = ?")
            params.append(group)
        if after is not None:
            clauses.append("(created_at, content_hash, group_id) > (?, ?, ?)")
            params.extend(after)
        params.append(max(1, int(limit)))
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM episodes WHERE " + " AND ".join(clauses) + " "
                "ORDER BY created_at, content_hash, group_id LIMIT ?",
                tuple(params),
            ).fetchall()
        return [entry for row in rows if (entry := self._row(row)) is not None]

    def pending(self, *, limit: int = 500) -> list[RegistryEpisode]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM episodes WHERE status = 'pending' "
                "ORDER BY COALESCE(NULLIF(queued_at, ''), created_at) ASC LIMIT ?",
                (max(1, int(limit)),),
            ).fetchall()
        return [entry for row in rows if (entry := self._row(row)) is not None]

    def tombstoned_unverified(self, *, limit: int = 500) -> list[RegistryEpisode]:
        """Tombstoned rows with no graph episode recorded yet.

        `graphiti_uuid IS NULL` marks a tombstone that landed before extraction
        did: the episode Graphiti creates later is still live in the graph and
        still turns up in search. Once the sweep records a uuid, the row leaves
        this set.

        Newest first: a row whose episode never appears would otherwise pin the
        head of the queue forever, and a just-tombstoned write is the one whose
        extraction is still in flight.
        """
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM episodes WHERE status = 'tombstoned' "
                "AND graphiti_uuid IS NULL ORDER BY tombstoned_at DESC LIMIT ?",
                (max(1, int(limit)),),
            ).fetchall()
        return [entry for row in rows if (entry := self._row(row)) is not None]

    def record_graph_uuid(
        self,
        entry: RegistryEpisode,
        graphiti_uuid: str,
        *,
        audit: Audit | None = None,
    ) -> bool:
        """Attach a graph uuid to a tombstoned row; status and tombstoned_at stay.

        The sweep uses this to stop rescanning a row it has already
        invalidated. Guarded on `status='tombstoned'`, so a row revived while
        the sweep ran keeps its fresh identity instead of the stale uuid.
        """
        with self._connect() as conn:
            cursor = conn.execute(
                "UPDATE episodes SET graphiti_uuid = ? WHERE group_id = ? "
                "AND content_hash = ? AND status = 'tombstoned'",
                (graphiti_uuid, entry.group, entry.content_hash),
            )
            if cursor.rowcount == 0:
                return False
            self._audit(conn, audit)
        return True

    def find_exact(self, group: str, ref: str) -> RegistryEpisode | None:
        """Exact uuid5, content-hash prefix (>=12 hex), or exact `origin:origin_ref`.

        References are matched case-insensitively: uuid5 and content hashes are
        lowercase by construction, and an origin ref is a label, not payload.
        A hash prefix that matches more than one row raises `AmbiguousRef`.
        """
        reference = (ref or "").strip().lower()
        if not reference:
            return None
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND uuid = ?",
                (group, reference),
            ).fetchone()
            if row is not None:
                return self._row(row)
            if ":" in reference:
                row = conn.execute(
                    """
                    SELECT * FROM episodes
                    WHERE group_id = ? AND lower(origin || ':' || origin_ref) = ?
                   """,
                    (group, reference),
                ).fetchone()
                if row is not None:
                    return self._row(row)
            if len(reference) >= 12 and all(char in "0123456789abcdef" for char in reference):
                rows = conn.execute(
                    "SELECT * FROM episodes WHERE group_id = ? AND content_hash LIKE ? LIMIT 2",
                    (group, reference + "%"),
                ).fetchall()
                if len(rows) > 1:
                    raise AmbiguousRef(
                        f"{reference!r} matches more than one episode in group {group}; "
                        "use a longer hash prefix or the registry uuid"
                    )
                if rows:
                    return self._row(rows[0])
        return None

    def lookup_many(
        self, group: str, digests: list[str], *, chunk: int = LOOKUP_CHUNK
    ) -> dict[str, RegistryEpisode]:
        """One chunked `IN (...)` lookup instead of a query per hash."""
        wanted = list(dict.fromkeys(str(digest) for digest in digests if digest))
        found: dict[str, RegistryEpisode] = {}
        step = max(1, int(chunk))
        with self._connect() as conn:
            for offset in range(0, len(wanted), step):
                part = wanted[offset : offset + step]
                rows = conn.execute(
                    "SELECT * FROM episodes WHERE group_id = ? "
                    f"AND content_hash IN ({_placeholders(part)})",
                    (group, *part),
                ).fetchall()
                for row in rows:
                    entry = self._row(row)
                    if entry is not None:
                        found[entry.content_hash] = entry
        return found

    def by_graphiti_uuids(self, uuids: set[str] | list[str]) -> dict[str, RegistryEpisode]:
        wanted = [str(uuid) for uuid in uuids if uuid]
        if not wanted:
            return {}
        found: dict[str, RegistryEpisode] = {}
        with self._connect() as conn:
            for offset in range(0, len(wanted), 500):
                chunk = wanted[offset : offset + 500]
                placeholders = ",".join("?" for _ in chunk)
                rows = conn.execute(
                    f"SELECT * FROM episodes WHERE graphiti_uuid IN ({placeholders})",
                    chunk,
                ).fetchall()
                for row in rows:
                    entry = self._row(row)
                    if entry is not None and entry.graphiti_uuid:
                        found[entry.graphiti_uuid] = entry
        return found

    def record_promotion(
        self,
        *,
        source_uuid: str,
        target_uuid: str,
        source_group: str,
        target_group: str,
        actor: str,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR IGNORE INTO promotions
                    (source_uuid, target_uuid, source_group, target_group, actor, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (source_uuid, target_uuid, source_group, target_group, actor, utcnow()),
            )

    def is_promoted(self, source_uuid: str, target_group: str) -> bool:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM promotions WHERE source_uuid = ? AND target_group = ?",
                (source_uuid, target_group),
            ).fetchone()
        return row is not None

    def stats(self, group: str) -> dict[str, object]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                    SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending,
                    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN status = 'tombstoned' THEN 1 ELSE 0 END) AS tombstoned,
                    MAX(created_at) AS last_written
                FROM episodes WHERE group_id = ?
                """,
                (group,),
            ).fetchone()
        return {
            "total": row["total"] or 0,
            "active": row["active"] or 0,
            "pending": row["pending"] or 0,
            "failed": row["failed"] or 0,
            "tombstoned": row["tombstoned"] or 0,
            "last_written": row["last_written"],
        }

    def audit(self, audit: Audit) -> None:
        with self._connect() as conn:
            self._audit(conn, audit)
