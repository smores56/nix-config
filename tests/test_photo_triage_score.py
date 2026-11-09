import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fake_immich import FakeImmich  # noqa: E402
from fake_llm import FakeLLM  # noqa: E402
from photo_triage_fixtures import assets_for, generate_corpus  # noqa: E402

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import READ_PERMISSIONS, ImmichClient  # noqa: E402
from photo_triage.model import LLMClient  # noqa: E402
from photo_triage.scan import scan_library  # noqa: E402
from photo_triage.score import (  # noqa: E402
    SCHEMA,
    ScoreSchemaError,
    ScorerError,
    parse_score,
    score_library,
)

VERDICT = {"verdict": "review", "defects": ["blur"], "interest": 3, "confidence": 0.8}


class ScoreTests(unittest.TestCase):
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
        self.scan_id = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )

    def tearDown(self):
        self.database.close()
        self.fake_llm.stop()
        self.fake_immich.stop()
        self._tmp.cleanup()

    def score(self, scan_id=None):
        return score_library(
            self.immich,
            self.model,
            self.database,
            scan_id or self.scan_id,
            sleep=lambda _: None,
            model_id="qwen",
            mmproj_sha256="projector",
        )

    def test_scores_each_image(self):
        stats = self.score()
        self.assertEqual(stats["pending"], self.scanned)
        self.assertEqual(stats["scored"], self.scanned)
        self.assertEqual(stats["model_calls"], self.scanned)
        self.assertEqual(self.database.score_count(), self.scanned)
        self.assertEqual(self.database.preview_count(), self.scanned)
        self.assertEqual(
            self.database.coverage(self.scan_id)["states"]["scored"], self.scanned
        )
        row = self.database.connection.execute(
            "SELECT verdict, interest, confidence FROM scores LIMIT 1"
        ).fetchone()
        self.assertEqual((row["verdict"], row["interest"], row["confidence"]), ("review", 3, 0.8))

    def test_reuses_scores_across_generations(self):
        self.score()
        model_requests = len(self.fake_llm.requests)
        second_scan = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )
        stats = self.score(second_scan)
        self.assertEqual(stats["reused"], self.scanned)
        self.assertEqual(stats["scored"], 0)
        self.assertEqual(stats["model_calls"], 0)
        self.assertEqual(len(self.fake_llm.requests), model_requests)

    def test_prompt_and_schema(self):
        self.score()
        request = next(
            item for item in self.fake_llm.requests if item[1] == "/v1/chat/completions"
        )
        payload = request[2]
        self.assertEqual(payload["response_format"], SCHEMA)
        self.assertEqual(payload["temperature"], 0)
        self.assertEqual(payload["chat_template_kwargs"], {"enable_thinking": False})
        self.assertIn("Never describe or judge", payload["messages"][0]["content"])
        user_content = payload["messages"][1]["content"]
        self.assertTrue(
            any(part.get("type") == "image_url" for part in user_content)
        )

    def test_preview_failure_is_skipped(self):
        missing = dict(self.assets[0])
        missing["id"] = "asset-no-preview"
        missing["preview"] = None
        with FakeImmich(
            assets=[missing],
            keys={"read-key": sorted(READ_PERMISSIONS)},
            api_key="read-key",
            unix_path=self.immich_socket + ".missing",
        ) as immich_fake:
            client = ImmichClient(socket_path=self.immich_socket + ".missing", api_key="read-key")
            database = Database(Path(self._tmp.name, "missing.db"))
            scan_id = scan_library(client, database, page_size=100, sleep=lambda _: None)
            stats = score_library(
                client, self.model, database, scan_id, sleep=lambda _: None
            )
            self.assertEqual(stats["skipped"], 1)
            self.assertEqual(database.coverage(scan_id)["reasons"]["preview"], 1)
            database.close()

    def test_schema_failure_is_skipped_after_retries(self):
        self.fake_llm.content = "not json"
        stats = self.score()
        self.assertEqual(stats["skipped"], self.scanned)
        self.assertEqual(stats["model_calls"], self.scanned * 3)
        self.assertEqual(
            self.database.coverage(self.scan_id)["reasons"]["schema"], self.scanned
        )

    def test_transient_model_error_is_retried(self):
        self.fake_llm.queue_failure(503)
        stats = self.score()
        self.assertEqual(stats["scored"], self.scanned)
        self.assertEqual(stats["model_calls"], self.scanned + 1)

    def test_persistent_model_outage_aborts_and_leaves_assets_pending(self):
        self.fake_llm.fail_status = 503
        with self.assertRaises(ScorerError):
            self.score()
        self.assertEqual(
            self.database.scan_state(self.scan_id), "complete"
        )  # the scan generation is unchanged
        pending = self.database.pending_assets(self.scan_id)
        self.assertEqual(len(pending), self.scanned)
        run_state = self.database.connection.execute(
            "SELECT state FROM runs ORDER BY id DESC LIMIT 1"
        ).fetchone()["state"]
        self.assertEqual(run_state, "failed")

    def test_parse_score_rejects_bad_payloads(self):
        valid = dict(VERDICT)
        self.assertEqual(parse_score(json.dumps(valid))["verdict"], "review")
        bad = [
            "not json",
            "[]",
            json.dumps({**valid, "extra": 1}),
            json.dumps({**valid, "interest": 9}),
            json.dumps({**valid, "confidence": 2}),
            json.dumps({**valid, "verdict": "maybe"}),
            json.dumps({**valid, "defects": ["bogus"]}),
            json.dumps({**valid, "defects": ["blur", "blur"]}),
            json.dumps({**valid, "interest": 2.5}),
            json.dumps({**valid, "confidence": float("nan")}),
        ]
        for payload in bad:
            with self.subTest(payload=payload):
                with self.assertRaises(ScoreSchemaError):
                    parse_score(payload)

    def test_changed_preview_is_rescored(self):
        self.score()
        calls = len(self.fake_llm.requests)
        self.fake_immich.assets["asset-keep"]["checksum"] = "changed"
        self.fake_immich.assets["asset-keep"]["updatedAt"] = "2025-01-01T00:00:00.000Z"
        self.fake_immich.assets["asset-keep"]["preview"] = self.assets[1]["preview"]
        second = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )
        stats = self.score(second)
        self.assertGreaterEqual(stats["scored"], 1)
        self.assertGreater(len(self.fake_llm.requests), calls)

    def test_changed_model_identity_rescores(self):
        self.score()
        calls = len(self.fake_llm.requests)
        second = scan_library(
            self.immich, self.database, page_size=100, sleep=lambda _: None
        )
        stats = score_library(
            self.immich,
            self.model,
            self.database,
            second,
            sleep=lambda _: None,
            model_id="qwen",
            mmproj_sha256="other-projector",
        )
        self.assertEqual(stats["scored"], self.scanned)
        self.assertGreater(len(self.fake_llm.requests), calls)

    def test_cli_run(self):
        credentials = Path(self._tmp.name, "credentials")
        credentials.mkdir()
        (credentials / "immich-read-key").write_text("read-key\n")
        keys = (
            "PHOTO_TRIAGE_DATA_DIR",
            "PHOTO_TRIAGE_IMMICH_SOCKET",
            "PHOTO_TRIAGE_LLM_SOCKET",
            "PHOTO_TRIAGE_MODEL",
            "PHOTO_TRIAGE_MODEL_ID",
            "PHOTO_TRIAGE_MMPROJ_SHA256",
            "PHOTO_TRIAGE_UNIT",
            "CREDENTIALS_DIRECTORY",
        )
        old = {key: os.environ.get(key) for key in keys}
        os.environ.update(
            {
                "PHOTO_TRIAGE_DATA_DIR": self._tmp.name,
                "PHOTO_TRIAGE_IMMICH_SOCKET": self.immich_socket,
                "PHOTO_TRIAGE_LLM_SOCKET": self.llm_socket,
                "PHOTO_TRIAGE_MODEL": "photo-triage",
                "PHOTO_TRIAGE_MODEL_ID": "qwen",
                "PHOTO_TRIAGE_MMPROJ_SHA256": "projector",
                "PHOTO_TRIAGE_UNIT": "1",
                "CREDENTIALS_DIRECTORY": str(credentials),
            }
        )
        try:
            with redirect_stdout(__import__("io").StringIO()) as out:
                self.assertEqual(main(["run"]), 0)
            self.assertEqual(json.loads(out.getvalue())["scored"], self.scanned)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
