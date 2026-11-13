"""Unit tests for the Immich metadata collector (smores56/sdlc#592).

Covers the metadata-only endpoint allowlist (every byte path is refused before a
request exists), `nextPage`/`nextCursor` pagination, `(updatedAt, id)` cursoring,
EXIF/place/people extraction, album membership and people joins, non-JSON
refusal and API-key redaction. No Immich instance is contacted.
"""

from __future__ import annotations

import importlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

INGEST = Path(__file__).parents[1] / "modules/lib/ingest"
KEY = "immich-read-key"
UUID = "0b6c0b0a-0000-4000-8000-000000000001"


def load(name: str = "immich"):
    if str(INGEST) not in sys.path:
        sys.path.insert(0, str(INGEST))
    module = importlib.import_module(name)
    getattr(module, "_SECRETS", set()).clear()
    return module


class FakeResponse:
    def __init__(self, body: object, content_type: str = "application/json"):
        self._body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.headers = {"Content-Type": content_type}

    def read(self, size: int = -1) -> bytes:
        return self._body if size < 0 else self._body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class RouteOpener:
    def __init__(self, search, albums=None, people=None, membership=None, content_type="application/json"):
        self.search = list(search)
        self.albums = albums if albums is not None else []
        self.people = list(people or [])
        self.membership = list(membership or [])
        self.content_type = content_type
        self.requests: list[object] = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        url = request.full_url
        payload = json.loads(request.data) if request.data else {}
        if "/api/search/metadata" in url:
            queue = self.membership if "filter" in payload else self.search
            return FakeResponse(queue.pop(0), self.content_type)
        if "/api/albums" in url:
            return FakeResponse(self.albums, self.content_type)
        if "/api/people" in url:
            return FakeResponse(self.people.pop(0), self.content_type)
        raise AssertionError(f"unexpected request {url}")


def asset(asset_id=UUID, updated="2026-01-02T03:04:05.000Z", name="IMG_0001.jpg"):
    return {
        "id": asset_id,
        "type": "IMAGE",
        "originalFileName": name,
        "originalMimeType": "image/jpeg",
        "originalPath": "upload/library/owner/IMG_0001.jpg",
        "thumbhash": "1QcSHQRnh493V4dIh4eXh1h4kJUI",
        "createdAt": "2026-01-02T03:00:00.000Z",
        "updatedAt": updated,
        "localDateTime": "2026-01-02T03:00:00.000Z",
        "fileCreatedAt": "2026-01-02T03:00:00.000Z",
        "width": 4032,
        "height": 3024,
        "isFavorite": True,
        "isArchived": False,
        "isTrashed": False,
        "visibility": "timeline",
        "exifInfo": {
            "make": "FUJIFILM",
            "model": "X-T5",
            "lensModel": "XF23mmF2",
            "iso": 400,
            "fNumber": 2.0,
            "exposureTime": "1/250",
            "focalLength": 23.0,
            "latitude": 40.1,
            "longitude": -74.2,
            "city": "Princeton",
            "state": "New Jersey",
            "country": "United States",
            "dateTimeOriginal": "2026-01-02T02:59:00.000Z",
            "timeZone": "America/New_York",
        },
        "people": [{"id": "p1", "name": "Alice"}],
        "tags": [{"id": "t1", "value": "trip"}],
    }


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.immich = load()

    def test_defaults_and_strict_env(self):
        session = self.immich.session_of({"IMMICH_API_KEY": KEY})
        self.assertEqual(session["base_url"], "https://photos.sammohr.dev")
        self.assertEqual(session["page_size"], 1000)
        for env in (
            {"IMMICH_API_KEY": KEY, "IMMICH_BASE_URL": "http://photos.sammohr.dev"},
            {"IMMICH_API_KEY": KEY, "IMMICH_BASE_URL": "https://evil.test"},
            {"IMMICH_API_KEY": KEY, "IMMICH_BASE_URL": "https://photos.sammohr.dev/api"},
            {"IMMICH_API_KEY": KEY, "IMMICH_EXTRA": "1"},
            {"IMMICH_API_KEY": ""},
        ):
            with self.subTest(env=env), self.assertRaises(self.immich.ImmichError):
                self.immich.session_of(env)

    def test_page_size_bounds(self):
        with self.assertRaises(self.immich.ImmichError):
            self.immich.session_of({"IMMICH_API_KEY": KEY, "IMMICH_PAGE_SIZE": "1001"})
        with self.assertRaises(self.immich.ImmichError):
            self.immich.session_of({"IMMICH_API_KEY": KEY, "IMMICH_PAGE_SIZE": "x"})


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.immich = load()

    def test_allowed_endpoints(self):
        for path, method in (
            ("/api/search/metadata", "POST"),
            ("/api/albums", "GET"),
            (f"/api/albums/{UUID}", "GET"),
            ("/api/people?page=2&size=100&withHidden=true", "GET"),
        ):
            with self.subTest(path=path):
                self.assertEqual(self.immich.assert_endpoint(path, method), path)

    def test_byte_and_foreign_paths_are_refused(self):
        for path, method in (
            (f"/api/assets/{UUID}/original", "GET"),
            (f"/api/assets/{UUID}/thumbnail", "GET"),
            ("/api/assets", "POST"),
            ("/api/download/archive", "POST"),
            (f"/api/videos/{UUID}/playback", "GET"),
            ("/api/search/metadata?x=1", "POST"),
            ("/api/people", "POST"),
            ("/api/server/config", "GET"),
            ("/api/albums?name=x", "GET"),
            ("http://evil.test/api/albums", "GET"),
        ):
            with self.subTest(path=path), self.assertRaises(self.immich.ImmichError):
                self.immich.assert_endpoint(path, method)

    def test_client_refuses_before_dialling(self):
        opener = RouteOpener([])
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        with self.assertRaises(self.immich.ImmichError):
            client.request(f"/api/assets/{UUID}/original")
        self.assertEqual(opener.requests, [])

    def test_requests_identify_the_collector(self):
        # Cloudflare in front of Immich answers 403 to urllib's default agent, so every
        # request must carry the shared one.
        opener = RouteOpener([], albums={"items": []})
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        client.request("/api/albums")
        self.assertEqual(len(opener.requests), 1)
        headers = {k.lower(): v for k, v in opener.requests[0].header_items()}
        self.assertEqual(headers.get("user-agent"), self.immich.policy.USER_AGENT)

    def test_non_json_response_is_refused(self):
        opener = RouteOpener([], albums={"items": []}, content_type="image/jpeg")
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        with self.assertRaises(self.immich.ImmichError):
            client.request("/api/albums")

    def test_api_key_is_redacted(self):
        self.immich.register_secrets(KEY)
        self.assertNotIn(KEY, self.immich.redact_text(f"failed with {KEY}"))
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.immich.log("error", reason=f"bad key {KEY}")
        self.assertNotIn(KEY, buffer.getvalue())


class PaginationTests(unittest.TestCase):
    def setUp(self):
        self.immich = load()

    def test_next_page_tokens(self):
        opener = RouteOpener(
            [
                {"items": [asset("a"), asset("b")], "nextPage": "2"},
                {"items": [asset("c")], "nextPage": None},
            ]
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        items = self.immich.search_assets(client, after=None, page_size=2)
        self.assertEqual([item["id"] for item in items], ["a", "b", "c"])
        bodies = [json.loads(request.data) for request in opener.requests]
        self.assertEqual(bodies[0]["page"], 1)
        self.assertEqual(bodies[1]["page"], 2)
        self.assertTrue(bodies[0]["withExif"])

    def test_assets_page_wins_over_album_hits(self):
        # Immich answers with {"albums": <album hits>, "assets": <asset page>}; the
        # asset page is the one the collector wants.
        opener = RouteOpener(
            [
                {
                    "albums": {"items": [], "nextPage": None},
                    "assets": {"items": [asset("a"), asset("b")], "nextPage": None},
                }
            ]
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        items = self.immich.search_assets(client, after=None, page_size=2)
        self.assertEqual([item["id"] for item in items], ["a", "b"])

    def test_nested_search_page_is_accepted(self):
        # Immich wraps search results in `albums`, which the flat readers missed.
        opener = RouteOpener(
            [
                {"albums": {"items": [asset("a"), asset("b")], "nextPage": "2"}},
                {"albums": {"items": [asset("c")], "nextPage": None}},
            ]
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        items = self.immich.search_assets(client, after=None, page_size=2)
        self.assertEqual([item["id"] for item in items], ["a", "b", "c"])

    def test_next_cursor(self):
        opener = RouteOpener(
            [
                {"items": [asset("a")], "nextCursor": "cur"},
                {"items": [asset("b")], "nextCursor": None},
            ]
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        items = self.immich.search_assets(client, after="2025-01-01T00:00:00Z", page_size=1)
        self.assertEqual([item["id"] for item in items], ["a", "b"])
        self.assertEqual(json.loads(opener.requests[0].data)["updatedAfter"], "2025-01-01T00:00:00Z")
        self.assertEqual(json.loads(opener.requests[1].data)["cursor"], "cur")

    def test_album_membership_cursor(self):
        opener = RouteOpener(
            [],
            membership=[
                {"items": [{"id": "a"}], "nextCursor": "cur"},
                {"items": [{"id": "b"}], "nextCursor": None},
            ],
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        self.assertEqual(self.immich.album_asset_ids(client, UUID, 1), ["a", "b"])
        self.assertEqual(json.loads(opener.requests[1].data)["cursor"], "cur")

    def test_people_pagination(self):
        opener = RouteOpener(
            [],
            people=[
                {"people": [{"id": "p1", "name": "Alice"}], "hasNextPage": True},
                {"people": [{"id": "p2", "name": "Bob"}], "hasNextPage": False},
            ],
        )
        client = self.immich.ImmichClient("https://photos.sammohr.dev", KEY, opener=opener)
        people = self.immich.people(client, 100)
        self.assertEqual([person["id"] for person in people], ["p1", "p2"])
        self.assertIn("page=2", opener.requests[1].full_url)


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.immich = load()

    def test_asset_metadata_and_bytes_are_excluded(self):
        item = self.immich.asset_item(asset())
        self.assertEqual(item["type"], "immich-asset")
        self.assertEqual(item["original_file_name"], "IMG_0001.jpg")
        self.assertEqual(item["exif"]["city"], "Princeton")
        self.assertEqual(item["exif"]["model"], "X-T5")
        self.assertEqual(item["people"], ["Alice"])
        self.assertEqual(item["tags"], ["trip"])
        self.assertNotIn("thumbhash", item)
        self.assertNotIn("originalPath", item)

    def test_missing_id_is_skipped(self):
        self.assertIsNone(self.immich.asset_item({"updatedAt": "2026-01-01T00:00:00Z"}))
        self.assertIsNone(self.immich.album_item({}))
        self.assertIsNone(self.immich.person_item({}))


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.immich = load()
        self.session = self.immich.session_of({"IMMICH_API_KEY": KEY})

    def run_collect(self, opener, state, directory, now=1700000000):
        return self.immich.collect(
            self.session, state, os.path.join(directory, "outbox"), opener=opener, now=now
        )

    def payloads(self, directory):
        outbox = os.path.join(directory, "outbox")
        return [
            json.loads(Path(outbox, name).read_text(encoding="utf-8"))
            for name in sorted(os.listdir(outbox))
        ]

    def test_assets_albums_people_and_dedupe(self):
        albums_response = [
            {
                "id": "album-1",
                "albumName": "Trip",
                "description": "Summer",
                "assetCount": 1,
                "shared": False,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "updatedAt": "2026-01-03T00:00:00.000Z",
                "startDate": "2026-01-02T00:00:00.000Z",
                "endDate": "2026-01-02T00:00:00.000Z",
            }
        ]
        opener = RouteOpener(
            [{"items": [asset()], "nextPage": None}],
            albums=albums_response,
            people=[{"people": [{"id": "p1", "name": "Alice", "updatedAt": "2026-01-01T00:00:00.000Z"}], "hasNextPage": False}],
            membership=[{"items": [{"id": UUID}], "nextPage": None}],
        )
        with tempfile.TemporaryDirectory() as directory:
            state = self.immich.load_state(os.path.join(directory, "state.json"))
            summary = self.run_collect(opener, state, directory)
            self.assertEqual(summary["assets"], 1)
            self.assertEqual(summary["albums"], 2)  # album + membership item
            self.assertEqual(summary["people"], 1)
            self.assertEqual(state["assets"], {"updated_at": "2026-01-02T03:04:05.000Z", "id": UUID})
            items = [item for payload in self.payloads(directory) for item in payload["items"]]
            types = sorted(item["type"] for item in items)
            self.assertEqual(types, ["immich-album", "immich-album-assets", "immich-asset", "immich-person"])
            # Every request stayed on the metadata allowlist.
            paths = {request.full_url.split("photos.sammohr.dev")[1].split("?")[0] for request in opener.requests}
            self.assertEqual(paths, {"/api/search/metadata", "/api/albums", "/api/people"})

            # A second pass with unchanged server state emits nothing.
            opener = RouteOpener(
                [{"items": [asset()], "nextPage": None}],
                albums=albums_response,
                people=[{"people": [{"id": "p1", "name": "Alice", "updatedAt": "2026-01-01T00:00:00.000Z"}], "hasNextPage": False}],
            )
            summary = self.run_collect(opener, state, directory, now=1700000100)
            self.assertEqual((summary["assets"], summary["albums"], summary["people"]), (0, 0, 0))

    def test_removed_album_and_person(self):
        with tempfile.TemporaryDirectory() as directory:
            state = self.immich.load_state(os.path.join(directory, "state.json"))
            state["albums"] = {"gone": {"updated_at": "x"}}
            state["people"] = {"gone": {"updated_at": "x", "name": "Gone"}}
            opener = RouteOpener([{"items": [], "nextPage": None}], albums=[], people=[{"people": [], "hasNextPage": False}])
            summary = self.run_collect(opener, state, directory)
            self.assertEqual(summary["albums"], 1)
            self.assertEqual(summary["people"], 1)
            items = [item for payload in self.payloads(directory) for item in payload["items"]]
            self.assertTrue(all(item["type"] == "immich-removed" for item in items))


if __name__ == "__main__":
    unittest.main()
