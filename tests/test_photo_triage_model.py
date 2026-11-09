import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fake_llm import FakeLLM  # noqa: E402

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.cli import main  # noqa: E402
from photo_triage.model import LLMClient, LLMError  # noqa: E402


class ModelClientTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.socket_path = str(Path(self._tmp.name, "llm.sock"))
        self.fake = FakeLLM(self.socket_path)
        self.fake.start()
        self.client = LLMClient(socket_path=self.socket_path, model="photo-triage")

    def tearDown(self):
        self.fake.stop()
        self._tmp.cleanup()

    def test_models_reports_the_alias(self):
        self.assertEqual(self.client.models(), ["photo-triage"])

    def test_chat_is_deterministic_and_disables_thinking(self):
        response_format = {
            "type": "json_schema",
            "json_schema": {"name": "verdict", "schema": {"type": "object"}},
        }
        response = self.client.chat(
            [{"role": "user", "content": "hello"}],
            max_tokens=12,
            response_format=response_format,
        )
        self.assertEqual(self.client.content(response), "unknown")
        _, path, payload = self.fake.requests[-1]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(payload["temperature"], 0)
        self.assertEqual(payload["max_tokens"], 12)
        self.assertEqual(payload["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(payload["response_format"], response_format)

    def test_vision_self_test_passes(self):
        self.client.vision_self_test()

    def test_vision_self_test_rejects_an_ignored_image(self):
        self.fake.ignore_images = True
        with self.assertRaisesRegex(LLMError, "no image tokens"):
            self.client.vision_self_test()

    def test_vision_self_test_rejects_the_wrong_color(self):
        self.fake.answer = "blue"
        with self.assertRaisesRegex(LLMError, "wrong color"):
            self.client.vision_self_test()

    def test_vision_self_test_rejects_a_missing_alias(self):
        self.fake.models = ["other"]
        with self.assertRaisesRegex(LLMError, "not served"):
            self.client.vision_self_test()

    def test_length_finish_reason_is_an_error(self):
        self.fake.finish_reason = "length"
        with self.assertRaisesRegex(LLMError, "max_tokens"):
            self.client.chat([{"role": "user", "content": "hello"}])

    def test_empty_content_is_an_error(self):
        self.fake.content = ""
        with self.assertRaisesRegex(LLMError, "empty content"):
            self.client.chat([{"role": "user", "content": "hello"}])

    def test_error_taxonomy_and_wait_ready(self):
        self.fake.fail_status = 503
        with self.assertRaises(LLMError) as raised:
            self.client.models()
        self.assertTrue(raised.exception.transient)
        self.assertEqual(raised.exception.status, 503)
        self.fake.fail_status = None
        self.client.wait_ready(timeout=1, interval=0.01)

    def test_self_test_command(self):
        old = {
            key: os.environ.get(key)
            for key in ("PHOTO_TRIAGE_LLM_SOCKET", "PHOTO_TRIAGE_MODEL")
        }
        os.environ["PHOTO_TRIAGE_LLM_SOCKET"] = self.socket_path
        os.environ["PHOTO_TRIAGE_MODEL"] = "photo-triage"
        try:
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["self-test"]), 0)
            self.assertEqual(json.loads(out.getvalue()), {"ok": "vision self-test"})
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
