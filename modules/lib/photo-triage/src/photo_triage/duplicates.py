"""Deterministic preview heuristics, duplicate tiers, and keep-best ranking."""

from __future__ import annotations

import io
import json
import time
from typing import Any, Callable

import numpy as np
from PIL import Image

from .db import Database
from .immich import ImmichClient, ImmichError
from .score import PREVIEW_GENERATOR, PreviewError, normalize_preview

HEURISTICS_VERSION = "v1"
PHASH_THRESHOLD = 10
MIN_DETAIL = 20.0
MASK = (1 << 64) - 1


def _dct_matrix(size: int = 32) -> np.ndarray:
    k = np.arange(size).reshape(-1, 1)
    x = np.arange(size).reshape(1, -1)
    matrix = np.sqrt(2 / size) * np.cos(np.pi * (2 * x + 1) * k / (2 * size))
    matrix[0] /= np.sqrt(2)
    return matrix


_DCT = _dct_matrix()


def unsigned(value: int) -> int:
    return int(value) & MASK


def signed(value: int) -> int:
    value = unsigned(value)
    return value - (1 << 64) if value >= (1 << 63) else value


def phash(image: Image.Image) -> int:
    gray = image.convert("L").resize((32, 32), Image.Resampling.LANCZOS)
    pixels = np.asarray(gray, dtype=np.float64)
    dct = _DCT @ pixels @ _DCT.T
    low = dct[:8, :8]
    median = np.median(low.flatten()[1:])
    bits = low.flatten() > median
    value = 0
    for bit in bits:
        value = (value << 1) | int(bit)
    return value


def laplacian_variance(image: Image.Image) -> float:
    gray = np.asarray(
        image.convert("L").resize((256, 256), Image.Resampling.LANCZOS),
        dtype=np.float64,
    )
    laplacian = (
        -4 * gray[1:-1, 1:-1]
        + gray[:-2, 1:-1]
        + gray[2:, 1:-1]
        + gray[1:-1, :-2]
        + gray[1:-1, 2:]
    )
    return float(laplacian.var())


def metrics(image: Image.Image) -> dict[str, float | int]:
    gray = np.asarray(image.convert("L"), dtype=np.float64)
    rgb = np.asarray(image.convert("RGB"), dtype=np.float64)
    return {
        "phash": phash(image),
        "lap_var": laplacian_variance(image),
        "mean_luma": float(gray.mean()),
        "hi_clip": float((rgb.max(axis=2) >= 250).mean()),
    }


def hamming(left: int, right: int) -> int:
    return ((unsigned(left) ^ unsigned(right))).bit_count()


class _DisjointSet:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def add(self, item: str) -> None:
        self.parent.setdefault(item, item)

    def find(self, item: str) -> str:
        root = item
        while self.parent[root] != root:
            root = self.parent[root]
        while self.parent[item] != item:
            self.parent[item], item = root, self.parent[item]
        return root

    def union(self, left: str, right: str) -> None:
        left_root, right_root = self.find(left), self.find(right)
        if left_root != right_root:
            self.parent[right_root] = left_root

    def components(self) -> list[list[str]]:
        groups: dict[str, list[str]] = {}
        for item in self.parent:
            groups.setdefault(self.find(item), []).append(item)
        return list(groups.values())


class _BKTree:
    def __init__(self, distance: Callable[[int, int], int] = hamming) -> None:
        self.distance = distance
        self.root: tuple[int, str, dict[int, Any]] | None = None

    def add(self, value: int, item: str) -> None:
        if self.root is None:
            self.root = (value, item, {})
            return
        node = self.root
        while True:
            distance = self.distance(value, node[0])
            if distance == 0:
                return
            child = node[2].get(distance)
            if child is None:
                node[2][distance] = (value, item, {})
                return
            node = child

    def search(self, value: int, radius: int) -> list[str]:
        if self.root is None:
            return []
        found: list[str] = []
        stack = [self.root]
        while stack:
            node = stack.pop()
            distance = self.distance(value, node[0])
            if distance <= radius:
                found.append(node[1])
            for edge, child in node[2].items():
                if distance - radius <= edge <= distance + radius:
                    stack.append(child)
        return found


def _fetch_preview(
    immich: ImmichClient, asset_id: str, sleep: Callable[[float], None]
) -> bytes | None:
    for attempt in range(3):
        try:
            return immich.thumbnail(asset_id)
        except ImmichError as error:
            if error.transient and attempt < 2:
                sleep(2**attempt)
                continue
            return None
    return None


def _rank(rows: list[Any], suggested: set[str]) -> list[tuple[str, int]]:
    def key(row: Any) -> tuple:
        return (
            0 if row["id"] in suggested else 1,
            0 if row["is_favorite"] else 1,
            1 if row["is_archived"] else 0,
            1 if row["is_trashed"] else 0,
            0 if (row["visibility"] or "timeline") == "timeline" else 1,
            -((row["width"] or 0) * (row["height"] or 0)),
            -float(row["lap_var"] or 0.0),
            float(row["hi_clip"] or 0.0),
            -(row["file_size"] or 0),
            row["taken_at"] or "",
            str(row["id"]),
        )

    return [(str(row["id"]), rank) for rank, row in enumerate(sorted(rows, key=key))]


def _record_skipped(database: Database, asset_id: str, revision: tuple[str | None, str | None]) -> None:
    database.record_preview(
        asset_id,
        state="skipped",
        reason="preview",
        generator_id=PREVIEW_GENERATOR,
        bytes_sha256=None,
        asset_checksum=revision[0],
        asset_updated_at=revision[1],
    )
    database.commit()


def _preview_metrics(
    immich: ImmichClient,
    database: Database,
    asset_id: str,
    sleep: Callable[[float], None],
) -> str:
    revision = database.asset_revision(asset_id)
    cached = database.preview(asset_id)
    if (
        cached is not None
        and cached["state"] == "ready"
        and cached["bytes_sha256"]
        and cached["generator_id"] == PREVIEW_GENERATOR
        and cached["asset_checksum"] == revision[0]
        and cached["asset_updated_at"] == revision[1]
        and cached["heuristics_version"] == HEURISTICS_VERSION
        and cached["phash"] is not None
    ):
        return "ready"
    raw = _fetch_preview(immich, asset_id, sleep)
    if raw is None:
        _record_skipped(database, asset_id, revision)
        return "skipped"
    try:
        normalized, digest = normalize_preview(raw)
        image = Image.open(io.BytesIO(normalized)).convert("RGB")
        values = metrics(image)
    except (OSError, ValueError, PreviewError, Image.DecompressionBombError):
        _record_skipped(database, asset_id, revision)
        return "skipped"
    database.record_preview(
        asset_id,
        state="ready",
        reason=None,
        generator_id=PREVIEW_GENERATOR,
        bytes_sha256=digest,
        asset_checksum=revision[0],
        asset_updated_at=revision[1],
    )
    database.update_preview_metrics(
        asset_id,
        phash=signed(int(values["phash"])),
        lap_var=float(values["lap_var"]),
        mean_luma=float(values["mean_luma"]),
        hi_clip=float(values["hi_clip"]),
        heuristics_version=HEURISTICS_VERSION,
    )
    database.commit()
    return "ready"


def analyze_scan(
    immich: ImmichClient,
    database: Database,
    scan_id: int,
    *,
    threshold: int = PHASH_THRESHOLD,
    max_assets: int | None = None,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, int]:
    stats = {
        "assets": 0,
        "previews": 0,
        "skipped": 0,
        "exact_groups": 0,
        "near_groups": 0,
        "immich_groups": 0,
    }
    run_id = database.start_run("analyze", scan_id)
    try:
        asset_ids = database.scan_image_assets(scan_id, max_assets)
        stats["assets"] = len(asset_ids)
        for asset_id in asset_ids:
            status = _preview_metrics(immich, database, asset_id, sleep)
            stats["previews" if status == "ready" else "skipped"] += 1

        if max_assets is None:
            database.clear_generated_groups(scan_id)

            exact_ids: set[str] = set()
            for checksum, members in database.exact_duplicate_groups(scan_id):
                exact_ids.update(members)
                rows = [database.asset_metrics(asset_id) for asset_id in members]
                rows = [row for row in rows if row is not None]
                database.insert_duplicate_group(
                    scan_id,
                    f"exact:{checksum}",
                    "exact",
                    "exact",
                    json.dumps({"checksum": checksum}, sort_keys=True),
                    [(asset_id, 0.0, rank) for asset_id, rank in _rank(rows, set())],
                )
                stats["exact_groups"] += 1

            phash_by_asset: dict[str, int] = {}
            for asset_id, phash_value, lap_var in database.scan_phash_rows(
                scan_id,
                generator_id=PREVIEW_GENERATOR,
                heuristics_version=HEURISTICS_VERSION,
            ):
                if asset_id in exact_ids or lap_var < MIN_DETAIL:
                    continue
                phash_by_asset[asset_id] = unsigned(phash_value)

            tree = _BKTree()
            components = _DisjointSet()
            for asset_id, phash_value in phash_by_asset.items():
                components.add(asset_id)
                for other in tree.search(phash_value, threshold):
                    components.union(asset_id, other)
                tree.add(phash_value, asset_id)
            for component in components.components():
                representative = min(component)
                component = [
                    asset_id
                    for asset_id in component
                    if hamming(phash_by_asset[asset_id], phash_by_asset[representative])
                    <= threshold
                ]
                if len(component) < 2:
                    continue
                rows = [database.asset_metrics(asset_id) for asset_id in component]
                rows = [row for row in rows if row is not None]
                database.insert_duplicate_group(
                    scan_id,
                    f"near:{representative}",
                    "near",
                    "near",
                    json.dumps({"threshold": threshold}, sort_keys=True),
                    [
                        (
                            asset_id,
                            float(
                                hamming(phash_by_asset[asset_id], phash_by_asset[representative])
                            ),
                            keep_rank,
                        )
                        for asset_id, keep_rank in _rank(rows, set())
                    ],
                )
                stats["near_groups"] += 1

            for group in database.immich_duplicate_groups(scan_id):
                distance = json.loads(group["distance_json"])
                suggested = set(distance.get("suggestedKeepAssetIds", []))
                member_ids = [
                    row["asset_id"]
                    for row in database.connection.execute(
                        "SELECT asset_id FROM duplicate_members WHERE scan_id = ? AND group_id = ?",
                        (scan_id, group["group_id"]),
                    ).fetchall()
                ]
                rows = [database.asset_metrics(asset_id) for asset_id in member_ids]
                rows = [row for row in rows if row is not None]
                database.update_duplicate_keep_ranks(
                    scan_id, group["group_id"], _rank(rows, suggested)
                )
                stats["immich_groups"] += 1

            database.commit()

        database.finish_run(run_id, "complete", stats)
        return stats
    except BaseException:
        try:
            database.rollback()
            database.finish_run(run_id, "failed", stats)
        except Exception:
            pass
        raise
