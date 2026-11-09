"""SQLite schema and scan-generation helpers for photo-triage."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "2"
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    state TEXT NOT NULL,
    stats_json TEXT
);
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY,
    as_of TEXT NOT NULL,
    filters_json TEXT NOT NULL,
    state TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS scan_assets (
    scan_id INTEGER NOT NULL,
    asset_id TEXT NOT NULL,
    state TEXT NOT NULL,
    reason TEXT,
    PRIMARY KEY (scan_id, asset_id)
);
CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    type TEXT,
    taken_at TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0,
    is_trashed INTEGER NOT NULL DEFAULT 0,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    visibility TEXT,
    width INTEGER,
    height INTEGER,
    file_size INTEGER,
    checksum TEXT,
    original_file_name TEXT,
    exif_json TEXT,
    updated_at TEXT
);
CREATE TABLE IF NOT EXISTS previews (
    asset_id TEXT PRIMARY KEY,
    state TEXT,
    reason TEXT,
    generator_id TEXT,
    bytes_sha256 TEXT,
    phash INTEGER,
    lap_var REAL,
    mean_luma REAL,
    hi_clip REAL
);
CREATE TABLE IF NOT EXISTS scores (
    id INTEGER PRIMARY KEY,
    asset_id TEXT NOT NULL,
    preview_sha256 TEXT NOT NULL,
    model_id TEXT NOT NULL,
    mmproj_sha256 TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    verdict TEXT NOT NULL,
    defects_json TEXT NOT NULL,
    interest INTEGER,
    confidence REAL,
    raw_sha256 TEXT,
    created_at TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    UNIQUE(asset_id, preview_sha256, model_id, mmproj_sha256, prompt_version)
);
CREATE TABLE IF NOT EXISTS decisions (
    asset_id TEXT NOT NULL,
    scan_id INTEGER NOT NULL,
    policy_version TEXT NOT NULL,
    heuristics_version TEXT NOT NULL,
    score_id INTEGER REFERENCES scores(id),
    cluster TEXT,
    signals_json TEXT NOT NULL,
    decision TEXT NOT NULL,
    decided_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS albums (
    kind TEXT PRIMARY KEY,
    immich_album_id TEXT,
    generation INTEGER,
    last_synced_at TEXT
);
CREATE TABLE IF NOT EXISTS album_membership (
    kind TEXT NOT NULL,
    asset_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    synced_at TEXT NOT NULL,
    PRIMARY KEY (kind, asset_id)
);
CREATE TABLE IF NOT EXISTS labels (
    asset_id TEXT NOT NULL,
    cluster TEXT,
    label TEXT NOT NULL,
    source TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS label_sets (
    name TEXT PRIMARY KEY,
    split TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS duplicate_groups (
    scan_id INTEGER NOT NULL,
    group_id TEXT NOT NULL,
    source TEXT NOT NULL,
    tier TEXT NOT NULL,
    distance_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (scan_id, group_id)
);
CREATE TABLE IF NOT EXISTS duplicate_members (
    scan_id INTEGER NOT NULL,
    group_id TEXT NOT NULL,
    asset_id TEXT NOT NULL,
    distance REAL,
    keep_rank INTEGER,
    PRIMARY KEY (scan_id, group_id, asset_id)
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Database:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(self.path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.executescript(SCHEMA)
        row = self.connection.execute(
            "SELECT value FROM schema_meta WHERE key = 'schema_version'"
        ).fetchone()
        if row is not None and row["value"] != SCHEMA_VERSION:
            raise RuntimeError(
                f"photo-triage database schema {row['value']} is not {SCHEMA_VERSION}; "
                "migrate or remove the database before running"
            )
        self.connection.execute(
            "INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', ?)",
            (SCHEMA_VERSION,),
        )
        self.connection.commit()

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> "Database":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def commit(self) -> None:
        self.connection.commit()

    def start_scan(self, filters: dict[str, Any], as_of: str | None = None) -> int:
        cursor = self.connection.execute(
            "INSERT INTO scans(as_of, filters_json, state) VALUES (?, ?, 'running')",
            (as_of or _now(), json.dumps(filters, sort_keys=True)),
        )
        self.connection.commit()
        return int(cursor.lastrowid)

    def finish_scan(self, scan_id: int, state: str) -> None:
        self.connection.execute("UPDATE scans SET state = ? WHERE id = ?", (state, scan_id))
        self.connection.commit()

    def scan_state(self, scan_id: int) -> str | None:
        row = self.connection.execute("SELECT state FROM scans WHERE id = ?", (scan_id,)).fetchone()
        return row["state"] if row else None

    def latest_scan(self) -> int | None:
        row = self.connection.execute(
            "SELECT id FROM scans WHERE state IN ('complete', 'partial') ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return int(row["id"]) if row else None

    def upsert_asset(self, asset: dict[str, Any]) -> None:
        exif = asset.get("exifInfo") or {}
        self.connection.execute(
            """
            INSERT INTO assets(
                id, type, taken_at, is_archived, is_trashed, is_favorite, visibility,
                width, height, file_size, checksum, original_file_name, exif_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                type = excluded.type,
                taken_at = excluded.taken_at,
                is_archived = excluded.is_archived,
                is_trashed = excluded.is_trashed,
                is_favorite = excluded.is_favorite,
                visibility = excluded.visibility,
                width = excluded.width,
                height = excluded.height,
                file_size = excluded.file_size,
                checksum = excluded.checksum,
                original_file_name = excluded.original_file_name,
                exif_json = excluded.exif_json,
                updated_at = excluded.updated_at
            """,
            (
                str(asset["id"]),
                asset.get("type"),
                asset.get("localDateTime"),
                int(bool(asset.get("isArchived"))),
                int(bool(asset.get("isTrashed"))),
                int(bool(asset.get("isFavorite"))),
                asset.get("visibility"),
                asset.get("width"),
                asset.get("height"),
                exif.get("fileSizeInByte"),
                asset.get("checksum"),
                asset.get("originalFileName"),
                json.dumps(exif, sort_keys=True),
                asset.get("updatedAt"),
            ),
        )

    def add_scan_asset(self, scan_id: int, asset_id: str, state: str, reason: str | None) -> None:
        self.connection.execute(
            "INSERT OR IGNORE INTO scan_assets(scan_id, asset_id, state, reason) VALUES (?, ?, ?, ?)",
            (scan_id, asset_id, state, reason),
        )

    def coverage(self, scan_id: int) -> dict[str, Any]:
        rows = self.connection.execute(
            "SELECT state, reason, count(*) AS count FROM scan_assets "
            "WHERE scan_id = ? GROUP BY state, reason",
            (scan_id,),
        ).fetchall()
        states: dict[str, int] = {}
        reasons: dict[str, int] = {}
        total = 0
        for row in rows:
            count = int(row["count"])
            state = row["state"]
            total += count
            states[state] = states.get(state, 0) + count
            if state == "skipped":
                reason = row["reason"] or "unknown"
                reasons[reason] = reasons.get(reason, 0) + count
        return {
            "scan_id": scan_id,
            "state": self.scan_state(scan_id),
            "total": total,
            "states": states,
            "reasons": reasons,
        }

    def requeue(self, scan_id: int, reason: str | None = None) -> int:
        statement = (
            "UPDATE scan_assets SET state = 'pending', reason = NULL "
            "WHERE scan_id = ? AND state = 'skipped'"
        )
        parameters: list[Any] = [scan_id]
        if reason is not None:
            statement += " AND reason = ?"
            parameters.append(reason)
        cursor = self.connection.execute(statement, parameters)
        self.connection.execute(
            "UPDATE previews SET state = NULL, reason = NULL WHERE asset_id IN "
            "(SELECT asset_id FROM scan_assets WHERE scan_id = ? AND state = 'pending')",
            (scan_id,),
        )
        self.connection.commit()
        return cursor.rowcount

    def import_duplicates(self, scan_id: int, groups: list[dict[str, Any]]) -> None:
        created_at = _now()
        for group in groups:
            group_id = str(group.get("duplicateId") or "")
            if not group_id:
                continue
            suggested = [str(value) for value in group.get("suggestedKeepAssetIds") or []]
            member_ids = [
                str(member.get("id"))
                for member in group.get("assets") or []
                if member.get("id")
                and self.connection.execute(
                    "SELECT 1 FROM scan_assets WHERE scan_id = ? AND asset_id = ?",
                    (scan_id, str(member["id"])),
                ).fetchone()
            ]
            if not member_ids:
                continue
            self.connection.execute(
                "INSERT OR REPLACE INTO duplicate_groups"
                "(scan_id, group_id, source, tier, distance_json, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    scan_id,
                    group_id,
                    "immich",
                    "similar",
                    json.dumps({"suggestedKeepAssetIds": suggested}, sort_keys=True),
                    created_at,
                ),
            )
            for asset_id in member_ids:
                self.connection.execute(
                    "INSERT OR REPLACE INTO duplicate_members"
                    "(scan_id, group_id, asset_id, distance, keep_rank) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (scan_id, group_id, asset_id, None, 0 if asset_id in suggested else 1),
                )
        self.connection.commit()

    def duplicates_summary(self, scan_id: int) -> dict[str, int]:
        groups = self.connection.execute(
            "SELECT count(*) AS count FROM duplicate_groups WHERE scan_id = ?", (scan_id,)
        ).fetchone()["count"]
        members = self.connection.execute(
            "SELECT count(*) AS count FROM duplicate_members WHERE scan_id = ?", (scan_id,)
        ).fetchone()["count"]
        return {"groups": int(groups), "members": int(members)}
