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
import threading
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Mapping

DB_NAME = "registry.sqlite"

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


class Registry:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = Path(state_dir)
        self.db_path = self.state_dir / "registry.sqlite"
        self._lock = threading.Lock()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(_SCHEMA)

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

    def insert(self, entry: RegistryEpisode) -> bool:
        try:
            with self._connect() as conn:
                self._insert(conn, entry)
            return True
        except sqlite3.IntegrityError:
            return False

    @staticmethod
    def _insert(conn: sqlite3.Connection, entry: RegistryEpisode) -> None:
        conn.execute(
            """
            INSERT INTO episodes
                (group_id, content_hash, uuid, name, content, kind, origin, origin_ref,
                 actor, cwd, tags, valid_at, created_at, status, attempts, last_error,
                 graphiti_uuid, promoted_from_group, promoted_by, promoted_at,
                 tombstoned_at, tombstone_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                actor = ?, cwd = ?, tags = ?, valid_at = ?, created_at = ?, status = ?,
                attempts = ?, last_error = ?, graphiti_uuid = ?, promoted_from_group = ?,
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
                entry.created_at,
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
        pending = replace(
            entry,
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
        return pending

    def record_attempt(
        self,
        group: str,
        digest: str,
        *,
        error: str | None = None,
        audit: Audit | None = None,
    ) -> RegistryEpisode | None:
        """Count one submission attempt and remember the latest error."""
        with self._connect() as conn:
            conn.execute(
                "UPDATE episodes SET attempts = attempts + 1, last_error = ? "
                "WHERE group_id = ? AND content_hash = ?",
                (error, group, digest),
            )
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
        audit: Audit | None = None,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE episodes SET status = 'active', graphiti_uuid = ?, last_error = NULL "
                "WHERE group_id = ? AND content_hash = ?",
                (graphiti_uuid, group, digest),
            )
            self._audit(conn, audit)

    def mark_failed(
        self,
        group: str,
        digest: str,
        error: str,
        *,
        audit: Audit | None = None,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE episodes SET status = 'failed', last_error = ? "
                "WHERE group_id = ? AND content_hash = ?",
                (error, group, digest),
            )
            self._audit(conn, audit)

    def tombstone(
        self,
        entry: RegistryEpisode,
        *,
        reason: str,
        audit: Audit | None = None,
    ) -> RegistryEpisode:
        at = utcnow()
        updated = replace(
            entry,
            status="tombstoned",
            tombstoned_at=at,
            tombstone_reason=reason,
        )
        with self._connect() as conn:
            self._write(conn, updated)
            self._audit(conn, audit)
        return updated

    def pending(self, *, limit: int = 500) -> list[RegistryEpisode]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM episodes WHERE status = 'pending' "
                "ORDER BY created_at ASC LIMIT ?",
                (max(1, int(limit)),),
            ).fetchall()
        return [entry for row in rows if (entry := self._row(row)) is not None]

    def find_exact(self, group: str, ref: str) -> RegistryEpisode | None:
        """Exact uuid5, content-hash prefix (>=12 hex), or exact `origin:origin_ref`."""
        reference = (ref or "").strip()
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
                    WHERE group_id = ? AND origin || ':' || origin_ref = ?
                   """,
                    (group, reference),
                ).fetchone()
                if row is not None:
                    return self._row(row)
            if len(reference) >= 12 and all(char in "0123456789abcdefABCDEF" for char in reference):
                rows = conn.execute(
                    "SELECT * FROM episodes WHERE group_id = ? AND content_hash LIKE ? LIMIT 2",
                    (group, reference.lower() + "%"),
                ).fetchall()
                if len(rows) == 1:
                    return self._row(rows[0])
        return None

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
        with self._lock, self._connect() as conn:
            self._audit(conn, audit)
