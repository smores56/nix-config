"""SQLite schema and scan-generation helpers for photo-triage."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "6"
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    scan_id INTEGER,
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
CREATE TABLE IF NOT EXISTS scan_analysis (
    scan_id INTEGER PRIMARY KEY,
    generation INTEGER NOT NULL,
    generator_id TEXT NOT NULL,
    heuristics_version TEXT NOT NULL,
    groups_built INTEGER NOT NULL,
    completed_at TEXT NOT NULL
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
    asset_checksum TEXT,
    asset_updated_at TEXT,
    phash INTEGER,
    lap_var REAL,
    mean_luma REAL,
    hi_clip REAL,
    heuristics_version TEXT,
    metrics_sha256 TEXT,
    metrics_at TEXT
);
CREATE TABLE IF NOT EXISTS scores (
    id INTEGER PRIMARY KEY,
    asset_id TEXT NOT NULL,
    preview_sha256 TEXT NOT NULL,
    model_id TEXT NOT NULL,
    mmproj_sha256 TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    verdict TEXT NOT NULL CHECK (verdict IN ('keep', 'review', 'delete')),
    defects_json TEXT NOT NULL,
    interest INTEGER CHECK (interest BETWEEN 1 AND 5),
    confidence REAL CHECK (confidence BETWEEN 0 AND 1),
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
    decided_at TEXT NOT NULL,
    PRIMARY KEY (scan_id, asset_id)
);
CREATE INDEX IF NOT EXISTS decisions_asset ON decisions(asset_id);
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
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


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
        self._migrate()

    def _migrate(self) -> None:
        row = self.connection.execute(
            "SELECT value FROM schema_meta WHERE key = 'schema_version'"
        ).fetchone()
        if row is None:
            self.connection.execute(
                "INSERT INTO schema_meta(key, value) VALUES ('schema_version', ?)",
                (SCHEMA_VERSION,),
            )
            self.connection.commit()
            return
        current, target = int(row["value"]), int(SCHEMA_VERSION)
        if current > target:
            raise RuntimeError(
                f"photo-triage database schema {current} is newer than {target}"
            )
        if current == target:
            return
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            row = self.connection.execute(
                "SELECT value FROM schema_meta WHERE key = 'schema_version'"
            ).fetchone()
            current = int(row["value"])
            if current > target:
                raise RuntimeError(
                    f"photo-triage database schema {current} is newer than {target}"
                )
            if current < 4:
                if "heuristics_version" not in self._columns("previews"):
                    self.connection.execute(
                        "ALTER TABLE previews ADD COLUMN heuristics_version TEXT"
                    )
                current = 4
            if current < 5:
                self._migrate_decisions_primary_key()
                current = 5
            if current < 6:
                columns = self._columns("previews")
                if "metrics_sha256" not in columns:
                    self.connection.execute(
                        "ALTER TABLE previews ADD COLUMN metrics_sha256 TEXT"
                    )
                if "metrics_at" not in columns:
                    self.connection.execute("ALTER TABLE previews ADD COLUMN metrics_at TEXT")
                self.connection.execute(
                    "CREATE TABLE IF NOT EXISTS scan_analysis ("
                    "scan_id INTEGER PRIMARY KEY, generation INTEGER NOT NULL, "
                    "generator_id TEXT NOT NULL, heuristics_version TEXT NOT NULL, "
                    "groups_built INTEGER NOT NULL, completed_at TEXT NOT NULL)"
                )
                current = 6
            self._write_schema_version(target)
            self.connection.commit()
        except BaseException:
            self.connection.rollback()
            raise

    def _columns(self, table: str) -> set[str]:
        return {
            str(item["name"])
            for item in self.connection.execute(f"PRAGMA table_info({table})").fetchall()
        }

    def _write_schema_version(self, version: int) -> None:
        self.connection.execute(
            "UPDATE schema_meta SET value = ? WHERE key = 'schema_version'", (str(version),)
        )

    def _migrate_decisions_primary_key(self) -> None:
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS decisions_v5 ("
            "asset_id TEXT NOT NULL, scan_id INTEGER NOT NULL, "
            "policy_version TEXT NOT NULL, heuristics_version TEXT NOT NULL, "
            "score_id INTEGER REFERENCES scores(id), cluster TEXT, "
            "signals_json TEXT NOT NULL, decision TEXT NOT NULL, "
            "decided_at TEXT NOT NULL, PRIMARY KEY (scan_id, asset_id))"
        )
        self.connection.execute("DELETE FROM decisions_v5")
        self.connection.execute(
            "INSERT OR REPLACE INTO decisions_v5("
            "asset_id, scan_id, policy_version, heuristics_version, score_id, "
            "cluster, signals_json, decision, decided_at) "
            "SELECT asset_id, scan_id, policy_version, heuristics_version, score_id, "
            "cluster, signals_json, decision, decided_at FROM decisions"
        )
        self.connection.execute("DROP TABLE decisions")
        self.connection.execute("ALTER TABLE decisions_v5 RENAME TO decisions")
        self.connection.execute(
            "CREATE INDEX IF NOT EXISTS decisions_asset ON decisions(asset_id)"
        )

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

    def scan_as_of(self, scan_id: int) -> str | None:
        row = self.connection.execute("SELECT as_of FROM scans WHERE id = ?", (scan_id,)).fetchone()
        return row["as_of"] if row else None

    def latest_scan(self) -> int | None:
        row = self.connection.execute(
            "SELECT id FROM scans WHERE state IN ('complete', 'partial') ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return int(row["id"]) if row else None

    def latest_complete_scan(self) -> int | None:
        row = self.connection.execute(
            "SELECT id FROM scans WHERE state = 'complete' ORDER BY id DESC LIMIT 1"
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
            "UPDATE previews SET state = NULL, reason = NULL, phash = NULL, "
            "lap_var = NULL, mean_luma = NULL, hi_clip = NULL, heuristics_version = NULL "
            "WHERE asset_id IN (SELECT asset_id FROM scan_assets WHERE scan_id = ? "
            "AND state = 'pending')",
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

    def pending_assets(self, scan_id: int, limit: int | None = None) -> list[str]:
        statement = (
            "SELECT sa.asset_id FROM scan_assets sa "
            "JOIN assets a ON a.id = sa.asset_id "
            "WHERE sa.scan_id = ? AND sa.state = 'pending' "
            "ORDER BY sa.asset_id"
        )
        parameters: list[Any] = [scan_id]
        if limit is not None:
            statement += " LIMIT ?"
            parameters.append(limit)
        rows = self.connection.execute(statement, parameters).fetchall()
        return [str(row["asset_id"]) for row in rows]

    def start_run(self, kind: str, scan_id: int | None = None) -> int:
        if scan_id is not None:
            self.connection.execute(
                "UPDATE runs SET state = 'interrupted', finished_at = ? "
                "WHERE kind = ? AND scan_id = ? AND state = 'running'",
                (_now(), kind, scan_id),
            )
        cursor = self.connection.execute(
            "INSERT INTO runs(kind, scan_id, started_at, state) VALUES (?, ?, ?, 'running')",
            (kind, scan_id, _now()),
        )
        self.connection.commit()
        return int(cursor.lastrowid)

    def start_analysis(
        self, scan_id: int, *, generator_id: str, heuristics_version: str
    ) -> int:
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            row = self.analysis(scan_id)
            generation = (int(row["generation"]) if row is not None else 0) + 1
            self.connection.execute(
                "INSERT INTO scan_analysis(scan_id, generation, generator_id, "
                "heuristics_version, groups_built, completed_at) VALUES (?, ?, ?, ?, 0, ?) "
                "ON CONFLICT(scan_id) DO UPDATE SET generation = excluded.generation, "
                "generator_id = excluded.generator_id, "
                "heuristics_version = excluded.heuristics_version, groups_built = 0, "
                "completed_at = excluded.completed_at",
                (scan_id, generation, generator_id, heuristics_version, _now()),
            )
            self.connection.commit()
            return generation
        except BaseException:
            self.connection.rollback()
            raise

    def finish_analysis(self, scan_id: int, generation: int, *, commit: bool = True) -> None:
        self.connection.execute(
            "UPDATE scan_analysis SET groups_built = 1, completed_at = ? "
            "WHERE scan_id = ? AND generation = ?",
            (_now(), scan_id, generation),
        )
        if commit:
            self.connection.commit()

    def analysis(self, scan_id: int) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM scan_analysis WHERE scan_id = ?", (scan_id,)
        ).fetchone()

    def analysis_ready(
        self, scan_id: int, *, generator_id: str, heuristics_version: str
    ) -> bool:
        row = self.analysis(scan_id)
        return bool(
            row is not None
            and int(row["groups_built"]) == 1
            and row["generator_id"] == generator_id
            and row["heuristics_version"] == heuristics_version
        )

    def finish_run(
        self, run_id: int, state: str, stats: dict[str, Any], *, commit: bool = True
    ) -> None:
        self.connection.execute(
            "UPDATE runs SET finished_at = ?, state = ?, stats_json = ? WHERE id = ?",
            (_now(), state, json.dumps(stats, sort_keys=True), run_id),
        )
        if commit:
            self.connection.commit()

    def preview(self, asset_id: str) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM previews WHERE asset_id = ?", (asset_id,)
        ).fetchone()

    def record_preview(
        self,
        asset_id: str,
        *,
        state: str,
        reason: str | None,
        generator_id: str,
        bytes_sha256: str | None,
        asset_checksum: str | None = None,
        asset_updated_at: str | None = None,
    ) -> None:
        self.connection.execute(
            "INSERT INTO previews(asset_id, state, reason, generator_id, bytes_sha256, "
            "asset_checksum, asset_updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(asset_id) DO UPDATE SET state = excluded.state, "
            "reason = excluded.reason, generator_id = excluded.generator_id, "
            "bytes_sha256 = excluded.bytes_sha256, asset_checksum = excluded.asset_checksum, "
            "asset_updated_at = excluded.asset_updated_at",
            (asset_id, state, reason, generator_id, bytes_sha256, asset_checksum, asset_updated_at),
        )

    def mark_scan_asset(
        self, scan_id: int, asset_id: str, state: str, reason: str | None = None
    ) -> None:
        self.connection.execute(
            "UPDATE scan_assets SET state = ?, reason = ? WHERE scan_id = ? AND asset_id = ?",
            (state, reason, scan_id, asset_id),
        )

    def active_score(
        self,
        asset_id: str,
        preview_sha256: str,
        model_id: str,
        mmproj_sha256: str,
        prompt_version: str,
    ) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT id FROM scores WHERE asset_id = ? AND preview_sha256 = ? "
            "AND model_id = ? AND mmproj_sha256 = ? AND prompt_version = ? AND is_active = 1",
            (asset_id, preview_sha256, model_id, mmproj_sha256, prompt_version),
        ).fetchone()

    def record_score(
        self,
        *,
        asset_id: str,
        preview_sha256: str,
        model_id: str,
        mmproj_sha256: str,
        prompt_version: str,
        verdict: str,
        defects: list[str],
        interest: int,
        confidence: float,
        raw_sha256: str,
    ) -> None:
        with self.connection:
            self.connection.execute(
                "UPDATE scores SET is_active = 0 WHERE asset_id = ? AND NOT ("
                "preview_sha256 = ? AND model_id = ? AND mmproj_sha256 = ? AND prompt_version = ?)",
                (asset_id, preview_sha256, model_id, mmproj_sha256, prompt_version),
            )
            self.connection.execute(
                "INSERT INTO scores(asset_id, preview_sha256, model_id, mmproj_sha256, "
                "prompt_version, verdict, defects_json, interest, confidence, raw_sha256, "
                "created_at, is_active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1) "
                "ON CONFLICT(asset_id, preview_sha256, model_id, mmproj_sha256, prompt_version) "
                "DO UPDATE SET is_active = 1, verdict = excluded.verdict, "
                "defects_json = excluded.defects_json, interest = excluded.interest, "
                "confidence = excluded.confidence, raw_sha256 = excluded.raw_sha256, "
                "created_at = excluded.created_at",
                (
                    asset_id,
                    preview_sha256,
                    model_id,
                    mmproj_sha256,
                    prompt_version,
                    verdict,
                    json.dumps(defects, sort_keys=True),
                    interest,
                    confidence,
                    raw_sha256,
                    _now(),
                ),
            )

    def asset_revision(self, asset_id: str) -> tuple[str | None, str | None]:
        row = self.connection.execute(
            "SELECT checksum, updated_at FROM assets WHERE id = ?", (asset_id,)
        ).fetchone()
        return (row["checksum"], row["updated_at"]) if row else (None, None)

    def rollback(self) -> None:
        self.connection.rollback()


    def scan_image_assets(self, scan_id: int, limit: int | None = None) -> list[str]:
        statement = (
            "SELECT sa.asset_id FROM scan_assets sa "
            "JOIN assets a ON a.id = sa.asset_id "
            "WHERE sa.scan_id = ? AND a.type = 'IMAGE' ORDER BY sa.asset_id"
        )
        parameters: list[Any] = [scan_id]
        if limit is not None:
            statement += " LIMIT ?"
            parameters.append(limit)
        return [str(row["asset_id"]) for row in self.connection.execute(statement, parameters)]

    def update_preview_metrics(
        self,
        asset_id: str,
        *,
        phash: int,
        lap_var: float,
        mean_luma: float,
        hi_clip: float,
        heuristics_version: str,
        bytes_sha256: str,
    ) -> None:
        self.connection.execute(
            "UPDATE previews SET phash = ?, lap_var = ?, mean_luma = ?, hi_clip = ?, "
            "heuristics_version = ?, metrics_sha256 = ?, metrics_at = ? WHERE asset_id = ?",
            (
                phash,
                lap_var,
                mean_luma,
                hi_clip,
                heuristics_version,
                bytes_sha256,
                _now(),
                asset_id,
            ),
        )

    def asset_metrics(self, asset_id: str) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT a.id, a.width, a.height, a.file_size, a.taken_at, a.is_favorite, "
            "a.is_archived, a.is_trashed, a.visibility, p.lap_var, p.mean_luma, p.hi_clip "
            "FROM assets a LEFT JOIN previews p ON p.asset_id = a.id WHERE a.id = ?",
            (asset_id,),
        ).fetchone()

    def clear_generated_groups(self, scan_id: int) -> None:
        self.connection.execute(
            "DELETE FROM duplicate_members WHERE scan_id = ? AND group_id IN "
            "(SELECT group_id FROM duplicate_groups WHERE scan_id = ? AND source IN ('exact', 'near'))",
            (scan_id, scan_id),
        )
        self.connection.execute(
            "DELETE FROM duplicate_groups WHERE scan_id = ? AND source IN ('exact', 'near')",
            (scan_id,),
        )

    def insert_duplicate_group(
        self,
        scan_id: int,
        group_id: str,
        source: str,
        tier: str,
        distance_json: str,
        members: list[tuple[str, float | None, int]],
    ) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO duplicate_groups"
            "(scan_id, group_id, source, tier, distance_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (scan_id, group_id, source, tier, distance_json, _now()),
        )
        for asset_id, distance, keep_rank in members:
            self.connection.execute(
                "INSERT OR REPLACE INTO duplicate_members"
                "(scan_id, group_id, asset_id, distance, keep_rank) VALUES (?, ?, ?, ?, ?)",
                (scan_id, group_id, asset_id, distance, keep_rank),
            )

    def exact_duplicate_groups(self, scan_id: int) -> list[tuple[str, list[str]]]:
        rows = self.connection.execute(
            "SELECT a.checksum AS checksum, group_concat(a.id) AS ids FROM scan_assets sa "
            "JOIN assets a ON a.id = sa.asset_id WHERE sa.scan_id = ? AND a.type = 'IMAGE' "
            "AND a.checksum IS NOT NULL AND a.checksum != '' "
            "GROUP BY a.checksum HAVING count(*) >= 2",
            (scan_id,),
        ).fetchall()
        return [(str(row["checksum"]), sorted(str(row["ids"]).split(","))) for row in rows]

    def scan_phash_rows(
        self, scan_id: int, *, generator_id: str, heuristics_version: str
    ) -> list[tuple[str, int, float]]:
        rows = self.connection.execute(
            "SELECT sa.asset_id AS asset_id, p.phash AS phash, p.lap_var AS lap_var "
            "FROM scan_assets sa JOIN previews p ON p.asset_id = sa.asset_id "
            "JOIN assets a ON a.id = sa.asset_id WHERE sa.scan_id = ? AND a.type = 'IMAGE' "
            "AND p.state = 'ready' AND p.generator_id = ? AND p.heuristics_version = ? "
            "AND p.phash IS NOT NULL ORDER BY sa.asset_id",
            (scan_id, generator_id, heuristics_version),
        ).fetchall()
        return [
            (str(row["asset_id"]), int(row["phash"]), float(row["lap_var"] or 0.0))
            for row in rows
        ]

    def immich_duplicate_groups(self, scan_id: int) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT group_id, distance_json FROM duplicate_groups "
            "WHERE scan_id = ? AND source = 'immich'",
            (scan_id,),
        ).fetchall()

    def update_duplicate_keep_ranks(
        self, scan_id: int, group_id: str, ranked: list[tuple[str, int]]
    ) -> None:
        for asset_id, keep_rank in ranked:
            self.connection.execute(
                "UPDATE duplicate_members SET keep_rank = ? WHERE scan_id = ? "
                "AND group_id = ? AND asset_id = ?",
                (keep_rank, scan_id, group_id, asset_id),
            )

    def score_count(self) -> int:
        row = self.connection.execute("SELECT count(*) AS count FROM scores").fetchone()
        return int(row["count"])

    def preview_count(self) -> int:
        row = self.connection.execute("SELECT count(*) AS count FROM previews").fetchone()
        return int(row["count"])

    def decision_rows(self, scan_id: int) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT sa.asset_id AS asset_id, a.width AS width, a.height AS height, "
            "a.checksum AS checksum, a.updated_at AS asset_updated_at, "
            "a.is_favorite AS is_favorite, a.is_archived AS is_archived, "
            "a.is_trashed AS is_trashed, a.visibility AS visibility, "
            "p.state AS preview_state, p.generator_id AS preview_generator, "
            "p.heuristics_version AS preview_heuristics_version, "
            "p.bytes_sha256 AS preview_sha256, p.asset_checksum AS preview_asset_checksum, "
            "p.asset_updated_at AS preview_asset_updated_at, "
            "p.metrics_sha256 AS metrics_sha256, p.metrics_at AS metrics_at, "
            "p.phash AS phash, p.lap_var AS lap_var, p.mean_luma AS mean_luma, "
            "p.hi_clip AS hi_clip, "
            "s.id AS score_id, s.preview_sha256 AS score_preview_sha256, "
            "s.model_id AS model_id, s.mmproj_sha256 AS mmproj_sha256, "
            "s.prompt_version AS prompt_version, "
            "s.verdict AS verdict, s.defects_json AS defects_json, "
            "s.interest AS interest, s.confidence AS confidence "
            "FROM scan_assets sa JOIN assets a ON a.id = sa.asset_id "
            "LEFT JOIN previews p ON p.asset_id = sa.asset_id "
            "LEFT JOIN scores s ON s.id = (SELECT id FROM scores "
            "WHERE asset_id = sa.asset_id AND is_active = 1 "
            "AND preview_sha256 = p.bytes_sha256 ORDER BY id DESC LIMIT 1) "
            "WHERE sa.scan_id = ? AND sa.state IN ('scored', 'reused') "
            "AND a.type = 'IMAGE' "
            "ORDER BY sa.asset_id",
            (scan_id,),
        ).fetchall()

    def undecided_assets(self, scan_id: int) -> list[str]:
        return [
            str(row["asset_id"])
            for row in self.connection.execute(
                "SELECT sa.asset_id FROM scan_assets sa JOIN assets a ON a.id = sa.asset_id "
                "WHERE sa.scan_id = ? AND sa.state NOT IN ('scored', 'reused') "
                "AND a.type = 'IMAGE' ORDER BY sa.asset_id",
                (scan_id,),
            )
        ]

    def duplicate_groups_for_scan(self, scan_id: int) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT g.group_id AS group_id, g.source AS source, g.tier AS tier, "
            "gm.asset_id AS asset_id, gm.keep_rank AS keep_rank, gm.distance AS distance "
            "FROM duplicate_groups g JOIN duplicate_members gm "
            "ON gm.scan_id = g.scan_id AND gm.group_id = g.group_id "
            "WHERE g.scan_id = ? ORDER BY g.group_id, gm.keep_rank",
            (scan_id,),
        ).fetchall()

    def delete_decisions(self, scan_id: int) -> None:
        self.connection.execute("DELETE FROM decisions WHERE scan_id = ?", (scan_id,))

    def insert_decision(
        self,
        *,
        asset_id: str,
        scan_id: int,
        policy_version: str,
        heuristics_version: str,
        score_id: int | None,
        cluster: str,
        signals: dict[str, Any],
        decision: str,
    ) -> None:
        self.connection.execute(
            "INSERT INTO decisions(asset_id, scan_id, policy_version, heuristics_version, "
            "score_id, cluster, signals_json, decision, decided_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                asset_id,
                scan_id,
                policy_version,
                heuristics_version,
                score_id,
                cluster,
                json.dumps(signals, sort_keys=True),
                decision,
                _now(),
            ),
        )

    def decisions_for_scan(self, scan_id: int) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT asset_id, decision, cluster, signals_json FROM decisions "
            "WHERE scan_id = ? ORDER BY asset_id",
            (scan_id,),
        ).fetchall()

    def run(self, run_id: int) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM runs WHERE id = ?", (run_id,)
        ).fetchone()

    def latest_decide_run(self, scan_id: int) -> int | None:
        row = self.connection.execute(
            "SELECT id FROM runs WHERE kind = 'decide' AND scan_id = ? "
            "AND state = 'complete' ORDER BY id DESC LIMIT 1",
            (scan_id,),
        ).fetchone()
        return int(row["id"]) if row else None

    def album(self, kind: str) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM albums WHERE kind = ?", (kind,)
        ).fetchone()

    def set_album(self, kind: str, immich_album_id: str, generation: int | None) -> None:
        with self.connection:
            self.connection.execute(
                "INSERT INTO albums(kind, immich_album_id, generation, last_synced_at) "
                "VALUES (?, ?, ?, NULL) ON CONFLICT(kind) DO UPDATE SET "
                "immich_album_id = excluded.immich_album_id, "
                "generation = excluded.generation, last_synced_at = NULL",
                (kind, immich_album_id, generation),
            )

    def album_members(self, kind: str) -> list[str]:
        return [
            str(row["asset_id"])
            for row in self.connection.execute(
                "SELECT asset_id FROM album_membership WHERE kind = ? ORDER BY asset_id",
                (kind,),
            )
        ]

    def replace_album_members(
        self, kind: str, asset_ids: list[str], generation: int
    ) -> None:
        synced_at = _now()
        with self.connection:
            self.connection.execute(
                "DELETE FROM album_membership WHERE kind = ?", (kind,)
            )
            self.connection.executemany(
                "INSERT INTO album_membership(kind, asset_id, generation, synced_at) "
                "VALUES (?, ?, ?, ?)",
                [(kind, asset_id, generation, synced_at) for asset_id in asset_ids],
            )
            self.connection.execute(
                "UPDATE albums SET generation = ?, last_synced_at = ? WHERE kind = ?",
                (generation, synced_at, kind),
            )
