"""Unit tests for the kanbei inference eval harness (tests/inference/).

The eval itself needs the GPU guest and downloaded weights; these tests only prove the
harness's contract: the manifest is well formed, the fetch tool refuses a hash mismatch, and
every script exits 0 with a SKIP when the endpoint or the model is absent.
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import socket
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INFERENCE = REPO / "tests" / "inference"
sys.path.insert(0, str(INFERENCE))

import lane_fit  # noqa: E402
import long_context_recall  # noqa: E402
import quality_sample  # noqa: E402
import run_all  # noqa: E402
from common import missing_models  # noqa: E402

MANIFEST = REPO / "modules" / "lib" / "kanbei-models.json"
FETCH_TOOL = REPO / "modules" / "lib" / "kanbei-fetch-models.py"


def load_fetch_tool():
    spec = importlib.util.spec_from_file_location("kanbei_fetch_models", FETCH_TOOL)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class HealthyServer:
    """Minimal /health endpoint, so the skip path can be tested without a GPU."""

    def __init__(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                if self.path == "/health":
                    payload = json.dumps({"status": "ok"}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *args: object) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def write_tiny_manifest(directory: Path, payload: bytes, sha: str) -> Path:
    manifest = directory / "models.json"
    manifest.write_text(
        json.dumps(
            {
                "version": 1,
                "destination": str(directory / "models"),
                "models": {
                    "tiny": {
                        "repo": "example/tiny",
                        "file": "tiny.bin",
                        "size": len(payload),
                        "sha256": sha,
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    return manifest


class ManifestTests(unittest.TestCase):
    def test_manifest_has_the_contract_fields(self) -> None:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(data["destination"], "/var/lib/kanbei/models")
        self.assertGreaterEqual(len(data["models"]), 3)
        for name, spec in data["models"].items():
            with self.subTest(model=name):
                for field in ("repo", "file", "size", "sha256"):
                    self.assertIn(field, spec)
                self.assertIsInstance(spec["size"], int)
                self.assertGreater(spec["size"], 0)
                self.assertRegex(spec["sha256"], r"^[0-9a-f]{64}$")
                self.assertIn("/", spec["repo"])

    def test_missing_models_names_every_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = missing_models(Path(tmp), MANIFEST)
        self.assertEqual(len(missing), 3)
        self.assertTrue(all("is missing" in item for item in missing))


class FetchToolTests(unittest.TestCase):
    def test_check_rejects_a_hash_mismatch(self) -> None:
        tool = load_fetch_tool()
        payload = b"hello kanbei"
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            dest = directory / "models"
            dest.mkdir()
            (dest / "tiny.bin").write_bytes(payload)
            manifest = write_tiny_manifest(directory, payload, "0" * 64)
            stderr = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                code = tool.main(["--check", "--manifest", str(manifest), "--dest", str(dest)])
        self.assertEqual(code, 2)
        self.assertIn("sha256", stderr.getvalue())

    def test_check_accepts_a_matching_file(self) -> None:
        tool = load_fetch_tool()
        payload = b"hello kanbei"
        sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            dest = directory / "models"
            dest.mkdir()
            (dest / "tiny.bin").write_bytes(payload)
            manifest = write_tiny_manifest(directory, payload, sha)
            with contextlib.redirect_stdout(io.StringIO()):
                code = tool.main(["--check", "--manifest", str(manifest), "--dest", str(dest)])
        self.assertEqual(code, 0)

    def test_check_rejects_a_size_mismatch(self) -> None:
        tool = load_fetch_tool()
        payload = b"hello kanbei"
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            dest = directory / "models"
            dest.mkdir()
            (dest / "tiny.bin").write_bytes(payload + b"!")
            manifest = write_tiny_manifest(directory, payload, "0" * 64)
            stderr = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                code = tool.main(["--check", "--manifest", str(manifest), "--dest", str(dest)])
        self.assertEqual(code, 2)
        self.assertIn("bytes", stderr.getvalue())


class SkipTests(unittest.TestCase):
    def test_lane_fit_skips_without_endpoint(self) -> None:
        port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = lane_fit.main(
                    ["--chat-url", f"http://127.0.0.1:{port}", "--models-dir", tmp, "--timeout", "2"]
                )
        self.assertEqual(code, 0)
        self.assertIn("SKIP", out.getvalue())

    def test_lane_fit_skips_when_the_model_is_absent(self) -> None:
        server = HealthyServer()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    code = lane_fit.main(["--chat-url", server.url, "--models-dir", tmp])
                self.assertEqual(code, 0)
                self.assertIn("model files not downloaded", out.getvalue())
        finally:
            server.close()

    def test_recall_skips_without_endpoint(self) -> None:
        port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = long_context_recall.main(
                    ["--chat-url", f"http://127.0.0.1:{port}", "--models-dir", tmp, "--timeout", "2"]
                )
        self.assertEqual(code, 0)
        self.assertIn("SKIP", out.getvalue())

    def test_quality_skips_without_f16_server(self) -> None:
        server = HealthyServer()
        port = free_port()
        payload = b"hello kanbei"
        try:
            with tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                dest = directory / "models"
                dest.mkdir()
                (dest / "tiny.bin").write_bytes(payload)
                manifest = write_tiny_manifest(directory, payload, hashlib.sha256(payload).hexdigest())
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    code = quality_sample.main(
                        [
                            "--chat-url",
                            server.url,
                            "--fp16-url",
                            f"http://127.0.0.1:{port}",
                            "--models-dir",
                            str(dest),
                            "--manifest",
                            str(manifest),
                        ]
                    )
                self.assertEqual(code, 0)
                self.assertIn("no f16-KV reference server", out.getvalue())
        finally:
            server.close()

    def test_run_all_skips_cleanly(self) -> None:
        port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            with contextlib.redirect_stdout(io.StringIO()):
                code = run_all.main(
                    ["--chat-url", f"http://127.0.0.1:{port}", "--models-dir", tmp, "--timeout", "2"]
                )
        self.assertEqual(code, 0)


class ScoringTests(unittest.TestCase):
    def test_needle_detection_ignores_case_and_punctuation(self) -> None:
        answer = "The archive passphrase is: Amber-River, seven copper lantern moss."
        self.assertTrue(long_context_recall.contains_needle(answer, long_context_recall.NEEDLE))
        self.assertFalse(long_context_recall.contains_needle("no idea", long_context_recall.NEEDLE))

    def test_similarity_is_one_for_equal_text(self) -> None:
        self.assertEqual(quality_sample.similarity("same text", "same text"), 1.0)
        self.assertLess(quality_sample.similarity("same text", "other words"), 1.0)


if __name__ == "__main__":
    unittest.main()
