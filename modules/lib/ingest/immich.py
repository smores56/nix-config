"""Immich metadata collector for the `ingest-immich` guest (smores56/sdlc#592).

Reads asset metadata, EXIF, places, people and album membership from Immich's
JSON API and writes NDJSON batches for `ingest-emit`. No image bytes are ever
requested: the client has a three-endpoint allowlist (`/api/search/metadata`,
`/api/albums`, `/api/people`) and refuses every `/original`, `/thumbnail`,
`/download`, `/video` or generic `/api/assets` path before a socket is opened.
Responses must be JSON and are size-capped.

Pagination follows `nextPage` (v1/v2) or `nextCursor` (v3) while present, and
the persisted cursor is the `(updatedAt, id)` pair, so a restart re-reads one
boundary page and dedupes instead of replaying the library. The key is a scoped
read-only Immich API key (`asset.read`, `album.read`, `person.read`) read from
the read-only secret device; it is never logged.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

import policy

SOURCE = "immich"
STATE_VERSION = 1
PROTOCOL_VERSION = 1
BASE_HOST = "photos.sammohr.dev"
BASE_URL = f"https://{BASE_HOST}"
ENV_KEYS = {"IMMICH_BASE_URL", "IMMICH_API_KEY", "IMMICH_PAGE_SIZE"}
DEFAULT_PAGE_SIZE = 1000
MAX_PAGE_SIZE = 1000
MAX_PAGES = 1000
MAX_RESPONSE_BYTES = 16 << 20
MAX_ITEMS_PER_BATCH = 200
MAX_BATCH_BYTES = 350_000
MAX_TEXT = 500
ALLOWED_EXACT = {"/api/search/metadata", "/api/albums", "/api/people"}
ALLOWED_ALBUM = re.compile(r"^/api/albums/[0-9a-fA-F-]{36}$")
BYTE_WORDS = ("original", "thumbnail", "download", "video", "playback", "file", "asset")
EXIF_FIELDS = (
    "make",
    "model",
    "lensModel",
    "iso",
    "fNumber",
    "exposureTime",
    "focalLength",
    "latitude",
    "longitude",
    "city",
    "state",
    "country",
    "dateTimeOriginal",
    "timeZone",
    "rating",
)
_SECRETS: set[str] = set()


class ImmichError(RuntimeError):
    """A refused secret, endpoint, response or state file."""


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-immich", "event": event}
    record.update(fields)
    print(redact_text(json.dumps(record, sort_keys=True)), flush=True)


def register_secrets(*values: str) -> None:
    for value in values:
        if value:
            _SECRETS.add(value)


def redact_text(text: str) -> str:
    out = str(text)
    for secret in sorted(_SECRETS, key=len, reverse=True):
        out = out.replace(secret, "[redacted]")
    return out


def safe_text(value: object, limit: int = MAX_TEXT) -> str:
    text = "".join(ch if ch.isprintable() else " " for ch in str(value or ""))
    return re.sub(r"\s+", " ", text).strip()[:limit]


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ImmichError(f"secret line {number} is not a contract KEY=value")
        if key not in ENV_KEYS:
            raise ImmichError(f"unknown secret key {key}")
        if key in values:
            raise ImmichError(f"secret key {key} appears twice")
        if value[:1] == value[-1:] and value[:1] in ("'", '"') and len(value) >= 2:
            value = value[1:-1]
        values[key] = value
    return values


def validate_base_url(url: str) -> str:
    if not url:
        raise ImmichError("IMMICH_BASE_URL is missing")
    try:
        parts = urllib_parse.urlsplit(url)
    except ValueError:
        raise ImmichError("IMMICH_BASE_URL is not a URL") from None
    if parts.scheme != "https":
        raise ImmichError("IMMICH_BASE_URL must be HTTPS")
    if parts.hostname != BASE_HOST:
        raise ImmichError(f"IMMICH_BASE_URL host must be {BASE_HOST}")
    if parts.port not in (None, 443) or parts.username or parts.password or parts.query or parts.fragment:
        raise ImmichError("IMMICH_BASE_URL must be the bare service origin")
    if parts.path not in ("", "/"):
        raise ImmichError("IMMICH_BASE_URL must not carry a path")
    return BASE_URL


def session_of(env: dict[str, str]) -> dict:
    unknown = set(env) - ENV_KEYS
    if unknown:
        raise ImmichError(f"unknown secret keys: {sorted(unknown)}")
    api_key = env.get("IMMICH_API_KEY", "")
    if not api_key or len(api_key) > 500 or not re.fullmatch(r"[A-Za-z0-9._-]+", api_key):
        raise ImmichError("IMMICH_API_KEY is missing or malformed")
    register_secrets(api_key)
    page_size = DEFAULT_PAGE_SIZE
    if env.get("IMMICH_PAGE_SIZE"):
        try:
            page_size = int(env["IMMICH_PAGE_SIZE"])
        except ValueError:
            raise ImmichError("IMMICH_PAGE_SIZE is not an integer") from None
        if not 1 <= page_size <= MAX_PAGE_SIZE:
            raise ImmichError(f"IMMICH_PAGE_SIZE must be 1..{MAX_PAGE_SIZE}")
    return {
        "base_url": validate_base_url(env.get("IMMICH_BASE_URL") or BASE_URL),
        "api_key": api_key,
        "page_size": page_size,
    }


def assert_endpoint(path: str, method: str = "GET") -> str:
    """Refuse every path outside the metadata endpoints; bytes never cross the tap."""
    if not isinstance(path, str) or not path.startswith("/api/"):
        raise ImmichError("Immich endpoint is not an /api path")
    base, _, query = path.partition("?")
    if "#" in query:
        raise ImmichError("Immich endpoint must not carry a fragment")
    if base == "/api/people":
        if method != "GET":
            raise ImmichError("/api/people is GET only")
        allowed_query = {"page", "size", "withHidden"}
        for part in filter(None, query.split("&")):
            key, _, value = part.partition("=")
            if key not in allowed_query or not re.fullmatch(r"[0-9a-zA-Z]+", value):
                raise ImmichError(f"/api/people query parameter refused: {key}")
        return path
    if query:
        raise ImmichError("Immich endpoint must not carry a query")
    if base in ALLOWED_EXACT:
        if base == "/api/search/metadata" and method != "POST":
            raise ImmichError("search/metadata is POST only")
        if base != "/api/search/metadata" and method != "GET":
            raise ImmichError(f"{base} is GET only")
        return base
    if ALLOWED_ALBUM.match(base) and method == "GET":
        return base
    lowered = base.lower()
    if any(word in lowered for word in BYTE_WORDS) or lowered.startswith("/api/assets"):
        raise ImmichError(f"byte endpoint refused: {path}")
    raise ImmichError(f"endpoint is outside the metadata allowlist: {path}")


class ImmichClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        opener: urllib_request.OpenerDirector | None = None,
        timeout: float = 60.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.open_url = (opener or urllib_request.build_opener()).open
        self.timeout = timeout

    def request(self, path: str, payload: dict | None = None, method: str = "GET") -> object:
        """Return the decoded JSON (object or array); never image bytes."""
        allowed = assert_endpoint(path, method)
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {
            "Accept": "application/json",
            "User-Agent": policy.USER_AGENT,
            "x-api-key": self.api_key,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib_request.Request(self.base_url + allowed, data=body, headers=headers, method=method)
        try:
            with self.open_url(request, timeout=self.timeout) as response:
                content_type = response.headers.get("Content-Type", "")
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib_error.HTTPError as exc:
            if exc.code in (401, 403):
                raise ImmichError(f"Immich refused the API key ({exc.code})") from None
            raise ImmichError(f"Immich returned HTTP {exc.code} for {allowed}") from None
        except (urllib_error.URLError, OSError, ValueError) as exc:
            raise ImmichError(f"Immich request failed: {exc}") from None
        except http.client.HTTPException as exc:
            # A truncated chunked body (IncompleteRead, RemoteDisconnected) is an
            # HTTPException, not an OSError, so it escaped as a bare traceback and
            # skipped both the state write and the `error` event.
            raise ImmichError(f"Immich request failed: {exc}") from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ImmichError("Immich response exceeds the size cap")
        if "application/json" not in content_type.lower():
            raise ImmichError(f"Immich returned non-JSON content for {allowed}")
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ImmichError("Immich response is not JSON") from None
        if not isinstance(document, (dict, list)):
            raise ImmichError("Immich response is neither an object nor a list")
        return document


def iso_cursor(value: object) -> str:
    return safe_text(value, 64)


def cursor_after(updated_at: str, item_id: str, cursor: dict) -> bool:
    key = (updated_at or "", item_id or "")
    stored = (str(cursor.get("updated_at") or ""), str(cursor.get("id") or ""))
    return key > stored


def search_page(document: dict) -> dict:
    """Return the page object of a search/metadata response.

    Immich answers with two page objects: `assets` holds the assets that matched
    (also for the album-membership search) and `albums` holds album hits, which
    are empty for an asset query. Older builds wrapped the assets in `albums`
    under the same `items`/`nextPage` shape, and some answered at the top level,
    so try each in turn.
    """
    for key in ("assets", "albums"):
        inner = document.get(key)
        if isinstance(inner, dict):
            return inner
    return document


def asset_pages(client: ImmichClient, *, after: str | None, page_size: int):
    """Yield one page of raw assets at a time.

    Streaming matters at this size: the guest holds 256 MiB and the collector runs
    under a 112 MiB cgroup cap, so materialising a whole library before batching is
    what got the unit killed instead of reporting anything.
    """
    body: dict = {
        "size": page_size,
        "withExif": True,
        "withPeople": True,
        "order": "asc",
    }
    if after:
        body["updatedAfter"] = after
    page = 1
    cursor: str | None = None
    for _ in range(MAX_PAGES):
        request_body = dict(body)
        if cursor:
            request_body["cursor"] = cursor
        else:
            request_body["page"] = page
        document = client.request("/api/search/metadata", request_body, method="POST")
        if not isinstance(document, dict):
            raise ImmichError("search/metadata response is not an object")
        page_document = search_page(document)
        page_items = page_document.get("items")
        if not isinstance(page_items, list):
            raise ImmichError("search/metadata response has no items list")
        log("page", page=page, items=len(page_items), next=page_document.get("nextPage"))
        yield [raw for raw in page_items if isinstance(raw, dict)]
        # An empty page is the end regardless of the token: Immich keeps returning a
        # nextPage past the last asset, and following it walked MAX_PAGES pages.
        if not page_items:
            break
        next_cursor = page_document.get("nextCursor")
        if isinstance(next_cursor, str) and next_cursor:
            cursor = next_cursor
            continue
        next_page = page_document.get("nextPage")
        if isinstance(next_page, str) and next_page:
            page = int(next_page) if next_page.isdigit() else page + 1
            continue
        if "nextPage" in page_document or "nextCursor" in page_document:
            break
        if len(page_items) < page_size:
            break
        page += 1


def search_assets(client: ImmichClient, *, after: str | None, page_size: int) -> list[dict]:
    return [raw for page in asset_pages(client, after=after, page_size=page_size) for raw in page]


def albums(client: ImmichClient) -> list[dict]:
    document = client.request("/api/albums")
    entries = document if isinstance(document, list) else document.get("items") if isinstance(document, dict) else None
    if not isinstance(entries, list):
        raise ImmichError("albums response is not a list")
    return [raw for raw in entries if isinstance(raw, dict)]


def people(client: ImmichClient, page_size: int) -> list[dict]:
    items: list[dict] = []
    page = 1
    for _ in range(MAX_PAGES):
        document = client.request(f"/api/people?page={page}&size={page_size}&withHidden=true")
        if not isinstance(document, dict):
            raise ImmichError("people response is not an object")
        entries = document.get("people")
        if not isinstance(entries, list):
            raise ImmichError("people response has no people list")
        items.extend(raw for raw in entries if isinstance(raw, dict))
        if not document.get("hasNextPage"):
            break
        page += 1
    return items


def album_asset_ids(client: ImmichClient, album_id: str, page_size: int) -> list[str]:
    body = {
        "size": page_size,
        "withExif": False,
        "withPeople": False,
        "filter": {"albumIds": {"ids": [album_id]}},
    }
    ids: list[str] = []
    seen: set[str] = set()
    page = 1
    cursor: str | None = None
    for _ in range(MAX_PAGES):
        request_body = dict(body)
        if cursor:
            request_body["cursor"] = cursor
        else:
            request_body["page"] = page
        document = client.request("/api/search/metadata", request_body, method="POST")
        if not isinstance(document, dict):
            raise ImmichError("search/metadata album response is not an object")
        page_document = search_page(document)
        entries = page_document.get("items")
        if not isinstance(entries, list):
            raise ImmichError("search/metadata album response has no items list")
        for raw in entries:
            if isinstance(raw, dict) and raw.get("id") and str(raw["id"]) not in seen:
                seen.add(str(raw["id"]))
                ids.append(str(raw["id"]))
        next_cursor = page_document.get("nextCursor")
        if isinstance(next_cursor, str) and next_cursor:
            cursor = next_cursor
            continue
        next_page = page_document.get("nextPage")
        if isinstance(next_page, str) and next_page:
            page = int(next_page) if next_page.isdigit() else page + 1
            continue
        if "nextPage" in document or "nextCursor" in document:
            break
        if len(entries) < page_size:
            break
        page += 1
    return ids


def asset_item(raw: dict) -> dict | None:
    asset_id = safe_text(raw.get("id"), 64)
    if not asset_id:
        return None
    exif = raw.get("exifInfo") if isinstance(raw.get("exifInfo"), dict) else {}
    exif_values = {key: exif[key] for key in EXIF_FIELDS if exif.get(key) is not None}
    people_names = sorted(
        {
            safe_text(person.get("name"), 200)
            for person in raw.get("people") or []
            if isinstance(person, dict) and safe_text(person.get("name"), 200)
        }
    )
    tags = sorted(
        {
            safe_text(tag.get("value") or tag.get("name"), 200)
            for tag in raw.get("tags") or []
            if isinstance(tag, dict) and (tag.get("value") or tag.get("name"))
        }
    )
    stack = raw.get("stack") if isinstance(raw.get("stack"), dict) else {}
    return {
        "type": "immich-asset",
        "id": asset_id,
        "kind": safe_text(raw.get("type"), 32),
        "original_file_name": safe_text(raw.get("originalFileName"), 300),
        "mime_type": safe_text(raw.get("originalMimeType"), 100),
        "taken_at": safe_text(exif.get("dateTimeOriginal") or raw.get("localDateTime") or raw.get("fileCreatedAt"), 64),
        "created_at": safe_text(raw.get("createdAt"), 64),
        "updated_at": safe_text(raw.get("updatedAt"), 64),
        "width": raw.get("width"),
        "height": raw.get("height"),
        "duration_ms": raw.get("duration"),
        "is_favorite": bool(raw.get("isFavorite")),
        "is_archived": bool(raw.get("isArchived")),
        "is_trashed": bool(raw.get("isTrashed")),
        "visibility": safe_text(raw.get("visibility"), 32),
        "duplicate_id": safe_text(raw.get("duplicateId"), 64) or None,
        "live_photo_video_id": safe_text(raw.get("livePhotoVideoId"), 64) or None,
        "stack_id": safe_text(stack.get("id"), 64) or None,
        "people": people_names,
        "tags": tags,
        "exif": exif_values,
    }


def album_item(raw: dict) -> dict | None:
    album_id = safe_text(raw.get("id"), 64)
    if not album_id:
        return None
    return {
        "type": "immich-album",
        "id": album_id,
        "name": safe_text(raw.get("albumName"), 300),
        "description": safe_text(raw.get("description"), 1000),
        "asset_count": raw.get("assetCount"),
        "shared": bool(raw.get("shared")),
        "created_at": safe_text(raw.get("createdAt"), 64),
        "updated_at": safe_text(raw.get("updatedAt"), 64),
        "start_date": safe_text(raw.get("startDate"), 64) or None,
        "end_date": safe_text(raw.get("endDate"), 64) or None,
    }


def person_item(raw: dict) -> dict | None:
    person_id = safe_text(raw.get("id"), 64)
    if not person_id:
        return None
    return {
        "type": "immich-person",
        "id": person_id,
        "name": safe_text(raw.get("name"), 300),
        "birth_date": safe_text(raw.get("birthDate"), 32) or None,
        "is_hidden": bool(raw.get("isHidden")),
        "is_favorite": bool(raw.get("isFavorite")),
        "updated_at": safe_text(raw.get("updatedAt"), 64),
    }


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {
            "version": STATE_VERSION,
            "seq": 0,
            "assets": {"updated_at": "", "id": ""},
            "albums": {},
            "people": {},
            "known": {"albums": [], "people": []},
        }
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ImmichError(f"state file {path} is not JSON") from None
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise ImmichError(f"state file {path} has an unsupported version")
    state.setdefault("seq", 0)
    state.setdefault("assets", {"updated_at": "", "id": ""})
    state.setdefault("albums", {})
    state.setdefault("people", {})
    state.setdefault("known", {"albums": [], "people": []})
    return state


def write_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".immich-state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def chunk(items: list[dict], max_items: int = MAX_ITEMS_PER_BATCH, max_bytes: int = MAX_BATCH_BYTES):
    batch: list[dict] = []
    size = 2
    for item in items:
        encoded = len(json.dumps(item, sort_keys=True).encode("utf-8")) + 2
        if batch and (len(batch) >= max_items or size + encoded > max_bytes):
            yield batch
            batch = []
            size = 2
        batch.append(item)
        size += encoded
    if batch:
        yield batch


def write_batch(outbox: str, state: dict, items: list[dict]) -> str:
    seq = int(state.get("seq", 0)) + 1
    envelope = {
        "v": PROTOCOL_VERSION,
        "source": SOURCE,
        "kind": "batch",
        "seq": seq,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": items,
    }
    payload = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode("utf-8")
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    name = f"{seq:06d}-batch-{int(time.time())}.json"
    fd, temporary = tempfile.mkstemp(dir=outbox, prefix=".batch-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(outbox, name))
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    state["seq"] = seq
    return name


def collect(
    session: dict,
    state: dict,
    outbox: str,
    *,
    opener: urllib_request.OpenerDirector | None = None,
    now: int | None = None,
) -> dict:
    now = int(now if now is not None else time.time())
    client = ImmichClient(session["base_url"], session["api_key"], opener=opener)
    page_size = int(session.get("page_size") or DEFAULT_PAGE_SIZE)
    cursor = dict(state.get("assets") or {})
    after = cursor.get("updated_at") or None
    # Immich orders search results by capture time, so the page stream is not sorted
    # by updatedAt. A cursor advanced mid-pass therefore dropped every asset that
    # sorted before the page-1 maximum (1,000 of 17,559 on the real library), so the
    # stored cursor is only trusted once a whole pass has completed.
    incremental = bool(state.get("synced_at"))

    items: list[dict] = []
    emitted_assets = 0
    skipped_assets = 0
    batches = 0
    # Assets are the only unbounded source, so they are batched page by page: keep
    # at most one page plus one partial batch in memory.
    for page in asset_pages(client, after=after, page_size=page_size):
        for raw in sorted(page, key=lambda raw: (str(raw.get("updatedAt") or ""), str(raw.get("id") or ""))):
            item = asset_item(raw)
            if item is None:
                skipped_assets += 1
                continue
            if incremental and not cursor_after(item["updated_at"], item["id"], cursor):
                skipped_assets += 1
                continue
            items.append(item)
            emitted_assets += 1
            if (item["updated_at"], item["id"]) > (cursor.get("updated_at", ""), cursor.get("id", "")):
                cursor = {"updated_at": item["updated_at"], "id": item["id"]}
        state["assets"] = cursor
        if len(items) >= MAX_ITEMS_PER_BATCH:
            for batch in chunk(items):
                write_batch(outbox, state, batch)
                batches += 1
            items = []

    album_state = state.setdefault("albums", {})
    album_items: list[dict] = []
    current_albums: list[str] = []
    for raw in albums(client):
        item = album_item(raw)
        if item is None:
            continue
        current_albums.append(item["id"])
        stored = album_state.get(item["id"], {})
        if stored.get("updated_at") == item["updated_at"]:
            continue
        members = album_asset_ids(client, item["id"], page_size)
        album_items.append(item)
        for start in range(0, len(members), 500):
            album_items.append(
                {
                    "type": "immich-album-assets",
                    "album_id": item["id"],
                    "asset_ids": members[start : start + 500],
                }
            )
        album_state[item["id"]] = {"updated_at": item["updated_at"], "asset_count": item.get("asset_count")}
    for removed in sorted(set(album_state) - set(current_albums)):
        album_items.append({"type": "immich-removed", "kind": "album", "id": removed})
        album_state.pop(removed, None)

    person_state = state.setdefault("people", {})
    person_items: list[dict] = []
    current_people: list[str] = []
    for raw in people(client, page_size):
        item = person_item(raw)
        if item is None:
            continue
        current_people.append(item["id"])
        stored = person_state.get(item["id"], {})
        if stored.get("updated_at") == item["updated_at"] and stored.get("name") == item["name"]:
            continue
        person_items.append(item)
        person_state[item["id"]] = {"updated_at": item["updated_at"], "name": item["name"]}
    for removed in sorted(set(person_state) - set(current_people)):
        person_items.append({"type": "immich-removed", "kind": "person", "id": removed})
        person_state.pop(removed, None)

    items.extend(album_items)
    items.extend(person_items)
    for batch in chunk(items):
        write_batch(outbox, state, batch)
        batches += 1
    state["synced_at"] = now
    log(
        "done",
        assets=emitted_assets,
        skipped=skipped_assets,
        albums=len(album_items),
        people=len(person_items),
        batches=batches,
        host=BASE_HOST,
    )
    return {
        "assets": emitted_assets,
        "albums": len(album_items),
        "people": len(person_items),
        "batches": batches,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-immich")
    parser.add_argument("--env", default="/run/ingest-secret/env")
    parser.add_argument("--outbox", default="/var/lib/ingest/outbox")
    parser.add_argument("--state", default="/var/lib/immich/state.json")
    args = parser.parse_args(argv)
    try:
        with open(args.env, encoding="utf-8") as handle:
            session = session_of(parse_env(handle.read()))
        state = load_state(args.state)
        summary = collect(session, state, args.outbox)
        write_state(args.state, state)
        log("done", **summary)
        return 0
    except (OSError, ImmichError) as exc:
        log("error", reason=str(exc))
        return 65


if __name__ == "__main__":
    sys.exit(main())
