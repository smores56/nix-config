import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from fake_immich import FakeImmich  # noqa: E402
from fake_llm import FakeLLM  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import ALBUM_PERMISSIONS, READ_PERMISSIONS  # noqa: E402

VERDICT = {"verdict": "delete", "defects": ["blur"], "interest": 2, "confidence": 0.95}


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._corpus = tempfile.TemporaryDirectory()
        cls.assets = assets_for(generate_corpus(Path(cls._corpus.name)))

    @classmethod
    def tearDownClass(cls):
        cls._corpus.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.immich_socket = str(root / "immich.sock")
        self.llm_socket = str(root / "llm.sock")
        self.fake_immich = FakeImmich(
            assets=self.assets,
            keys={
                "read-key": sorted(READ_PERMISSIONS),
                "album-key": sorted(ALBUM_PERMISSIONS),
            },
            api_key="read-key",
            unix_path=self.immich_socket,
        )
        self.fake_immich.start()
        self.fake_llm = FakeLLM(self.llm_socket, content=json.dumps(VERDICT))
        self.fake_llm.start()
        self.credentials = root / "credentials"
        self.credentials.mkdir()
        (self.credentials / "immich-read-key").write_text("read-key")
        (self.credentials / "immich-album-key").write_text("album-key")
        self.env = {
            "PHOTO_TRIAGE_DATA_DIR": str(root),
            "PHOTO_TRIAGE_IMMICH_SOCKET": self.immich_socket,
            "PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET": self.immich_socket,
            "PHOTO_TRIAGE_LLM_SOCKET": self.llm_socket,
            "CREDENTIALS_DIRECTORY": str(self.credentials),
        }
        self.old = {key: os.environ.get(key) for key in self.env}
        os.environ.update(self.env)
        self.database = Database(root / "triage.db")

    def tearDown(self):
        self.database.close()
        self.fake_llm.stop()
        self.fake_immich.stop()
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._tmp.cleanup()

    def test_synthetic_library_to_albums(self):
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(["orchestrate"]), 0)
        result = json.loads(out.getvalue())
        self.assertEqual(result["score"]["scored"], len(self.assets))
        scan_id = result["scan_id"]
        export_path = Path(result["export"])
        export = json.loads(export_path.read_text())
        self.assertGreater(len(export["delete"]), 0)
        self.assertEqual(export["scan_id"], scan_id)

        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(
                main(
                    [
                        "calibration",
                        "sample",
                        "--total",
                        "40",
                        "--min-per-cluster",
                        "40",
                    ]
                ),
                0,
            )
        sample = json.loads(out.getvalue())
        sample_rows = self.database.sample_assets(f"scan-{scan_id}")
        self.assertEqual(sample["sample"], len(sample_rows))
        self.assertGreater(len(sample_rows), 0)
        labels_path = Path(self._tmp.name, "labels.json")
        labels_path.write_text(
            json.dumps({row["asset_id"]: "delete" for row in sample_rows})
        )
        with redirect_stdout(io.StringIO()):
            self.assertEqual(
                main(["calibration", "labels", "--file", str(labels_path)]), 0
            )
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(["calibration", "report", "--min-labelled", "1"]), 0)
        report = json.loads(out.getvalue())
        self.assertTrue(report["go_no_go"]["passed"])
        self.assertEqual(report["decide_run_id"], export["run_id"])

        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(["albums", "sync", "--export", str(export_path)]), 0)
        reports = json.loads(out.getvalue())["reports"]
        self.assertTrue(all(item["reconciled"] for item in reports))
        delete_id = self.database.album("delete")["immich_album_id"]
        review_id = self.database.album("review")["immich_album_id"]
        self.assertEqual(
            sorted(self.fake_immich.album_asset_ids(delete_id)), sorted(export["delete"])
        )
        self.assertEqual(
            sorted(self.fake_immich.album_asset_ids(review_id)), sorted(export["review"])
        )


if __name__ == "__main__":
    unittest.main()
