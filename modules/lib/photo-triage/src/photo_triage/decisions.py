"""Turn scores, heuristics and duplicate tiers into reviewable decisions."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .db import Database
from .duplicates import HEURISTICS_VERSION, hamming
from .score import PREVIEW_GENERATOR

POLICY = {
    "version": 2,
    "delete_cap": 100,
    "review_only": ["screenshot", "document"],
    "confidence": {
        "dark": 0.75,
        "bright": 0.75,
        "blur": 0.70,
        "low_res": 0.75,
        "general": 0.85,
        "near": 0.75,
    },
    "dark_luma": 55.0,
    "bright_luma": 200.0,
    "bright_clip": 0.2,
    "blur_var": 80.0,
    "low_res_edge": 256,
    "near_distance": 10,
    "protect_stack_primary": True,
}
POLICY_VERSION = hashlib.sha256(json.dumps(POLICY, sort_keys=True).encode("utf-8")).hexdigest()[
    :12
]
TIER_ORDER = {"exact": 0, "near": 1, "similar": 2}


@dataclass(frozen=True)
class _Member:
    asset_id: str
    keep_rank: int | None


@dataclass(frozen=True)
class _Group:
    group_id: str
    tier: str
    members: tuple[_Member, ...]


def _fingerprint(cap: int, models: list[dict[str, Any]]) -> str:
    payload = json.dumps(
        {
            "policy": POLICY,
            "cap": cap,
            "heuristics": HEURISTICS_VERSION,
            "generator": PREVIEW_GENERATOR,
            "models": models,
        },
        sort_keys=True,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]


def _export_digest(document: dict[str, Any]) -> str:
    payload = {key: value for key, value in document.items() if key != "manifest_sha256"}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _defects(row: Any) -> list[str]:
    return list(json.loads(row["defects_json"] or "[]"))


def _models(rows: list[Any]) -> list[dict[str, Any]]:
    seen = {
        (
            str(row["model_id"]),
            str(row["mmproj_sha256"]),
            str(row["prompt_version"]),
        )
        for row in rows
        if row["model_id"] is not None
    }
    return [
        {"model_id": model, "mmproj_sha256": projector, "prompt_version": prompt}
        for model, projector, prompt in sorted(seen)
    ]


def _preview_status(row: Any, completed_at: str) -> str | None:
    if row["preview_state"] != "ready" or row["preview_generator"] != PREVIEW_GENERATOR:
        return "stale_preview"
    if row["preview_heuristics_version"] is None:
        return "missing_metrics"
    if row["preview_heuristics_version"] != HEURISTICS_VERSION:
        return "stale_heuristics"
    if row["preview_sha256"] is None:
        return "stale_preview"
    if row["score_preview_sha256"] != row["preview_sha256"]:
        return "stale_score"
    if (
        row["preview_asset_checksum"] != row["checksum"]
        or row["preview_asset_updated_at"] != row["asset_updated_at"]
    ):
        return "stale_preview"
    if (
        row["lap_var"] is None
        or row["mean_luma"] is None
        or row["hi_clip"] is None
        or row["metrics_sha256"] is None
    ):
        return "missing_metrics"
    if row["metrics_sha256"] != row["preview_sha256"]:
        return "stale_heuristics"
    if row["metrics_at"] is None or row["metrics_at"] > completed_at:
        return "stale_analysis"
    return None


def _cluster(row: Any) -> str:
    defects = set(_defects(row))
    if "screenshot" in defects:
        return "screenshot"
    if "document" in defects:
        return "document"
    mean, clip, lap = row["mean_luma"], row["hi_clip"], row["lap_var"]
    if mean is not None and float(mean) < POLICY["dark_luma"]:
        return "dark"
    if (mean is not None and float(mean) > POLICY["bright_luma"]) or (
        clip is not None and float(clip) > POLICY["bright_clip"]
    ):
        return "bright"
    if lap is not None and float(lap) < POLICY["blur_var"]:
        return "blur"
    width, height = row["width"], row["height"]
    if (
        width is not None
        and height is not None
        and min(int(width), int(height)) < POLICY["low_res_edge"]
    ):
        return "low_res"
    return "general"


def _heuristic(cluster: str) -> bool:
    return cluster in {"blur", "dark", "bright", "low_res"}


def _load_groups(database: Database, scan_id: int) -> dict[str, _Group]:
    grouped: dict[str, tuple[str, list[_Member]]] = {}
    for row in database.duplicate_groups_for_scan(scan_id):
        group_id = str(row["group_id"])
        tier, members = grouped.setdefault(group_id, (str(row["tier"]), []))
        rank = row["keep_rank"]
        members.append(_Member(str(row["asset_id"]), None if rank is None else int(rank)))
    return {
        group_id: _Group(group_id, tier, tuple(members))
        for group_id, (tier, members) in grouped.items()
    }


def _membership(groups: dict[str, _Group]) -> dict[str, tuple[str, ...]]:
    index: dict[str, list[str]] = {}
    for group in groups.values():
        for member in group.members:
            index.setdefault(member.asset_id, []).append(group.group_id)
    return {asset_id: tuple(sorted(ids)) for asset_id, ids in index.items()}


def _rank_of(group: _Group, asset_id: str) -> int | None:
    for member in group.members:
        if member.asset_id == asset_id:
            return member.keep_rank
    return None


def _is_keeper(group: _Group, asset_id: str) -> bool:
    return _rank_of(group, asset_id) == 0


def _group_keeper(group: _Group) -> str | None:
    keepers = [member.asset_id for member in group.members if member.keep_rank == 0]
    return keepers[0] if len(keepers) == 1 else None


def _tier_order(tier: str) -> int:
    return TIER_ORDER.get(tier, len(TIER_ORDER))


def _evaluate_group(
    group: _Group, row: Any, rows_by_id: dict[str, Any], completed_at: str
) -> tuple[str, str, str]:
    """A group may only delete a member when its keeper is trusted and current."""
    tier = group.tier
    keeper = _group_keeper(group)
    if keeper is None:
        return "review", "keeper_ambiguous", tier
    keeper_row = rows_by_id.get(keeper)
    if keeper_row is None or keeper_row["score_id"] is None:
        return "review", "keeper_unscored", tier
    status = _preview_status(keeper_row, completed_at)
    if status is not None:
        return "review", f"keeper_{status}", tier
    if bool(keeper_row["is_trashed"]) or keeper_row["visibility"] != "timeline":
        return "review", "keeper_protected", tier
    keeper_verdict = str(keeper_row["verdict"])
    if tier == "exact":
        if keeper_verdict == "delete":
            return "review", "keeper_untrusted", tier
        if not row["checksum"] or keeper_row["checksum"] != row["checksum"]:
            return "review", "exact_checksum_mismatch", tier
        if keeper_row["preview_sha256"] != row["preview_sha256"]:
            return "review", "exact_preview_mismatch", tier
        return "delete", "exact_duplicate", tier
    if tier == "near":
        if keeper_verdict != "keep":
            return "review", "keeper_untrusted", tier
        if set(_defects(keeper_row)) & set(POLICY["review_only"]):
            return "review", "keeper_review_only", tier
        if row["phash"] is None or keeper_row["phash"] is None:
            return "review", "stale_heuristics", tier
        if hamming(int(keeper_row["phash"]), int(row["phash"])) > POLICY["near_distance"]:
            return "review", "near_distance", tier
        if (
            str(row["verdict"]) == "delete"
            and float(row["confidence"] or 0.0) >= POLICY["confidence"]["near"]
        ):
            return "delete", "near_duplicate", tier
        return "review", "near_review", tier
    return "review", "similar_review", tier


def _group_decision(
    row: Any,
    group_ids: tuple[str, ...],
    groups: dict[str, _Group],
    rows_by_id: dict[str, Any],
    completed_at: str,
) -> tuple[str, str, str]:
    deletable: list[tuple[int, str, str]] = []
    failure: tuple[int, str] | None = None
    for group_id in group_ids:
        group = groups[group_id]
        decision, reason, tier = _evaluate_group(group, row, rows_by_id, completed_at)
        order = _tier_order(tier)
        if decision == "delete":
            deletable.append((order, group_id, tier))
        elif failure is None or order < failure[0]:
            failure = (order, reason)
    if not deletable:
        reason = failure[1] if failure is not None else "unranked"
        tier = min((groups[group_id].tier for group_id in group_ids), key=_tier_order)
        return "review", reason, tier
    _, _, tier = min(deletable, key=lambda item: (item[0], item[1]))
    return "delete", f"{tier}_duplicate", tier


def _classify(
    row: Any,
    group_ids: tuple[str, ...],
    groups: dict[str, _Group],
    rows_by_id: dict[str, Any],
    completed_at: str,
) -> tuple[str, str, str | None, str]:
    asset_id = str(row["asset_id"])
    cluster = _cluster(row)
    keeper_tiers = [
        groups[group_id].tier
        for group_id in group_ids
        if _is_keeper(groups[group_id], asset_id)
    ]
    if keeper_tiers:
        tier = min(keeper_tiers, key=_tier_order)
        return "keep", f"{tier}_keep", tier, cluster
    if bool(row["is_trashed"]):
        return "keep", "protected_trashed", None, cluster
    if bool(row["is_favorite"]):
        return "keep", "protected_favorite", None, cluster
    if bool(row["is_archived"]):
        return "keep", "protected_archived", None, cluster
    if row["visibility"] != "timeline":
        return "keep", "protected_visibility", None, cluster
    if cluster in POLICY["review_only"]:
        return "review", cluster, None, cluster
    if row["score_id"] is None:
        return "review", "missing_score", None, cluster
    status = _preview_status(row, completed_at)
    if status is not None:
        return "review", status, None, cluster
    if any(_rank_of(groups[group_id], asset_id) is None for group_id in group_ids):
        tier = min((groups[group_id].tier for group_id in group_ids), key=_tier_order)
        return "review", "unranked", tier, cluster
    if POLICY["protect_stack_primary"] and bool(row["stack_primary"]):
        return "keep", "protected_stack_primary", None, cluster
    if group_ids:
        decision, reason, tier = _group_decision(
            row, group_ids, groups, rows_by_id, completed_at
        )
        return decision, reason, tier, cluster

    verdict = str(row["verdict"])
    confidence = float(row["confidence"] or 0.0)
    if (
        verdict == "delete"
        and _heuristic(cluster)
        and confidence
        >= POLICY["confidence"].get(cluster, POLICY["confidence"]["general"])
    ):
        return "delete", cluster, None, cluster
    if verdict == "delete":
        return "review", "model_only", None, cluster
    if verdict == "review":
        return "review", "model_review", None, cluster
    return "keep", "model_keep", None, cluster


def _distribution(decisions: list[dict[str, Any]], key: str) -> dict[str, dict[str, int]]:
    distribution: dict[str, dict[str, int]] = {}
    for decision in decisions:
        value = decision[key] or "none"
        bucket = distribution.setdefault(value, {"delete": 0, "review": 0, "keep": 0})
        bucket[decision["decision"]] += 1
    return dict(sorted(distribution.items()))


def _write_temp(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        return Path(temporary)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def decide_scan(
    database: Database,
    scan_id: int,
    *,
    cap: int | None = None,
    export_path: str | Path | None = None,
    allow_partial: bool = False,
    dry_run: bool = False,
) -> dict[str, Any]:
    state = database.scan_state(scan_id)
    if state is None:
        raise ValueError(f"scan {scan_id} does not exist")
    if state in ("running", "failed"):
        raise ValueError(f"scan {scan_id} is {state}; decide cannot use it")
    if state != "complete" and not allow_partial:
        raise ValueError(f"scan {scan_id} is {state}; decide requires a complete scan")
    if not database.analysis_ready(
        scan_id, generator_id=PREVIEW_GENERATOR, heuristics_version=HEURISTICS_VERSION
    ):
        raise ValueError(
            f"scan {scan_id} has no completed analyze run for this generator/heuristics"
        )
    if not database.scan_stacks_imported(scan_id):
        raise ValueError(
            f"scan {scan_id} has no stack import; rescan before deciding"
        )
    limit = POLICY["delete_cap"] if cap is None else int(cap)
    if not 0 <= limit <= POLICY["delete_cap"]:
        raise ValueError(f"cap must be between 0 and {POLICY['delete_cap']}")

    analysis = database.analysis(scan_id)
    if (
        analysis is None
        or int(analysis["groups_built"]) != 1
        or analysis["generator_id"] != PREVIEW_GENERATOR
        or analysis["heuristics_version"] != HEURISTICS_VERSION
    ):
        raise ValueError(
            f"scan {scan_id} has no completed analyze run for this generator/heuristics"
        )
    completed_at = str(analysis["completed_at"])
    analysis_generation = int(analysis["generation"])

    run_id = None if dry_run else database.start_run("decide", scan_id)
    committed = False
    temporary: Path | None = None
    stats: dict[str, Any] = {}
    try:
        rows = database.decision_rows(scan_id)
        groups = _load_groups(database, scan_id)
        membership = _membership(groups)
        rows_by_id = {str(row["asset_id"]): row for row in rows}
        models = _models(rows)
        fingerprint = _fingerprint(limit, models)

        decisions: list[dict[str, Any]] = []
        for row in rows:
            asset_id = str(row["asset_id"])
            group_ids = membership.get(asset_id, ())
            decision, reason, tier, cluster = _classify(
                row, group_ids, groups, rows_by_id, completed_at
            )
            decisions.append(
                {
                    "asset_id": asset_id,
                    "score_id": row["score_id"],
                    "tier": tier,
                    "cluster": cluster,
                    "decision": decision,
                    "reason": reason,
                    "confidence": float(row["confidence"] or 0.0),
                    "signals": {
                        "cap": limit,
                        "tier": tier,
                        "cluster": cluster,
                        "reason": reason,
                        "model_id": row["model_id"],
                        "model_verdict": row["verdict"],
                        "confidence": float(row["confidence"] or 0.0),
                        "defects": _defects(row),
                        "preview_sha256": row["preview_sha256"],
                        "asset_checksum": row["checksum"],
                        "policy_fingerprint": fingerprint,
                        "group_keepers": {
                            group_id: _group_keeper(groups[group_id])
                            for group_id in group_ids
                        },
                        "groups": [
                            {
                                "group_id": group_id,
                                "tier": groups[group_id].tier,
                                "keep_rank": _rank_of(groups[group_id], asset_id),
                            }
                            for group_id in group_ids
                        ],
                    },
                }
            )

        candidates = [
            decision for decision in decisions if decision["decision"] == "delete"
        ]
        candidates.sort(
            key=lambda decision: (
                0 if decision["tier"] == "exact" else 1,
                -decision["confidence"],
                decision["asset_id"],
            )
        )
        allowed = {decision["asset_id"] for decision in candidates[:limit]}
        capped = 0
        for decision in decisions:
            if decision["decision"] == "delete" and decision["asset_id"] not in allowed:
                original = decision["reason"]
                decision["decision"] = "review"
                decision["reason"] = "cap"
                decision["suppressed_by_cap"] = True
                decision["original_reason"] = original
                decision["signals"]["reason"] = "cap"
                decision["signals"]["original_reason"] = original
                decision["signals"]["suppressed_by_cap"] = True
                capped += 1

        undecided = database.undecided_assets(scan_id)
        counts = {
            "delete": sum(1 for decision in decisions if decision["decision"] == "delete"),
            "review": sum(1 for decision in decisions if decision["decision"] == "review"),
            "keep": sum(1 for decision in decisions if decision["decision"] == "keep"),
            "capped": capped,
            "decided": len(decisions),
            "undecided": len(undecided),
            "universe": len(decisions) + len(undecided),
            "images": len(database.scan_image_assets(scan_id)),
            "stack_primaries": database.stack_primary_count(scan_id),
        }
        if counts["decided"] == 0 and counts["universe"] > 0:
            raise ValueError("no scored assets in the scan; run the scorer first")
        export: dict[str, Any] = {
            "scan_id": scan_id,
            "scan_state": state,
            "scan_as_of": database.scan_as_of(scan_id),
            "analysis_completed_at": completed_at,
            "safe_to_delete": state == "complete" and counts["undecided"] == 0,
            "run_id": run_id,
            "policy": POLICY["version"],
            "policy_version": POLICY_VERSION,
            "policy_fingerprint": fingerprint,
            "heuristics_version": HEURISTICS_VERSION,
            "generator_id": PREVIEW_GENERATOR,
            "analysis_generation": analysis_generation,
            "models": models,
            "cap": limit,
            "delete": sorted(
                decision["asset_id"]
                for decision in decisions
                if decision["decision"] == "delete"
            ),
            "review": sorted(
                decision["asset_id"]
                for decision in decisions
                if decision["decision"] == "review"
            ),
            "keep": sorted(
                decision["asset_id"]
                for decision in decisions
                if decision["decision"] == "keep"
            ),
            "undecided": undecided,
            "assets": {
                decision["asset_id"]: {
                    "decision": decision["decision"],
                    "tier": decision["tier"],
                    "cluster": decision["cluster"],
                    "reason": decision["reason"],
                    "confidence": decision["confidence"],
                    "model_verdict": decision["signals"]["model_verdict"],
                    "defects": decision["signals"]["defects"],
                    "preview_sha256": decision["signals"]["preview_sha256"],
                    "asset_checksum": decision["signals"]["asset_checksum"],
                    "groups": decision["signals"]["groups"],
                    "group_keepers": decision["signals"]["group_keepers"],
                    **({
                        "suppressed_by_cap": True,
                        "original_reason": decision["original_reason"],
                    } if decision.get("suppressed_by_cap") else {}),
                }
                for decision in decisions
            },
            "counts": counts,
            "tiers": _distribution(decisions, "tier"),
            "clusters": _distribution(decisions, "cluster"),
            "coverage": database.coverage(scan_id),
        }

        export["manifest_sha256"] = _export_digest(export)

        if dry_run:
            return {**export, "dry_run": True}

        body = json.dumps(export, indent=2, sort_keys=True) + "\n"
        export_sha256 = hashlib.sha256(body.encode("utf-8")).hexdigest()
        destination = Path(export_path) if export_path is not None else None
        if destination is not None:
            temporary = _write_temp(destination, body)

        database.connection.execute("BEGIN IMMEDIATE")
        current = database.analysis(scan_id)
        if (
            current is None
            or int(current["generation"]) != analysis_generation
            or int(current["groups_built"]) != 1
            or current["completed_at"] != completed_at
            or current["generator_id"] != PREVIEW_GENERATOR
            or current["heuristics_version"] != HEURISTICS_VERSION
        ):
            raise ValueError("duplicate analysis changed during decide; rerun decide")
        if run_id is not None:
            run_state = database.connection.execute(
                "SELECT state FROM runs WHERE id = ?", (run_id,)
            ).fetchone()
            if run_state is None or run_state["state"] != "running":
                raise ValueError("this decide run was superseded; rerun decide")

        database.delete_decisions(scan_id)
        for decision in decisions:
            database.insert_decision(
                asset_id=decision["asset_id"],
                scan_id=scan_id,
                policy_version=POLICY_VERSION,
                heuristics_version=HEURISTICS_VERSION,
                score_id=decision["score_id"],
                cluster=decision["cluster"],
                signals=decision["signals"],
                decision=decision["decision"],
            )
        stats = {
            "counts": counts,
            "tiers": export["tiers"],
            "clusters": export["clusters"],
            "cap": limit,
            "policy_version": POLICY_VERSION,
            "policy_fingerprint": fingerprint,
            "heuristics_version": HEURISTICS_VERSION,
            "generator_id": PREVIEW_GENERATOR,
            "analysis_generation": analysis_generation,
            "models": models,
            "export_path": str(destination) if destination is not None else None,
            "export_sha256": export_sha256 if destination is not None else None,
        }
        database.finish_run(run_id, "complete", stats, commit=False)
        database.commit()
        committed = True
        if destination is not None:
            os.replace(temporary, destination)
            temporary = None
            _fsync_directory(destination.parent)
        return export
    except BaseException:
        if not committed:
            database.rollback()
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
                temporary = None
            if run_id is not None:
                database.finish_run(run_id, "failed", stats)
        elif run_id is not None:
            database.finish_run(
                run_id, "failed", {**stats, "export_published": False}
            )
        raise
