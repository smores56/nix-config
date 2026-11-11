import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from fake_immich import FakeImmich  # noqa: E402
from fake_llm import FakeLLM  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

from photo_triage import operations  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import READ_PERMISSIONS, ImmichClient  # noqa: E402
from photo_triage.model import LLMClient  # noqa: E402
from photo_triage.scan import scan_library  # noqa: E402
from photo_triage.score import PREVIEW_GENERATOR  # noqa: E402
from photo_triage.duplicates import HEURISTICS_VERSION  # noqa: E402

VERDICT = {"verdict": "review", "defects": ["blur"], "interest": 3, "confidence": 0.8}


class OperationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._corpus = tempfile.TemporaryDirectory()
        cls.assets = assets_for(generate_corpus(Path(cls._corpus.name)))
        cls.scanned = len(cls.assets)

    @classmethod
    def tearDownClass(cls):
        cls._corpus.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.immich_socket = str(Path(self._tmp.name, "immich.sock"))
        self.llm_socket = str(Path(self._tmp.name, "llm.sock"))
        self.fake_immich = FakeImmich(
            assets=self.assets,
            keys={"read-key": sorted(READ_PERMISSIONS)},
            api_key="read-key",
            unix_path=self.immich_socket,
        )
        self.fake_immich.start()
        self.fake_llm = FakeLLM(self.llm_socket, content=json.dumps(VERDICT))
        self.fake_llm.start()
        self.immich = ImmichClient(socket_path=self.immich_socket, api_key="read-key")
        self.model = LLMClient(socket_path=self.llm_socket)
        self.database = Database(Path(self._tmp.name, "triage.db"))

    def tearDown(self):
        self.database.close()
        self.fake_llm.stop()
        self.fake_immich.stop()
        self._tmp.cleanup()

    def orchestrate(self, **kwargs):
        return operations.orchestrate(
            self.immich,
            self.model,
            self.database,
            page_size=100,
            export_dir=self._tmp.name,
            notifier=operations.Notifier(address=None),
            sleep=lambda _: None,
            **kwargs,
        )

    def test_orchestrate_runs_the_whole_pipeline(self):
        result = self.orchestrate()
        self.assertEqual(result["scan_id"], 1)
        self.assertEqual(result["score"]["scored"], self.scanned)
        self.assertEqual(result["decide"]["decided"], self.scanned)
        self.assertTrue(
            self.database.analysis_ready(
                result["scan_id"],
                generator_id=PREVIEW_GENERATOR,
                heuristics_version=HEURISTICS_VERSION,
            )
        )
        export_path = Path(result["export"])
        self.assertTrue(export_path.is_file())
        export = json.loads(export_path.read_text())
        self.assertEqual(export["scan_id"], result["scan_id"])
        self.assertEqual(len(self.database.decisions_for_scan(result["scan_id"])), self.scanned)

    def test_orchestrate_resumes_without_rescanning(self):
        first = self.orchestrate()
        second = self.orchestrate(scan_id=first["scan_id"])
        self.assertEqual(second["scan_id"], first["scan_id"])
        self.assertEqual(second["score"]["scored"], 0)
        self.assertEqual(second["decide"]["decided"], self.scanned)
        scans = self.database.connection.execute(
            "SELECT count(*) AS count FROM scans"
        ).fetchone()["count"]
        self.assertEqual(scans, 1)

    def test_status_reports_progress(self):
        result = self.orchestrate()
        status = operations.status(self.database)
        self.assertEqual(status["scan_id"], result["scan_id"])
        self.assertEqual(status["pending"], 0)
        self.assertEqual(status["scored"], self.scanned)
        self.assertTrue(status["analysis"]["ready"])
        self.assertIsNotNone(status["decide_run_id"])
        self.assertTrue(status["resume_safe"])
        self.assertIn("albums", status)
        self.assertEqual(status["skipped_details"], {})

    def test_benchmark_scores_a_bounded_batch(self):
        scan_id = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )
        result = operations.benchmark(
            self.immich, self.model, self.database, count=2, scan_id=scan_id,
            sleep=lambda _: None,
        )
        self.assertEqual(result["scored"] + result["reused"], 2)
        self.assertGreaterEqual(result["assets_per_minute"], 0)
        history = operations.benchmark_history(self.database)
        self.assertIsInstance(history["runs"], list)

    def test_notifier_is_a_noop_without_systemd(self):
        notifier = operations.Notifier(address=None)
        notifier.send("READY=1")
        notifier.start_watchdog(interval=0.01)
        notifier.stop_watchdog()


if __name__ == "__main__":
    unittest.main()
