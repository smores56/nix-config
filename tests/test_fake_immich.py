import json
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fake_immich import FakeImmich  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

READ_PERMISSIONS = ["asset.read", "asset.view", "album.read", "duplicate.read"]
WRITE_PERMISSIONS = ["album.read", "album.create", "albumAsset.create", "albumAsset.delete"]
KEYS = {"read-key": READ_PERMISSIONS, "write-key": WRITE_PERMISSIONS}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _request(base, method, path, data=None, key="read-key"):
    body = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(base + path, data=body, method=method)
    if key is not None:
        request.add_header("X-Api-Key", key)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with OPENER.open(request, timeout=5) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        try:
            raw = error.read()
            status = error.code
        finally:
            error.close()
    try:
        payload = json.loads(raw) if raw else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = raw
    return status, payload


class FakeImmichTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        manifest = generate_corpus(Path(cls._tmp.name))
        cls.assets = assets_for(manifest)
        cls.keep = next(asset for asset in cls.assets if asset["id"] == "asset-keep")
        cls.duplicates = [
            {
                "duplicateId": "dup-1",
                "assetIds": ["asset-duplicate-a", "asset-duplicate-b"],
                "suggestedKeepAssetIds": ["asset-duplicate-a"],
            }
        ]

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        self.immich = FakeImmich(
            assets=self.assets,
            duplicates=self.duplicates,
            keys=KEYS,
            api_key="read-key",
        )
        self.immich.start()

    def tearDown(self):
        self.immich.stop()

    def test_version_is_public_and_keys_need_auth(self):
        status, payload = _request(
            self.immich.base_url, "GET", "/api/server/version", key=None
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"major": 3, "minor": 0, "patch": 3})
        self.assertEqual(
            _request(self.immich.base_url, "GET", "/api/api-keys/me", key=None)[0], 401
        )
        status, payload = _request(self.immich.base_url, "GET", "/api/api-keys/me")
        self.assertEqual(status, 200)
        self.assertEqual(payload["permissions"], READ_PERMISSIONS)

    def test_read_and_write_keys_are_separated(self):
        self.assertEqual(
            _request(
                self.immich.base_url, "POST", "/api/albums", {"albumName": "a"}, key="read-key"
            )[0],
            403,
        )
        self.assertEqual(
            _request(
                self.immich.base_url,
                "GET",
                "/api/assets/asset-keep/thumbnail",
                key="write-key",
            )[0],
            403,
        )
        status, album = _request(
            self.immich.base_url,
            "POST",
            "/api/albums",
            {"albumName": "triage-delete"},
            key="write-key",
        )
        self.assertEqual(status, 201)
        self.assertEqual(album["assetCount"], 0)

    def test_search_paginates_and_filters(self):
        status, payload = _request(
            self.immich.base_url, "POST", "/api/search/metadata", {"page": 1, "size": 3}
        )
        self.assertEqual(status, 200)
        # 3.0.3 reports the page length as total, not the library size.
        self.assertEqual(payload["assets"]["total"], 3)
        self.assertEqual(payload["assets"]["count"], 3)
        self.assertEqual(payload["assets"]["nextPage"], "2")
        total = len(self.assets)
        size = 3
        last_page = (total + size - 1) // size
        _, last = _request(
            self.immich.base_url,
            "POST",
            "/api/search/metadata",
            {"page": last_page, "size": size},
        )
        self.assertEqual(last["assets"]["count"], total - (last_page - 1) * size)
        self.assertIsNone(last["assets"]["nextPage"])

    def test_search_visibility_and_deleted_filters(self):
        hidden = dict(self.keep)
        hidden["id"] = "asset-hidden"
        hidden["visibility"] = "hidden"
        archived = dict(self.keep)
        archived["id"] = "asset-archived"
        archived["visibility"] = "archive"
        archived["isArchived"] = True
        trashed = dict(self.keep)
        trashed["id"] = "asset-trashed"
        trashed["isTrashed"] = True
        with FakeImmich(
            assets=self.assets + [hidden, archived, trashed], keys=KEYS, api_key="read-key"
        ) as immich:
            _, default = _request(
                immich.base_url, "POST", "/api/search/metadata", {"page": 1, "size": 100}
            )
            _, timeline = _request(
                immich.base_url,
                "POST",
                "/api/search/metadata",
                {"page": 1, "size": 100, "visibility": "timeline"},
            )
            _, timeline_deleted = _request(
                immich.base_url,
                "POST",
                "/api/search/metadata",
                {"page": 1, "size": 100, "visibility": "timeline", "withDeleted": True},
            )
        self.assertEqual(default["assets"]["count"], len(self.assets) + 2)
        self.assertEqual(timeline["assets"]["count"], len(self.assets))
        self.assertEqual(timeline_deleted["assets"]["count"], len(self.assets) + 1)

    def test_thumbnail_and_missing_preview(self):
        status, payload = _request(
            self.immich.base_url, "GET", "/api/assets/asset-keep/thumbnail?size=preview"
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload, self.keep["preview"])
        missing = dict(self.keep)
        missing["id"] = "asset-no-preview"
        missing["preview"] = None
        with FakeImmich(assets=self.assets + [missing], keys=KEYS, api_key="read-key") as immich:
            self.assertEqual(
                _request(
                    immich.base_url, "GET", "/api/assets/asset-no-preview/thumbnail"
                )[0],
                404,
            )

    def test_original_requires_download_permission(self):
        self.assertEqual(
            _request(self.immich.base_url, "GET", "/api/assets/asset-keep/original")[0], 403
        )

    def test_duplicates_include_a_suggested_keep(self):
        status, payload = _request(self.immich.base_url, "GET", "/api/duplicates")
        self.assertEqual(status, 200)
        self.assertEqual(payload[0]["suggestedKeepAssetIds"], ["asset-duplicate-a"])

    def test_asset_checksum_is_base64_sha1(self):
        import base64
        import hashlib

        self.assertEqual(
            self.keep["checksum"],
            base64.b64encode(hashlib.sha1(self.keep["preview"]).digest()).decode(),
        )

    def test_seeded_album_and_album_read(self):
        seeded = [
            {"id": "album-seeded", "albumName": "triage-review", "assetIds": ["asset-keep"]}
        ]
        with FakeImmich(
            assets=self.assets, albums=seeded, keys=KEYS, api_key="read-key"
        ) as immich:
            status, albums = _request(immich.base_url, "GET", "/api/albums")
            self.assertEqual(status, 200)
            self.assertEqual(albums[0]["id"], "album-seeded")
            self.assertEqual(albums[0]["assetCount"], 1)
            status, album = _request(immich.base_url, "GET", "/api/albums/album-seeded")
            self.assertEqual(status, 200)
            self.assertEqual(album["assetCount"], 1)
            self.assertNotIn("assets", album)
            self.assertEqual(
                _request(immich.base_url, "GET", "/api/albums/missing")[0], 400
            )

    def test_query_key_is_accepted(self):
        status, _ = _request(
            self.immich.base_url,
            "GET",
            "/api/assets/asset-keep/thumbnail?size=preview&key=read-key",
            key=None,
        )
        self.assertEqual(status, 200)

    def test_album_lifecycle_and_partial_failure(self):
        status, album = _request(
            self.immich.base_url,
            "POST",
            "/api/albums",
            {"albumName": "triage-delete"},
            key="write-key",
        )
        self.assertEqual(status, 201)
        album_id = album["id"]
        status, results = _request(
            self.immich.base_url,
            "PUT",
            f"/api/albums/{album_id}/assets",
            {"ids": ["asset-keep", "asset-blur"]},
            key="write-key",
        )
        self.assertEqual(status, 200)
        self.assertTrue(all(result["success"] for result in results))
        self.immich.set_fail_add({"asset-dark"})
        _, results = _request(
            self.immich.base_url,
            "PUT",
            f"/api/albums/{album_id}/assets",
            {"ids": ["asset-dark"]},
            key="write-key",
        )
        self.assertFalse(results[0]["success"])
        self.assertEqual(results[0]["error"], "no_permission")
        _, results = _request(
            self.immich.base_url,
            "DELETE",
            f"/api/albums/{album_id}/assets",
            {"ids": ["asset-keep"]},
            key="write-key",
        )
        self.assertTrue(results[0]["success"])
        self.assertEqual(self.immich.album_asset_ids(album_id), ["asset-blur"])

    def test_failure_injection_is_scoped(self):
        self.immich.queue_failure(503, method="POST", path_prefix="/api/search/metadata")
        self.assertEqual(
            _request(self.immich.base_url, "GET", "/api/server/version", key=None)[0], 200
        )
        self.assertEqual(
            _request(self.immich.base_url, "POST", "/api/search/metadata", {"page": 1})[0], 503
        )
        self.assertEqual(
            _request(self.immich.base_url, "POST", "/api/search/metadata", {"page": 1})[0], 200
        )

    def test_invalid_pagination_is_a_400(self):
        self.assertEqual(
            _request(
                self.immich.base_url, "POST", "/api/search/metadata", {"page": "1"}
            )[0],
            400,
        )

    def test_requests_are_recorded(self):
        _request(self.immich.base_url, "GET", "/api/assets/asset-keep/thumbnail?size=preview")
        record = self.immich.requests[-1]
        self.assertEqual((record.method, record.path), ("GET", "/api/assets/asset-keep/thumbnail"))
        self.assertEqual(record.query["size"], ["preview"])


if __name__ == "__main__":
    unittest.main()
