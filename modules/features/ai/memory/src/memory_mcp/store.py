"""SQLite index for dedup, provenance, promotions, tombstones, and audit.

The graph is the memory model, but Graphiti has no dedup and no arbitrary
metadata. This index is the wrapper's authoritative record of what was written:
it makes writes idempotent, keeps the content needed for promotion, and records
tombstones without ever calling Graphiti's hard-delete tools.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import threading
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

DB_NAME = "index.sqlite"
AUDIT_NAME = "audit.jsonl"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    group_id TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    uuid TEXT NOT NULL,
    name TEXT NOT NULL,
    content TEXT NOT NULL,
    source TEXT NOT NULL,
    source_id TEXT,
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

CREATE TABLE IF NOT EXISTS tombstones (
    group_id TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    uuid TEXT NOT NULL,
    actor TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


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
    source_id: str | None = None
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
            source_id=row["source_id"],
            cwd=row["cwd"],
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
                         source_id, cwd, created_at, tags, status, promoted_from)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        entry.group,
                        entry.content_hash,
                        entry.uuid,
                        entry.name,
                        entry.content,
                        entry.source,
                        entry.source_id,
                        entry.cwd,
                        entry.created_at,
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
            pattern = reference.lower() + "%"
            row = conn.execute(
                """
                SELECT * FROM episodes
                WHERE group_id = ?
                  AND (content_hash LIKE ? OR uuid LIKE ? OR name LIKE ?)
                ORDER BY created_at DESC LIMIT 1
                """,
                (group, pattern, pattern, reference + "%"),
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

    def tombstone(self, entry: Entry, *, actor: str, reason: str) -> Entry:
        at = utcnow()
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE episodes
                SET status = 'tombstoned', tombstoned_at = ?, tombstone_reason = ?
                WHERE group_id = ? AND content_hash = ?
                """,
                (at, reason, entry.group, entry.content_hash),
            )
            conn.execute(
                """
                INSERT INTO tombstones
                    (group_id, content_hash, uuid, actor, reason, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (entry.group, entry.content_hash, entry.uuid, actor, reason, at),
            )
        return replace(
            entry,
            status="tombstoned",
            tombstoned_at=at,
            tombstone_reason=reason,
        )

    def stats(self, group: str) -> dict[str, object]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                    SUM(CASE WHEN status = 'tombstoned' THEN 1 ELSE 0 END) AS tombstoned,
                    MAX(created_at) AS last_written
                FROM episodes WHERE group_id = ?
                """,
                (group,),
            ).fetchone()
        return {
            "total": row["total"] or 0,
            "active": row["active"] or 0,
            "tombstoned": row["tombstoned"] or 0,
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
