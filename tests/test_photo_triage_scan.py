import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fake_immich import FakeImmich  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import READ_PERMISSIONS, ImmichClient, ImmichError  # noqa: E402
from photo_triage.scan import scan_library  # noqa: E402


class ScanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._corpus = tempfile.TemporaryDirectory()
        manifest = generate_corpus(Path(cls._corpus.name))
        cls.images = assets_for(manifest)
        video = dict(cls.images[0])
        video["id"] = "asset-video"
        video["type"] = "VIDEO"
        video["originalFileName"] = "clip.mp4"
        archived = dict(cls.images[1])
        archived["id"] = "asset-archived"
        archived["visibility"] = "archive"
        archived["isArchived"] = True
        cls.assets = cls.images + [video, archived]
        cls.scanned = len(cls.images) + 1
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
        self.database = Database(Path(self._tmp.name, "triage.db"))

    def tearDown(self):
        self.database.close()
        self.fake.stop()
        self._tmp.cleanup()

    def test_scan_builds_a_complete_generation(self):
        scan_id = scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        self.assertEqual(self.database.scan_state(scan_id), "complete")
        coverage = self.database.coverage(scan_id)
        self.assertEqual(coverage["state"], "complete")
        self.assertEqual(coverage["total"], self.scanned)
        self.assertEqual(coverage["states"]["pending"], len(self.images))
        self.assertEqual(coverage["reasons"]["type"], 1)
        self.assertEqual(self.database.duplicates_summary(scan_id), {"groups": 1, "members": 2})
        self.assertEqual(self.database.latest_scan(), scan_id)

    def test_archived_assets_are_not_scanned(self):
        scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        ids = {
            row["id"]
            for row in self.database.connection.execute("SELECT id FROM assets").fetchall()
        }
        self.assertNotIn("asset-archived", ids)

    def test_generations_are_separate(self):
        first = scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        second = scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        self.assertGreater(second, first)
        self.assertEqual(self.database.coverage(first)["total"], self.scanned)
        self.assertEqual(self.database.coverage(second)["total"], self.scanned)

    def test_max_assets_marks_the_generation_partial(self):
        scan_id = scan_library(
            self.client, self.database, page_size=3, max_assets=2, sleep=lambda _: None
        )
        self.assertEqual(self.database.scan_state(scan_id), "partial")
        self.assertLess(self.database.coverage(scan_id)["total"], self.scanned)

    def test_requeue_reopens_skipped_assets(self):
        scan_id = scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        self.assertEqual(self.database.requeue(scan_id, "type"), 1)
        coverage = self.database.coverage(scan_id)
        self.assertEqual(coverage["reasons"], {})
        self.assertEqual(coverage["states"]["pending"], self.scanned)

    def test_transient_failure_is_retried(self):
        self.fake.queue_failure(503, method="POST", path_prefix="/api/search/metadata")
        scan_id = scan_library(self.client, self.database, page_size=3, sleep=lambda _: None)
        self.assertEqual(self.database.scan_state(scan_id), "complete")
        self.assertEqual(self.database.coverage(scan_id)["total"], self.scanned)

    def test_permission_failure_aborts_before_a_scan(self):
        client = ImmichClient(socket_path=self.socket_path, api_key="wrong-key")
        with self.assertRaises(ImmichError):
            scan_library(client, self.database, sleep=lambda _: None)
        self.assertIsNone(self.database.latest_scan())

    def test_cli_scan_and_coverage(self):
        credentials = Path(self._tmp.name, "credentials")
        credentials.mkdir()
        (credentials / "immich-read-key").write_text("read-key\n")
        old = {
            key: os.environ.get(key)
            for key in (
                "PHOTO_TRIAGE_DATA_DIR",
                "PHOTO_TRIAGE_IMMICH_SOCKET",
                "CREDENTIALS_DIRECTORY",
            )
        }
        os.environ["PHOTO_TRIAGE_DATA_DIR"] = self._tmp.name
        os.environ["PHOTO_TRIAGE_IMMICH_SOCKET"] = self.socket_path
        os.environ["CREDENTIALS_DIRECTORY"] = str(credentials)
        try:
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["scan", "--page-size", "3"]), 0)
            payload = json.loads(out.getvalue())
            self.assertEqual(payload["coverage"]["total"], self.scanned)
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["coverage"]), 0)
            self.assertEqual(json.loads(out.getvalue())["scan_id"], payload["scan_id"])
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
