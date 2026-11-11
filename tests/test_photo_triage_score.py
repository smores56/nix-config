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
from photo_triage.db import DETAIL_BUCKETS, Database  # noqa: E402
from photo_triage.immich import READ_PERMISSIONS, ImmichClient  # noqa: E402
from photo_triage.model import LLMClient  # noqa: E402
from photo_triage.scan import scan_library  # noqa: E402
from photo_triage.score import (  # noqa: E402
    PREVIEW_GENERATOR,
    PreviewError,
    MAX_REPLY_CHARS,
    SCHEMA,
    SCORE_MAX_TOKENS,
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

    def test_scored_preview_is_recorded_for_the_analyzer(self):
        self.score()
        row = self.database.connection.execute(
            "SELECT p.asset_id, p.generator_id, p.asset_checksum, p.asset_updated_at, "
            "a.checksum, a.updated_at FROM previews p JOIN assets a ON a.id = p.asset_id "
            "LIMIT 1"
        ).fetchone()
        self.assertEqual(row["generator_id"], PREVIEW_GENERATOR)
        self.assertEqual(row["asset_checksum"], row["checksum"])
        self.assertEqual(row["asset_updated_at"], row["updated_at"])

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
        self.assertEqual(payload["max_tokens"], SCORE_MAX_TOKENS)
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
            coverage = database.coverage(scan_id)
            self.assertEqual(coverage["reasons"]["preview"], 1)
            self.assertIn("404", next(iter(coverage["details"]["preview"])))
            database.close()

    def test_schema_failure_is_skipped_after_retries(self):
        self.fake_llm.content = "not json"
        stats = self.score()
        self.assertEqual(stats["skipped"], self.scanned)
        self.assertEqual(stats["model_calls"], self.scanned * 3)
        coverage = self.database.coverage(self.scan_id)
        self.assertEqual(coverage["reasons"]["schema"], self.scanned)
        detail = next(iter(coverage["details"]["schema"]))
        self.assertIn("not JSON", detail)
        self.assertIn("len=1-63", detail)
        self.assertIn("braces=none", detail)
        self.assertNotIn("not json", detail)  # model prose never reaches the database

    def test_model_skip_records_the_error_detail(self):
        self.fake_llm.fail_status = 400
        stats = self.score()
        self.assertEqual(stats["scored"], 0)
        coverage = self.database.coverage(self.scan_id)
        self.assertEqual(coverage["reasons"]["model"], self.scanned)
        detail = next(iter(coverage["details"]["model"]))
        self.assertIn("http=400", detail)
        # The server's body is arbitrary text; only the class is persisted.
        self.assertNotIn("injected failure", detail)

    def test_detail_is_bounded_and_printable(self):
        from photo_triage.score import DETAIL_MAX_CHARS, _detail

        noisy = "bad\x1b[2J\x1b[31mrequest\x00" + "x" * 500
        detail = _detail(noisy)
        self.assertLessEqual(len(detail), DETAIL_MAX_CHARS)
        self.assertTrue(detail.isprintable())
        self.assertNotIn("\x1b", detail)

    def test_max_tokens_skip_records_the_finish_reason(self):
        self.fake_llm.finish_reason = "length"
        stats = self.score()
        self.assertEqual(stats["scored"], 0)
        coverage = self.database.coverage(self.scan_id)
        self.assertEqual(coverage["reasons"]["model"], self.scanned)
        detail = next(iter(coverage["details"]["model"]))
        self.assertIn("hit max_tokens", detail)
        self.assertIn("completion_tokens=1", detail)

    def test_requeue_clears_skip_detail(self):
        self.fake_llm.content = "not json"
        self.score()
        self.database.requeue(self.scan_id, "schema")
        row = self.database.connection.execute(
            "SELECT state, reason, detail FROM scan_assets WHERE scan_id = ? LIMIT 1",
            (self.scan_id,),
        ).fetchone()
        self.assertEqual((row["state"], row["reason"], row["detail"]), ("pending", None, None))

    def test_coverage_rolls_up_excess_detail_buckets(self):
        self.database.connection.execute(
            "DELETE FROM scan_assets WHERE scan_id = ?", (self.scan_id,)
        )
        for index in range(12):
            self.database.add_scan_asset(
                self.scan_id, f"asset-{index}", "skipped", "schema", f"detail-{index}"
            )
        details = self.database.coverage(self.scan_id)["details"]["schema"]
        self.assertEqual(len(details), DETAIL_BUCKETS + 1)
        self.assertEqual(details["(other)"], 2)

    def test_coverage_rollup_cannot_absorb_a_real_bucket(self):
        self.database.connection.execute(
            "DELETE FROM scan_assets WHERE scan_id = ?", (self.scan_id,)
        )
        for index in range(11):
            self.database.add_scan_asset(
                self.scan_id, f"asset-{index}", "skipped", "schema", f"detail-{index}"
            )
        self.database.add_scan_asset(
            self.scan_id, "asset-other", "skipped", "schema", "(other)"
        )
        details = self.database.coverage(self.scan_id)["details"]["schema"]
        self.assertEqual(sum(details.values()), 12)

    def test_requeue_invalidates_analysis(self):
        self.database.connection.execute(
            "INSERT INTO scan_analysis(scan_id, generation, generator_id, "
            "heuristics_version, groups_built, completed_at) VALUES (?, 3, 'g', 'h', 1, 'now')",
            (self.scan_id,),
        )
        self.database.connection.execute(
            "UPDATE scan_assets SET state = 'skipped', reason = 'schema' WHERE scan_id = ?",
            (self.scan_id,),
        )
        self.database.requeue(self.scan_id, "schema")
        row = self.database.connection.execute(
            "SELECT generation, groups_built FROM scan_analysis WHERE scan_id = ?",
            (self.scan_id,),
        ).fetchone()
        self.assertEqual((row["generation"], row["groups_built"]), (3, 0))

    def test_empty_requeue_keeps_the_analysis(self):
        self.database.connection.execute(
            "INSERT INTO scan_analysis(scan_id, generation, generator_id, "
            "heuristics_version, groups_built, completed_at) VALUES (?, 3, 'g', 'h', 1, 'now')",
            (self.scan_id,),
        )
        self.assertEqual(self.database.requeue(self.scan_id, "type"), 0)
        groups = self.database.connection.execute(
            "SELECT groups_built FROM scan_analysis WHERE scan_id = ?", (self.scan_id,)
        ).fetchone()["groups_built"]
        self.assertEqual(groups, 1)

    def test_normalize_preview_rejects_bad_bytes_with_a_code(self):
        from photo_triage.score import normalize_preview

        with self.assertRaises(PreviewError) as raised:
            normalize_preview(b"not an image")
        self.assertEqual(str(raised.exception), "decode")

    def test_model_failure_detail_never_carries_the_body(self):
        from photo_triage.model import LLMError
        from photo_triage.score import _model_failure_detail

        contextual = LLMError(
            'scoring model returned 400: {"error":"the request exceeds the '
            'available context size"}',
            status=400,
        )
        self.assertEqual(
            _model_failure_detail(contextual), "model http=400 class=context-overflow"
        )
        foreign = LLMError("scoring model request failed: BadStatusLine('\\x00secret')")
        self.assertEqual(_model_failure_detail(foreign), "model http=0 class=transport")

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
            json.dumps({**valid, "verdict": "maybe"}),
            json.dumps({**valid, "defects": ["bogus"]}),
            json.dumps({**valid, "interest": 2.5}),
            json.dumps({**valid, "confidence": float("nan")}),
            "x" * (MAX_REPLY_CHARS + 1),
        ]
        for payload in bad:
            with self.subTest(payload=payload):
                with self.assertRaises(ScoreSchemaError):
                    parse_score(payload)

    def test_parse_score_tolerates_model_quirks(self):
        duplicated = parse_score(
            json.dumps({**VERDICT, "defects": ["blur", "blur", "dark", "blur"]})
        )
        self.assertEqual(duplicated["defects"], ["blur", "dark"])
        self.assertEqual(duplicated.pop("_repairs"), ["defects"])
        self.assertEqual(duplicated["verdict"], "review")
        # An off-scale confidence is distrusted, never rescaled into a delete.
        # 1 is ambiguous (certainty or 1% on the 0-100 scale) and is distrusted.
        for confidence in (85, 1.5, 100.5, -1, 1, 10**400):
            parsed = parse_score(
                json.dumps({**VERDICT, "verdict": "delete", "confidence": confidence})
            )
            self.assertEqual(parsed["confidence"], 0.0)
            self.assertEqual(parsed["verdict"], "review")
            self.assertEqual(parsed.pop("_repairs"), ["confidence"])
        exact = parse_score(json.dumps({**VERDICT, "confidence": 0.75}))
        self.assertEqual((exact["confidence"], exact.pop("_repairs")), (0.75, []))

    def test_parse_score_rejects_duplicate_json_keys(self):
        payload = (
            '{"verdict": "keep", "verdict": "delete", "defects": [], '
            '"interest": 3, "confidence": 0.9}'
        )
        with self.assertRaises(ScoreSchemaError):
            parse_score(payload)

    def test_quirky_reply_is_scored(self):
        self.fake_llm.content = json.dumps(
            {**VERDICT, "defects": ["blur", "blur"], "confidence": 80}
        )
        stats = self.score()
        self.assertEqual(stats["scored"], self.scanned)
        self.assertEqual(stats["repaired_defects"], self.scanned)
        self.assertEqual(stats["repaired_confidence"], self.scanned)
        row = self.database.connection.execute(
            "SELECT verdict, defects_json, confidence FROM scores LIMIT 1"
        ).fetchone()
        self.assertEqual(
            (row["verdict"], row["defects_json"], row["confidence"]),
            ("review", '["blur"]', 0.0),
        )

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
