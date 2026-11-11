"""Scan an Immich library into a local generation without fetching pixels."""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any, Callable

from .db import Database
from .immich import ImmichClient, ImmichError

PAGE_SIZE = 250
SUPPORTED_MAJOR = 3


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def retry(call: Callable[[], Any], sleep: Callable[[float], None], attempts: int = 3) -> Any:
    for attempt in range(attempts):
        try:
            return call()
        except ImmichError as error:
            if not error.transient or attempt == attempts - 1:
                raise
            sleep(min(2**attempt, 10))
    raise AssertionError("unreachable")


def scan_library(
    client: ImmichClient,
    database: Database,
    *,
    page_size: int = PAGE_SIZE,
    max_assets: int | None = None,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    version = retry(client.version, sleep)
    if version[0] != SUPPORTED_MAJOR:
        raise ImmichError(0, f"unsupported Immich version {version}", transient=False)
    retry(client.assert_read_permissions, sleep)

    as_of = _now()
    filters = {
        "withDeleted": False,
        "withExif": True,
        # Immich compiles withStacked=false to `asset.stackId IS NULL`, which also
        # drops stack primaries: burst frames would never be triaged. Duplicate
        # grouping and the keeper policy handle stacked members.
        "withStacked": True,
        "visibility": "timeline",
        "createdBefore": as_of,
    }
    scan_id = database.start_scan(
        {**filters, "page_size": page_size, "max_assets": max_assets},
        as_of=as_of,
    )
    try:
        page = 1
        seen = 0
        partial = False
        while True:
            page_data = retry(
                lambda: client.search_metadata(page=page, size=page_size, **filters),
                sleep,
            )
            for asset in page_data["items"]:
                database.upsert_asset(asset)
                if asset.get("type") == "IMAGE":
                    database.add_scan_asset(scan_id, str(asset["id"]), "pending", None)
                else:
                    database.add_scan_asset(scan_id, str(asset["id"]), "skipped", "type")
            seen += len(page_data["items"])
            database.commit()
            next_page = page_data.get("nextPage")
            if max_assets is not None and seen >= max_assets:
                partial = True
                break
            if not next_page:
                break
            try:
                next_int = int(next_page)
            except (TypeError, ValueError) as error:
                raise ImmichError(0, "invalid nextPage", transient=False) from error
            if next_int <= page:
                raise ImmichError(0, "pagination did not advance", transient=False)
            page = next_int
        database.import_duplicates(scan_id, retry(client.duplicates, sleep))
        database.finish_scan(scan_id, "partial" if partial else "complete")
        return scan_id
    except BaseException:
        try:
            database.finish_scan(scan_id, "failed")
        except Exception:
            pass
        raise
