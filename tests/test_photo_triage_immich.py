import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fake_immich import FakeImmich  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.immich import (  # noqa: E402
    READ_PERMISSIONS,
    ImmichClient,
    ImmichError,
    ImmichPermissionError,
)


class ImmichClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._corpus = tempfile.TemporaryDirectory()
        manifest = generate_corpus(Path(cls._corpus.name))
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
        cls._corpus.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.socket_path = str(Path(self._tmp.name, "immich.sock"))
        self.fake = FakeImmich(
            assets=self.assets,
            duplicates=self.duplicates,
            keys={"read-key": sorted(READ_PERMISSIONS)},
            api_key="read-key",
            unix_path=self.socket_path,
        )
        self.fake.start()
        self.client = ImmichClient(socket_path=self.socket_path, api_key="read-key")

    def tearDown(self):
        self.fake.stop()
        self._tmp.cleanup()

    def test_version(self):
        self.assertEqual(self.client.version(), (3, 0, 3))

    def test_permissions_are_exact(self):
        self.assertEqual(set(self.client.permissions()), set(READ_PERMISSIONS))
        self.client.assert_read_permissions()

    def test_permission_mismatch_fails_closed(self):
        self.fake.keys["read-key"].append("asset.download")
        with self.assertRaises(ImmichPermissionError) as raised:
            self.client.assert_read_permissions()
        self.assertIn("asset.download", raised.exception.message)

    def test_search_paginates(self):
        first = self.client.search_metadata(page=1, size=3)
        self.assertEqual(len(first["items"]), 3)
        self.assertEqual(first["nextPage"], "2")
        last = self.client.search_metadata(page=4, size=3)
        self.assertEqual(last["count"], len(self.assets) - 9)
        self.assertIsNone(last["nextPage"])

    def test_thumbnail_returns_bytes(self):
        self.assertEqual(self.client.thumbnail("asset-keep"), self.keep["preview"])

    def test_duplicates_include_the_suggested_keep(self):
        groups = self.client.duplicates()
        self.assertEqual(groups[0]["suggestedKeepAssetIds"], ["asset-duplicate-a"])

    def test_asset_metadata(self):
        asset = self.client.asset("asset-keep")
        self.assertEqual(asset["id"], "asset-keep")
        self.assertEqual(asset["checksum"], self.keep["checksum"])

    def test_transient_errors_are_marked(self):
        self.fake.queue_failure(503, method="POST", path_prefix="/api/search/metadata")
        with self.assertRaises(ImmichError) as raised:
            self.client.search_metadata()
        self.assertTrue(raised.exception.transient)
        self.assertEqual(raised.exception.status, 503)

    def test_auth_errors_are_permanent(self):
        client = ImmichClient(socket_path=self.socket_path, api_key="wrong-key")
        with self.assertRaises(ImmichError) as raised:
            client.permissions()
        self.assertEqual(raised.exception.status, 401)
        self.assertFalse(raised.exception.transient)


if __name__ == "__main__":
    unittest.main()
