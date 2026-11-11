import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from PIL import Image  # noqa: E402

from fake_immich import FakeImmich  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.duplicates import (  # noqa: E402
    _rank,
    analyze_scan,
    hamming,
    laplacian_variance,
    metrics,
    phash,
)
from photo_triage.immich import READ_PERMISSIONS, ImmichClient  # noqa: E402
from photo_triage.scan import scan_library  # noqa: E402


class DuplicateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._corpus = tempfile.TemporaryDirectory()
        cls.manifest = generate_corpus(Path(cls._corpus.name))
        images = assets_for(cls.manifest)
        exact = dict(next(asset for asset in images if asset["id"] == "asset-keep"))
        exact["id"] = "asset-exact-copy"
        cls.assets = images + [exact]
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

    def image(self, photo_id):
        with Image.open(self.manifest[photo_id]["path"]) as image:
            return image.convert("RGB")

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
        self.immich = ImmichClient(socket_path=self.socket_path, api_key="read-key")
        self.database = Database(Path(self._tmp.name, "triage.db"))
        self.scan_id = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )

    def tearDown(self):
        self.database.close()
        self.fake.stop()
        self._tmp.cleanup()

    def analyze(self, **kwargs):
        return analyze_scan(
            self.immich, self.database, self.scan_id, sleep=lambda _: None, **kwargs
        )

    def test_phash_near_pair_and_distinct_photos(self):
        duplicate = phash(self.image("duplicate-a"))
        resized = phash(self.image("duplicate-b"))
        keep = phash(self.image("keep"))
        self.assertLessEqual(hamming(duplicate, resized), 10)
        self.assertGreater(hamming(duplicate, keep), 10)

    def test_heuristics_separate_the_fixtures(self):
        self.assertLess(
            laplacian_variance(self.image("blur")),
            laplacian_variance(self.image("keep")),
        )
        self.assertLess(
            metrics(self.image("dark"))["mean_luma"],
            metrics(self.image("keep"))["mean_luma"],
        )
        self.assertGreater(
            metrics(self.image("bright"))["hi_clip"],
            metrics(self.image("keep"))["hi_clip"],
        )

    def test_hamming_is_64_bit(self):
        self.assertEqual(hamming(0, 0), 0)
        self.assertEqual(hamming(0, 1), 1)
        self.assertEqual(hamming((1 << 64) - 1, 0), 64)

    def test_analyze_builds_exact_and_near_groups(self):
        stats = self.analyze()
        self.assertGreaterEqual(stats["exact_groups"], 1)
        self.assertGreaterEqual(stats["near_groups"], 1)
        exact = self.database.connection.execute(
            "SELECT group_id FROM duplicate_groups WHERE scan_id = ? AND source = 'exact'",
            (self.scan_id,),
        ).fetchall()
        self.assertTrue(exact)
        exact_members = self.database.connection.execute(
            "SELECT asset_id FROM duplicate_members WHERE scan_id = ? AND group_id = ?",
            (self.scan_id, exact[0]["group_id"]),
        ).fetchall()
        self.assertEqual(
            {row["asset_id"] for row in exact_members},
            {"asset-keep", "asset-exact-copy"},
        )
        near = self.database.connection.execute(
            "SELECT group_id FROM duplicate_groups WHERE scan_id = ? AND source = 'near'",
            (self.scan_id,),
        ).fetchall()
        self.assertTrue(near)
        near_members = {
            row["asset_id"]: row["keep_rank"]
            for row in self.database.connection.execute(
                "SELECT asset_id, keep_rank FROM duplicate_members WHERE scan_id = ? AND group_id = ?",
                (self.scan_id, near[0]["group_id"]),
            ).fetchall()
        }
        self.assertEqual(near_members["asset-duplicate-a"], 0)
        self.assertEqual(near_members["asset-duplicate-b"], 1)

    def test_rank_prefers_a_trusted_stack_primary(self):
        def row(asset_id, primary, width, lap, size, verdict="keep"):
            return {
                "id": asset_id,
                "is_favorite": 0,
                "stack_primary": primary,
                "is_archived": 0,
                "is_trashed": 0,
                "visibility": "timeline",
                "width": width,
                "height": width,
                "lap_var": lap,
                "hi_clip": 0.0,
                "file_size": size,
                "taken_at": "2024-01-01T00:00:00.000Z",
                "verdict": verdict,
            }

        ranked = _rank(
            [row("sharp", 0, 4000, 900.0, 9_000_000), row("primary", 1, 1000, 5.0, 10)],
            set(),
        )
        self.assertEqual(ranked[0][0], "primary")
        ranked = _rank(
            [
                row("sharp", 0, 4000, 900.0, 9_000_000),
                row("primary", 1, 1000, 5.0, 10, verdict="delete"),
            ],
            set(),
        )
        self.assertEqual(ranked[0][0], "sharp")

    def test_tier_benchmark(self):
        self.analyze()
        pairs = set()
        groups = self.database.connection.execute(
            "SELECT group_id FROM duplicate_groups WHERE scan_id = ?", (self.scan_id,)
        ).fetchall()
        for group in groups:
            members = [
                row["asset_id"]
                for row in self.database.connection.execute(
                    "SELECT asset_id FROM duplicate_members WHERE scan_id = ? AND group_id = ?",
                    (self.scan_id, group["group_id"]),
                ).fetchall()
            ]
            for index, left in enumerate(members):
                for right in members[index + 1 :]:
                    pairs.add(frozenset((left, right)))
        expected = {
            frozenset(("asset-keep", "asset-exact-copy")),
            frozenset(("asset-duplicate-a", "asset-duplicate-b")),
        }
        self.assertEqual(pairs, expected)

    def test_immich_groups_are_reranked(self):
        self.analyze()
        rows = self.database.connection.execute(
            "SELECT asset_id, keep_rank FROM duplicate_members WHERE scan_id = ? "
            "AND group_id = 'dup-1' ORDER BY keep_rank",
            (self.scan_id,),
        ).fetchall()
        self.assertEqual([row["asset_id"] for row in rows], ["asset-duplicate-a", "asset-duplicate-b"])

    def test_second_analyze_reuses_previews(self):
        self.analyze()
        requests = len(self.fake.requests)
        stats = self.analyze()
        self.assertEqual(stats["assets"], len(self.assets))
        self.assertEqual(len(self.fake.requests), requests)

    def test_cli_analyze(self):
        credentials = Path(self._tmp.name, "credentials")
        credentials.mkdir()
        (credentials / "immich-read-key").write_text("read-key\n")
        keys = (
            "PHOTO_TRIAGE_DATA_DIR",
            "PHOTO_TRIAGE_IMMICH_SOCKET",
            "CREDENTIALS_DIRECTORY",
        )
        old = {key: os.environ.get(key) for key in keys}
        os.environ.update(
            {
                "PHOTO_TRIAGE_DATA_DIR": self._tmp.name,
                "PHOTO_TRIAGE_IMMICH_SOCKET": self.socket_path,
                "CREDENTIALS_DIRECTORY": str(credentials),
            }
        )
        try:
            from contextlib import redirect_stdout

            import io

            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["analyze"]), 0)
            payload = json.loads(out.getvalue())
            self.assertGreaterEqual(payload["near_groups"], 1)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
