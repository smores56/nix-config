"""Reconcile a signed-off decision export into the two Immich triage albums."""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .db import Database
from .decisions import POLICY_VERSION
from .duplicates import HEURISTICS_VERSION
from .immich import ImmichClient, ImmichError
from .score import PREVIEW_GENERATOR

ALBUM_NAMES = {
    "delete": "triage-delete",
    "review": "triage-review",
    "calibration-dev": "photo-triage-dev",
    "calibration-heldout": "photo-triage-heldout",
}
CHUNK_MAX = 1000


class AlbumError(Exception):
    pass


@dataclass(frozen=True)
class AlbumReport:
    kind: str
    album_id: str | None
    created: bool
    add: tuple[str, ...]
    remove: tuple[str, ...]
    failures: tuple[dict[str, Any], ...]
    expected: int
    asset_count: int | None
    reconciled: bool

    def as_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "album_id": self.album_id,
            "created": self.created,
            "add": list(self.add),
            "remove": list(self.remove),
            "failures": list(self.failures),
            "expected": self.expected,
            "asset_count": self.asset_count,
            "reconciled": self.reconciled,
        }


def _canonical(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def manifest_digest(export: dict[str, Any]) -> str:
    payload = {key: value for key, value in export.items() if key != "manifest_sha256"}
    return hashlib.sha256(_canonical(payload)).hexdigest()


WRITABLE_KINDS = ("delete", "review")


def _checked_kinds(kinds: tuple[str, ...]) -> tuple[str, ...]:
    if isinstance(kinds, str) or not kinds:
        raise AlbumError("no album kinds requested")
    unknown = sorted(set(kinds) - set(WRITABLE_KINDS))
    if unknown:
        raise AlbumError(f"unknown album kinds: {unknown}")
    return tuple(dict.fromkeys(kinds))


def load_export(
    database: Database,
    path: str | Path,
    *,
    kinds: tuple[str, ...] = WRITABLE_KINDS,
) -> dict[str, Any]:
    kinds = _checked_kinds(kinds)
    path = Path(path)
    try:
        export = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AlbumError(f"cannot read export {path}: {error}") from error
    if not isinstance(export, dict):
        raise AlbumError(f"export {path} is not a JSON object")
    verify_export(database, export, path=path, kinds=kinds)
    return export


def verify_export(
    database: Database,
    export: dict[str, Any],
    *,
    path: str | Path | None = None,
    require_calibration: bool = True,
    kinds: tuple[str, ...] = WRITABLE_KINDS,
) -> None:
    """Refuse any export that is not the latest complete decide artifact.

    `kinds` narrows the run to one album. Only the delete album needs a complete
    universe and a passed calibration; a review-only sync of a partial run is
    safe because it never proposes a deletion.
    """
    required = {
        "scan_id",
        "scan_state",
        "run_id",
        "policy_version",
        "policy_fingerprint",
        "heuristics_version",
        "generator_id",
        "analysis_generation",
        "cap",
        "delete",
        "review",
        "keep",
        "undecided",
        "assets",
        "counts",
        "safe_to_delete",
        "manifest_sha256",
    }
    missing = sorted(required - set(export))
    if missing:
        raise AlbumError(f"export is missing fields: {missing}")
    if export["scan_state"] != "complete":
        raise AlbumError(f"export scan state is {export['scan_state']}, not complete")
    if "delete" in kinds and export["safe_to_delete"] is not True:
        raise AlbumError("export is not marked safe_to_delete")
    if manifest_digest(export) != export["manifest_sha256"]:
        raise AlbumError("export manifest hash does not match its contents")
    if export["policy_version"] != POLICY_VERSION:
        raise AlbumError("export was decided under another policy; decide again")
    if export["heuristics_version"] != HEURISTICS_VERSION:
        raise AlbumError("export was analyzed under another heuristics version; analyze again")
    if export["generator_id"] != PREVIEW_GENERATOR:
        raise AlbumError("export was analyzed by another preview generator; analyze again")
    if not database.scan_stacks_imported(export["scan_id"]):
        raise AlbumError("export's scan has no stack import; rescan and decide again")

    buckets = {
        name: {str(asset_id) for asset_id in export[name]}
        for name in ("delete", "review", "keep")
    }
    assets = set(export["assets"])
    union = buckets["delete"] | buckets["review"] | buckets["keep"]
    if union != assets:
        raise AlbumError("export decision lists do not match the asset map")
    if (
        buckets["delete"] & buckets["review"]
        or buckets["delete"] & buckets["keep"]
        or buckets["review"] & buckets["keep"]
    ):
        raise AlbumError("export decision lists overlap")
    for bucket, decision in (("delete", "delete"), ("review", "review"), ("keep", "keep")):
        for asset_id in export[bucket]:
            if export["assets"][asset_id].get("decision") != decision:
                raise AlbumError(
                    f"asset {asset_id} is listed for {bucket} with another decision"
                )
    undecided = {str(asset_id) for asset_id in export["undecided"]}
    if undecided & assets:
        raise AlbumError("undecided assets overlap the decided asset map")
    counts = export["counts"]
    if len(undecided) != counts.get("undecided"):
        raise AlbumError("export undecided count does not match the list")
    if counts.get("delete") != len(buckets["delete"]):
        raise AlbumError("export delete count does not match the list")
    if counts.get("review") != len(buckets["review"]):
        raise AlbumError("export review count does not match the list")
    if counts.get("keep") != len(buckets["keep"]):
        raise AlbumError("export keep count does not match the list")
    if counts.get("decided") != len(assets):
        raise AlbumError("export decided count does not match the asset map")
    if counts.get("universe") != counts.get("decided", 0) + counts.get("undecided", 0):
        raise AlbumError("export universe count does not reconcile")

    run_id = export["run_id"]
    if not isinstance(run_id, int):
        raise AlbumError("export has no decide run id")
    run = database.run(run_id)
    if run is None:
        raise AlbumError(f"decide run {run_id} does not exist")
    if (
        run["kind"] != "decide"
        or run["state"] != "complete"
        or run["scan_id"] != export["scan_id"]
    ):
        raise AlbumError(f"decide run {run_id} is not a complete run for this scan")
    if database.latest_decide_run(export["scan_id"]) != run_id:
        raise AlbumError(
            f"decide run {run_id} is not the latest decide run for scan {export['scan_id']}"
        )
    if database.latest_complete_scan() != export["scan_id"]:
        raise AlbumError(
            f"scan {export['scan_id']} is not the latest complete scan; rescan and decide first"
        )
    if require_calibration and "delete" in kinds:
        report_row = database.latest_calibration_report(export["scan_id"])
        if report_row is None or report_row["state"] != "complete":
            raise AlbumError(
                "no passing calibration report for this scan; run calibration report"
            )
        report = json.loads(report_row["stats_json"] or "{}")
        if not report.get("go_no_go", {}).get("passed"):
            raise AlbumError("the latest calibration report did not pass")
        if report.get("decide_run_id") != export["run_id"]:
            raise AlbumError("calibration report is for another decide run")
        if report.get("policy_fingerprint") != export["policy_fingerprint"]:
            raise AlbumError("calibration report policy does not match this export")
    stats = json.loads(run["stats_json"] or "{}")
    for key in (
        "policy_version",
        "policy_fingerprint",
        "heuristics_version",
        "generator_id",
        "analysis_generation",
        "cap",
    ):
        if stats.get(key) != export[key]:
            raise AlbumError(f"export {key} does not match decide run {run_id}")
    if path is not None:
        digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        if digest != stats.get("export_sha256"):
            raise AlbumError(
                f"export file {path} does not match the latest decide run {run_id}"
            )


def ensure_album(
    client: ImmichClient, database: Database, kind: str
) -> tuple[str, bool]:
    """Return (album id, created). Recreate the album when the UI deleted it."""
    name = ALBUM_NAMES[kind]
    row = database.album(kind)
    stored = str(row["immich_album_id"]) if row and row["immich_album_id"] else None
    if stored is not None:
        try:
            client.album(stored)
            return stored, False
        except ImmichError as error:
            if error.status not in (400, 404):
                raise
    matches = client.albums(name)
    if len(matches) > 1:
        raise AlbumError(f"multiple albums named {name}")
    created = False
    if matches:
        album_id = str(matches[0]["id"])
        album = client.album(album_id)
        if int(album.get("assetCount", 0)) != 0:
            raise AlbumError(
                f"refusing to adopt non-empty album {name} "
                f"({album.get('assetCount')} assets)"
            )
    else:
        album_id = str(client.create_album(name)["id"])
        created = True
    if stored != album_id:
        # A new (or lost) album starts empty; the previous snapshot is void.
        database.replace_album_members(kind, [], 0)
    database.set_album(kind, album_id, None)
    return album_id, created


def _chunks(ids: list[str], size: int) -> list[list[str]]:
    return [ids[index : index + size] for index in range(0, len(ids), size)]


def _apply(
    responses: list[dict[str, Any]], requested: list[str], tolerated: set[str]
) -> tuple[set[str], list[dict[str, Any]]]:
    succeeded: set[str] = set()
    failures: list[dict[str, Any]] = []
    requested_set = set(requested)
    seen: set[str] = set()
    for response in responses:
        asset_id = str(response.get("id"))
        seen.add(asset_id)
        if asset_id not in requested_set:
            failures.append({"id": asset_id, "error": "unexpected_response"})
        elif response.get("success") is True or response.get("error") in tolerated:
            succeeded.add(asset_id)
        else:
            failures.append(
                {
                    "id": asset_id,
                    "error": response.get("error"),
                    "message": response.get("errorMessage"),
                }
            )
    for asset_id in requested:
        if asset_id not in seen:
            failures.append({"id": asset_id, "error": "missing_response"})
    return succeeded, failures


def _retry(
    call: Callable[[], Any],
    *,
    sleep: Callable[[float], None],
    attempts: int = 3,
) -> Any:
    for attempt in range(attempts):
        try:
            return call()
        except ImmichError as error:
            if not error.transient or attempt + 1 == attempts:
                raise
            sleep(2**attempt)
    raise AssertionError("unreachable")


def sync_album(
    database: Database,
    client: ImmichClient,
    kind: str,
    targets: list[str],
    *,
    generation: int,
    dry_run: bool,
    reconcile: bool,
    chunk: int,
    sleep: Callable[[float], None] = time.sleep,
) -> AlbumReport:
    # Immich 3.0.3's album DTO has no asset list, and the album key may not read
    # assets, so membership is the local snapshot plus the per-asset write
    # responses. --reconcile can only compare the server's count; if they
    # diverge, delete the album in the UI and rerun so it is recreated empty.
    if not 1 <= chunk <= CHUNK_MAX:
        raise AlbumError(f"chunk must be between 1 and {CHUNK_MAX}")
    target = set(targets)
    if dry_run:
        current = set(database.album_members(kind))
        row = database.album(kind)
        return AlbumReport(
            kind=kind,
            album_id=str(row["immich_album_id"]) if row and row["immich_album_id"] else None,
            created=False,
            add=tuple(sorted(target - current)),
            remove=tuple(sorted(current - target)),
            failures=(),
            expected=len(target),
            asset_count=None,
            reconciled=True,
        )

    album_id, created = ensure_album(client, database, kind)
    current = set(database.album_members(kind))
    add = sorted(target - current)
    remove = sorted(current - target)
    failures: list[dict[str, Any]] = []
    removed: set[str] = set()
    added: set[str] = set()
    for request in _chunks(remove, chunk):
        succeeded, failed = _apply(
            _retry(
                lambda: client.remove_album_assets(album_id, request), sleep=sleep
            ),
            request,
            {"not_found"},
        )
        removed |= succeeded
        failures.extend(failed)
    for request in _chunks(add, chunk):
        succeeded, failed = _apply(
            _retry(lambda: client.add_album_assets(album_id, request), sleep=sleep),
            request,
            {"duplicate"},
        )
        added |= succeeded
        failures.extend(failed)
    actual = (current - removed) | added
    database.replace_album_members(kind, sorted(actual), generation)

    asset_count: int | None = None
    reconciled = not failures
    if reconcile:
        album = client.album(album_id)
        asset_count = int(album.get("assetCount", -1))
        if asset_count != len(actual):
            failures.append(
                {
                    "id": None,
                    "error": "count_mismatch",
                    "message": (
                        f"album reports {asset_count}, snapshot has {len(actual)}; "
                        "delete the album in Immich and rerun to recreate it"
                    ),
                }
            )
            reconciled = False
    return AlbumReport(
        kind=kind,
        album_id=album_id,
        created=created,
        add=tuple(add),
        remove=tuple(remove),
        failures=tuple(failures),
        expected=len(target),
        asset_count=asset_count,
        reconciled=reconciled,
    )


def sync_export(
    database: Database,
    client: ImmichClient | None,
    export: dict[str, Any],
    *,
    path: str | Path | None = None,
    dry_run: bool = False,
    reconcile: bool = True,
    chunk: int = 100,
    kinds: tuple[str, ...] = WRITABLE_KINDS,
    sleep: Callable[[float], None] = time.sleep,
) -> list[AlbumReport]:
    kinds = _checked_kinds(kinds)
    verify_export(database, export, path=path, kinds=kinds)
    generation = int(export["run_id"])
    if not dry_run:
        if client is None:
            raise AlbumError("a live album sync needs an Immich client")
        client.assert_album_permissions()
    reports: list[AlbumReport] = []
    for kind in kinds:
        assert client is not None or dry_run
        reports.append(
            sync_album(
                database,
                client,  # type: ignore[arg-type]
                kind,
                [str(asset_id) for asset_id in export[kind]],
                generation=generation,
                dry_run=dry_run,
                reconcile=reconcile,
                chunk=chunk,
                sleep=sleep,
            )
        )
    return reports


def _ensure_by_name(client: ImmichClient, name: str) -> tuple[str, bool]:
    matches = client.albums(name)
    if len(matches) > 1:
        raise AlbumError(f"multiple albums named {name}")
    if matches:
        return str(matches[0]["id"]), False
    return str(client.create_album(name)["id"]), True


def preflight(
    client: ImmichClient,
    *,
    probe_asset_id: str,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    """Prove the album key's exact scopes before a run spends GPU time."""
    if not probe_asset_id:
        raise AlbumError("preflight needs a probe asset id")
    client.assert_album_permissions()
    albums = {}
    for kind in ("delete", "review"):
        album_id, created = _ensure_by_name(client, ALBUM_NAMES[kind])
        albums[kind] = {"album_id": album_id, "created": created}
    review_id = albums["review"]["album_id"]
    added = _retry(
        lambda: client.add_album_assets(review_id, [probe_asset_id]), sleep=sleep
    )
    if not (len(added) == 1 and added[0].get("success") is True):
        error = added[0].get("error") if added else "missing_response"
        if error == "duplicate":
            raise AlbumError(
                "probe asset is already in triage-review; choose an asset that is "
                "not in either triage album"
            )
        raise AlbumError(f"probe add failed: {error}")
    removed = _retry(
        lambda: client.remove_album_assets(review_id, [probe_asset_id]), sleep=sleep
    )
    if not (len(removed) == 1 and removed[0].get("success") is True):
        error = removed[0].get("error") if removed else "missing_response"
        raise AlbumError(
            f"probe remove failed: {error}; {probe_asset_id} is still in "
            f"{ALBUM_NAMES['review']} and must be removed by hand"
        )
    return {"albums": albums, "probe_asset_id": probe_asset_id, "ok": True}


def album_status(database: Database) -> dict[str, Any]:
    status = {}
    for kind in ("delete", "review"):
        row = database.album(kind)
        status[kind] = {
            "album_id": row["immich_album_id"] if row else None,
            "generation": row["generation"] if row else None,
            "last_synced_at": row["last_synced_at"] if row else None,
            "members": len(database.album_members(kind)),
        }
    return status
