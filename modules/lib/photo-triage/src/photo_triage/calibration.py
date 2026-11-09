"""Stratified calibration samples, labels, Wilson intervals and go/no-go."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any

from .albums import AlbumReport, sync_album
from .db import Database
from .immich import ImmichClient

LABELS = frozenset({"keep", "delete"})
CALIBRATION_KINDS = ("calibration-dev", "calibration-heldout")


def _digest(asset_id: str) -> str:
    return hashlib.sha256(asset_id.encode("utf-8")).hexdigest()


def decisions_for_scan(database: Database, scan_id: int) -> list[dict[str, Any]]:
    decisions = []
    for row in database.decisions_for_scan(scan_id):
        signals = json.loads(row["signals_json"] or "{}")
        decisions.append(
            {
                "asset_id": str(row["asset_id"]),
                "decision": str(row["decision"]),
                "cluster": str(row["cluster"] or "general"),
                "tier": signals.get("tier"),
                "groups": [
                    str(group.get("group_id"))
                    for group in signals.get("groups") or []
                    if isinstance(group, dict) and group.get("group_id")
                ],
            }
        )
    return decisions


def _group_key(item: dict[str, Any]) -> str:
    groups = sorted(str(group) for group in item.get("groups") or [])
    return "|".join(groups) if groups else str(item["asset_id"])


def _unique_decisions(decisions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep one asset per duplicate group; copies are not independent samples."""
    unique: dict[str, dict[str, Any]] = {}
    for item in decisions:
        key = _group_key(item)
        current = unique.get(key)
        order = (_digest(item["asset_id"]), item["asset_id"])
        if current is None or order < (
            _digest(current["asset_id"]),
            current["asset_id"],
        ):
            unique[key] = dict(item)
    return list(unique.values())


def build_sample(
    decisions: list[dict[str, Any]],
    *,
    min_per_cluster: int = 30,
    total: int = 300,
) -> list[dict[str, Any]]:
    if min_per_cluster < 1 or total < 1:
        raise ValueError("min_per_cluster and total must be positive")
    items = _unique_decisions(decisions)
    groups: dict[str, list[dict[str, Any]]] = {}
    for item in items:
        groups.setdefault(str(item["cluster"]), []).append(item)
    for cluster in groups:
        groups[cluster].sort(
            key=lambda item: (
                0 if item["decision"] == "delete" else 1,
                _digest(item["asset_id"]),
                item["asset_id"],
            )
        )
    target = max(total, min_per_cluster * len(groups))
    selected: list[dict[str, Any]] = []
    for cluster in sorted(groups):
        selected.extend(groups[cluster][:min_per_cluster])
    chosen = {item["asset_id"] for item in selected}
    remaining = [item for item in items if item["asset_id"] not in chosen]
    remaining.sort(
        key=lambda item: (
            0 if item["decision"] == "delete" else 1,
            _digest(item["asset_id"]),
            item["asset_id"],
        )
    )
    selected.extend(remaining[: max(0, target - len(selected))])
    return selected


def split_sample(
    sample: list[dict[str, Any]], *, dev_fraction: float = 0.4
) -> dict[str, list[dict[str, Any]]]:
    if not 0 < dev_fraction < 1:
        raise ValueError("dev_fraction must be between 0 and 1")
    groups: dict[str, list[dict[str, Any]]] = {}
    for item in sample:
        groups.setdefault(str(item["cluster"]), []).append(dict(item))
    dev: list[dict[str, Any]] = []
    heldout: list[dict[str, Any]] = []
    for cluster in sorted(groups):
        items = sorted(
            groups[cluster], key=lambda item: (_digest(item["asset_id"]), item["asset_id"])
        )
        count = len(items)
        if count < 2:
            dev.extend(items)
            continue
        dev_count = min(count - 1, max(1, round(count * dev_fraction)))
        dev.extend(items[:dev_count])
        heldout.extend(items[dev_count:])
    return {"dev": dev, "heldout": heldout}


def wilson(successes: int, total: int, *, z: float = 1.96) -> tuple[float, float]:
    if total <= 0:
        return (0.0, 0.0)
    p = successes / total
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    margin = (
        z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    )
    return (max(0.0, centre - margin), min(1.0, centre + margin))


def _bucket(
    items: list[dict[str, Any]], labels: dict[str, str]
) -> dict[str, Any]:
    checked = [item for item in items if labels.get(item["asset_id"]) in LABELS]
    total = len(checked)
    false = sum(1 for item in checked if labels[item["asset_id"]] == "keep")
    true = total - false
    low, high = wilson(false, total)
    precision_low, precision_high = wilson(true, total)
    return {
        "candidates": len(items),
        "labelled": total,
        "unlabelled": len(items) - total,
        "false_deletes": false,
        "true_deletes": true,
        "false_rate": (false / total) if total else None,
        "false_rate_wilson": [low, high] if total else [None, None],
        "precision": (true / total) if total else None,
        "precision_wilson": [precision_low, precision_high] if total else [None, None],
    }


def label_report(
    decisions: list[dict[str, Any]],
    labels: dict[str, str],
    asset_ids: list[str],
) -> dict[str, Any]:
    decision_map = {item["asset_id"]: item for item in decisions}
    selected = [decision_map[asset_id] for asset_id in asset_ids if asset_id in decision_map]
    labelled = {asset_id: labels[asset_id] for asset_id in asset_ids if asset_id in labels}
    delete_candidates = [
        item for item in selected if item["decision"] == "delete"
    ]
    clusters: dict[str, dict[str, Any]] = {}
    for item in delete_candidates:
        clusters.setdefault(str(item["cluster"]), []).append(item)
    return {
        "selected": len(selected),
        "labelled": len(labelled),
        "delete_candidates": len(delete_candidates),
        "overall": _bucket(delete_candidates, labels),
        "clusters": {
            cluster: _bucket(items, labels)
            for cluster, items in sorted(clusters.items())
        },
    }


def go_no_go(
    report: dict[str, Any],
    *,
    max_false_rate: float = 0.0,
    min_labelled: int = 30,
) -> dict[str, Any]:
    if max_false_rate < 0 or max_false_rate > 1:
        raise ValueError("max_false_rate must be between 0 and 1")
    if min_labelled < 1:
        raise ValueError("min_labelled must be positive")
    overall = report["overall"]
    if overall["labelled"] == 0:
        return {
            "passed": False,
            "reason": "no labelled delete candidates",
            "rule": "none",
            "max_false_rate": max_false_rate,
            "min_labelled": min_labelled,
            "labelled": 0,
        }
    if overall["labelled"] < min_labelled:
        return {
            "passed": False,
            "reason": f"only {overall['labelled']} labels; need at least {min_labelled}",
            "rule": "minimum-labels",
            "max_false_rate": max_false_rate,
            "min_labelled": min_labelled,
            "labelled": overall["labelled"],
        }
    if max_false_rate == 0:
        passed = overall["false_deletes"] == 0
        rule = "zero-false-deletes"
    else:
        passed = overall["false_rate_wilson"][1] <= max_false_rate
        rule = "wilson-upper-bound"
    return {
        "passed": passed,
        "reason": "ok" if passed else "false-delete bound exceeded",
        "rule": rule,
        "max_false_rate": max_false_rate,
        "min_labelled": min_labelled,
        "labelled": overall["labelled"],
        "false_deletes": overall["false_deletes"],
        "false_rate": overall["false_rate"],
        "wilson_upper": overall["false_rate_wilson"][1],
    }


def sample_name(scan_id: int) -> str:
    return f"scan-{scan_id}"


def record_sample(
    database: Database, name: str, scan_id: int, split: dict[str, list[dict[str, Any]]]
) -> None:
    assets = [(item["asset_id"], "dev") for item in split["dev"]]
    assets.extend((item["asset_id"], "heldout") for item in split["heldout"])
    database.record_sample(name, scan_id, assets)


def load_labels(path: str | Path) -> list[tuple[str, str]]:
    try:
        payload = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read labels {path}: {error}") from error
    if isinstance(payload, dict):
        entries = list(payload.items())
    elif isinstance(payload, list):
        entries = [
            (item.get("asset_id"), item.get("label"))
            for item in payload
            if isinstance(item, dict)
        ]
    else:
        raise ValueError("labels must be a JSON object or list")
    if isinstance(payload, list) and any(not isinstance(item, dict) for item in payload):
        raise ValueError("every label entry must be an object")
    labels: dict[str, str] = {}
    for asset_id, label in entries:
        if not isinstance(asset_id, str) or not asset_id:
            raise ValueError("every label needs an asset_id")
        if label not in LABELS:
            raise ValueError(f"label for {asset_id} must be one of {sorted(LABELS)}")
        if asset_id in labels:
            raise ValueError(f"duplicate label for {asset_id}")
        labels[asset_id] = str(label)
    return sorted(labels.items())


def record_labels(
    database: Database,
    decisions: list[dict[str, Any]],
    entries: list[tuple[str, str]],
    *,
    source: str = "human",
) -> int:
    clusters = {item["asset_id"]: item["cluster"] for item in decisions}
    rows = [
        (asset_id, clusters.get(asset_id), label, source)
        for asset_id, label in entries
    ]
    database.record_labels(rows)
    return len(rows)


def publish_sample(
    database: Database,
    client: ImmichClient,
    scan_id: int,
    split: dict[str, list[dict[str, Any]]],
    *,
    chunk: int = 100,
) -> list[AlbumReport]:
    if database.latest_complete_scan() != scan_id:
        raise ValueError(f"scan {scan_id} is not the latest complete scan")
    if database.latest_decide_run(scan_id) is None:
        raise ValueError("the scan has no complete decide run")
    client.assert_album_permissions()
    reports = []
    for kind, items in zip(CALIBRATION_KINDS, (split["dev"], split["heldout"])):
        reports.append(
            sync_album(
                database,
                client,
                kind,
                [item["asset_id"] for item in items],
                generation=scan_id,
                dry_run=False,
                reconcile=True,
                chunk=chunk,
            )
        )
    return reports


def build_report(
    database: Database,
    scan_id: int,
    name: str,
    *,
    max_false_rate: float = 0.0,
    min_labelled: int = 30,
    source: str = "human",
) -> dict[str, Any]:
    if database.latest_complete_scan() != scan_id:
        raise ValueError(f"scan {scan_id} is not the latest complete scan")
    decide_run_id = database.latest_decide_run(scan_id)
    if decide_run_id is None:
        raise ValueError("the scan has no complete decide run")
    run = database.run(decide_run_id)
    stats = json.loads(run["stats_json"] or "{}")
    rows = database.sample_assets(name)
    if not rows:
        raise ValueError(f"no sample named {name}; run calibration sample first")
    if any(int(row["scan_id"]) != scan_id for row in rows):
        raise ValueError(f"sample {name} belongs to another scan")
    decisions = decisions_for_scan(database, scan_id)
    sample = {row["asset_id"]: row["split"] for row in rows}
    label_rows = [
        row for row in database.labels_for(list(sample)) if row["source"] == source
    ]
    labels = {str(row["asset_id"]): str(row["label"]) for row in label_rows}
    sources: dict[str, int] = {}
    for row in database.labels_for(list(sample)):
        sources[str(row["source"])] = sources.get(str(row["source"]), 0) + 1
    ids_by_split = {
        split: [asset_id for asset_id, value in sample.items() if value == split]
        for split in ("dev", "heldout")
    }
    report: dict[str, Any] = {
        "name": name,
        "scan_id": scan_id,
        "decide_run_id": decide_run_id,
        "policy_version": stats.get("policy_version"),
        "policy_fingerprint": stats.get("policy_fingerprint"),
        "heuristics_version": stats.get("heuristics_version"),
        "source": source,
        "label_sources": dict(sorted(sources.items())),
        "dev": label_report(decisions, labels, ids_by_split["dev"]),
        "heldout": label_report(decisions, labels, ids_by_split["heldout"]),
        "overall": label_report(decisions, labels, list(sample)),
    }
    report["go_no_go"] = go_no_go(
        report["heldout"],
        max_false_rate=max_false_rate,
        min_labelled=min_labelled,
    )
    return report


def record_report(
    database: Database, scan_id: int, report: dict[str, Any]
) -> int:
    run_id = database.start_run("calibration-report", scan_id)
    database.finish_run(
        run_id,
        "complete" if report["go_no_go"]["passed"] else "failed",
        report,
    )
    return run_id
