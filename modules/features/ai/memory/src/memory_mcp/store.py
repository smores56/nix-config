"""SQLite index for dedup, provenance, promotions, pending writes, and audit.

The graph is the memory model, but Graphiti has no dedup and no arbitrary
metadata. This index is the wrapper's authoritative record of what was written:
it makes writes idempotent, keeps the content needed for promotion, and marks
tombstones without ever calling Graphiti's hard-delete tools.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

DB_NAME = "index.sqlite"
AUDIT_NAME = "audit.jsonl"

# A pending row older than this belongs to a crashed attempt, not an in-flight
# write: re-queueing it cannot double-write while the original request is still
# bounded by the 60s tool deadline.
PENDING_STALE_SECONDS = 120

_SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    group_id TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    uuid TEXT NOT NULL,
    name TEXT NOT NULL,
    content TEXT NOT NULL,
    source TEXT NOT NULL,
    source_id TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL,
    created_at TEXT NOT NULL,
    tags TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    promoted_from TEXT,
    tombstoned_at TEXT,
    tombstone_reason TEXT,
    PRIMARY KEY (group_id, content_hash)
);
CREATE INDEX IF NOT EXISTS episodes_uuid ON episodes (uuid);
CREATE INDEX IF NOT EXISTS episodes_created ON episodes (group_id, created_at DESC);

CREATE TABLE IF NOT EXISTS promotions (
    source_uuid TEXT NOT NULL,
    target_uuid TEXT NOT NULL,
    source_group TEXT NOT NULL,
    target_group TEXT NOT NULL,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (source_uuid, target_group)
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def pending_is_stale(entry: Entry, now: datetime | None = None) -> bool:
    """Whether a pending row is old enough to belong to a crashed attempt."""
    try:
        moment = datetime.fromisoformat(entry.created_at.replace("Z", "+00:00"))
    except ValueError:
        return True
    reference = now or datetime.now(timezone.utc)
    return (reference - moment).total_seconds() > PENDING_STALE_SECONDS


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


@dataclass(frozen=True)
class Entry:
    group: str
    content_hash: str
    uuid: str
    name: str
    content: str
    source: str
    cwd: str
    created_at: str
    source_id: str = ""
    tags: str = ""
    status: str = "active"
    promoted_from: str | None = None
    tombstoned_at: str | None = None
    tombstone_reason: str | None = None


class Store:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = Path(state_dir)
        self.db_path = self.state_dir / DB_NAME
        self.audit_path = self.state_dir / AUDIT_NAME
        self._audit_lock = threading.Lock()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            # `source_id` was dropped as unused before ingestion existed and is
            # back now: additive, so old rows keep their empty provenance.
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(episodes)")}
            if "source_id" not in columns:
                conn.execute("ALTER TABLE episodes ADD COLUMN source_id TEXT NOT NULL DEFAULT ''")
            # Superseded by `episodes.status` + `tombstoned_at`; drop it so an
            # upgraded install does not keep a table nothing writes.
            conn.execute("DROP TABLE IF EXISTS tombstones")

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    @staticmethod
    def _row(row: sqlite3.Row | None) -> Entry | None:
        if row is None:
            return None
        return Entry(
            group=row["group_id"],
            content_hash=row["content_hash"],
            uuid=row["uuid"],
            name=row["name"],
            content=row["content"],
            source=row["source"],
            cwd=row["cwd"],
            source_id=row["source_id"],
            created_at=row["created_at"],
            tags=row["tags"],
            status=row["status"],
            promoted_from=row["promoted_from"],
            tombstoned_at=row["tombstoned_at"],
            tombstone_reason=row["tombstone_reason"],
        )

    def lookup(self, group: str, digest: str) -> Entry | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM episodes WHERE group_id = ? AND content_hash = ?",
                (group, digest),
            ).fetchone()
        return self._row(row)

    def insert(self, entry: Entry) -> bool:
        try:
            with self._connect() as conn:
                conn.execute(
                    """
                    INSERT INTO episodes
                        (group_id, content_hash, uuid, name, content, source,
                         cwd, created_at, source_id, tags, status, promoted_from)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        entry.group,
                        entry.content_hash,
                        entry.uuid,
                        entry.name,
                        entry.content,
                        entry.source,
                        entry.cwd,
                        entry.created_at,
                        entry.source_id,
                        entry.tags,
                        entry.status,
                        entry.promoted_from,
                    ),
                )
            return True
        except sqlite3.IntegrityError:
            return False

    def delete(self, group: str, digest: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "DELETE FROM episodes WHERE group_id = ? AND content_hash = ?",
                (group, digest),
            )

    def set_state(self, entry: Entry) -> None:
        """Write every mutable field back; used for pending/active/tombstone transitions."""
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE episodes
                SET uuid = ?, name = ?, content = ?, source = ?, cwd = ?, created_at = ?,
                    source_id = ?, tags = ?, status = ?, promoted_from = ?, tombstoned_at = ?,
                    tombstone_reason = ?
                WHERE group_id = ? AND content_hash = ?
                """,
                (
                    entry.uuid,
                    entry.name,
                    entry.content,
                    entry.source,
                    entry.cwd,
                    entry.created_at,
                    entry.source_id,
                    entry.tags,
                    entry.status,
                    entry.promoted_from,
                    entry.tombstoned_at,
                    entry.tombstone_reason,
                    entry.group,
                    entry.content_hash,
                ),
            )

    def find(self, group: str, ref: str) -> Entry | None:
        reference = ref.strip()
        if not reference:
            return None
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM episodes
                WHERE group_id = ? AND (uuid = ? OR content_hash = ? OR name = ?)
                ORDER BY created_at DESC LIMIT 1
                """,
                (group, reference, reference.lower(), reference),
            ).fetchone()
            if row is not None or len(reference) < 6:
                return self._row(row)
            pattern = _escape_like(reference.lower()) + "%"
            name_pattern = _escape_like(reference) + "%"
            row = conn.execute(
                """
                SELECT * FROM episodes
                WHERE group_id = ?
                  AND (content_hash LIKE ? ESCAPE '\\'
                       OR uuid LIKE ? ESCAPE '\\'
                       OR name LIKE ? ESCAPE '\\')
                ORDER BY created_at DESC LIMIT 1
                """,
                (group, pattern, pattern, name_pattern),
            ).fetchone()
        return self._row(row)

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

    def tombstone(self, entry: Entry, *, reason: str) -> Entry:
        at = utcnow()
        updated = Entry(
            group=entry.group,
            content_hash=entry.content_hash,
            uuid=entry.uuid,
            name=entry.name,
            content=entry.content,
            source=entry.source,
            cwd=entry.cwd,
            created_at=entry.created_at,
            source_id=entry.source_id,
            tags=entry.tags,
            status="tombstoned",
            promoted_from=entry.promoted_from,
            tombstoned_at=at,
            tombstone_reason=reason,
        )
        self.set_state(updated)
        return updated

    def stats(self, group: str) -> dict[str, object]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                    SUM(CASE WHEN status = 'tombstoned' THEN 1 ELSE 0 END) AS tombstoned,
                    SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending,
                    MAX(created_at) AS last_written
                FROM episodes WHERE group_id = ?
                """,
                (group,),
            ).fetchone()
        return {
            "total": row["total"] or 0,
            "active": row["active"] or 0,
            "tombstoned": row["tombstoned"] or 0,
            "pending": row["pending"] or 0,
            "last_written": row["last_written"],
        }

    def audit(self, *, actor: str, group: str, tool: str, status: str, **fields: object) -> None:
        record = {
            "ts": utcnow(),
            "actor": actor,
            "group": group,
            "tool": tool,
            "status": status,
            **fields,
        }
        line = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
        with self._audit_lock:
            try:
                fd = os.open(self.audit_path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o640)
                try:
                    os.write(fd, line.encode("utf-8"))
                finally:
                    os.close(fd)
            except OSError as exc:  # keep the memory write even if the log disk is full
                print(f"memory audit write failed: {exc}", file=sys.stderr)
