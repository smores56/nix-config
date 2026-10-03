import hashlib
import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

# Fake server responses are built from the real responses DTO shape; the HTTP
# transport is injected so no test ever touches the network.
JPEG = b"\xff\xd8\xff\xe0unit-test-jpeg-bytes\xff\xd9"


def load_module():
    path = Path(__file__).parents[1] / "modules/features/immich/immich_ingest.py"
    spec = importlib.util.spec_from_file_location("immich_ingest", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def response(module, status, payload):
    body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    return module.HttpResponse(status=status, body=body, headers={})


class FakeTransport:
    """Records every call and defers the reply to a handler; thread-safe."""

    def __init__(self, handler):
        self.handler = handler
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, method, url, headers, body, timeout):
        raw = body
        # urllib streams a file-like body via read(); materialise it here so
        # assertions can inspect the bytes a real server would receive.
        if hasattr(body, "read"):
            chunks = []
            while True:
                chunk = body.read(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            body = b"".join(chunks)
        with self.lock:
            self.calls.append(
                {
                    "method": method,
                    "url": url,
                    "headers": headers,
                    "body": body,
                    "raw_body": raw,
                    "timeout": timeout,
                }
            )
            index = len(self.calls)
        return self.handler(method, url, headers, body, index)

    def posts(self, suffix):
        return [
            c
            for c in self.calls
            if c["method"] == "POST" and c["url"].rstrip("/").endswith(suffix)
        ]


class ImmichUploadTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        # Backoff sleeps must never slow the suite; patch the module default.
        self.mod._sleep = lambda _seconds: None
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.state = self.tmp_path / "state"
        self._env = dict(os.environ)
        os.environ["XDG_STATE_HOME"] = str(self.state)
        os.environ.pop("IMMICH_URL", None)
        # A dummy key lets cmd_upload build a client; auth itself is tested below.
        os.environ["IMMICH_API_KEY"] = "test-key"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self.tmp.cleanup()

    def media(self, name, content=JPEG):
        path = self.tmp_path / name
        path.write_bytes(content)
        os.utime(path, (1_600_000_000, 1_600_000_000))
        return str(path.resolve())

    # -- hashing / chunking --------------------------------------------------

    def test_compute_sha1_matches_hashlib(self):
        path = self.media("a.jpg", b"hello")
        self.assertEqual(
            self.mod.compute_sha1(path), hashlib.sha1(b"hello").hexdigest()
        )

    def test_bulk_check_chunks_requests(self):
        self.mod.BULK_CHUNK = 500
        seen = []

        def handler(method, url, headers, body, index):
            seen.append(len(json.loads(body)["assets"]))
            return response(self.mod, 200, {"results": []})

        checks = [(f"f{i}.jpg", f"{i:040x}") for i in range(1200)]
        client = self.mod.ImmichClient("http://x", "k", transport=FakeTransport(handler))
        client.bulk_upload_check(checks)
        self.assertEqual(seen, [500, 500, 200])

    def test_bulk_check_parses_accept_and_duplicate(self):
        payload = {
            "results": [
                {"id": "a.jpg", "action": "accept"},
                {"id": "b.jpg", "action": "reject", "reason": "duplicate", "assetId": "u"},
            ]
        }
        transport = FakeTransport(lambda *a: response(self.mod, 200, payload))
        client = self.mod.ImmichClient("http://x", "k", transport=transport)
        results = client.bulk_upload_check([("a.jpg", "aa"), ("b.jpg", "bb")])
        self.assertEqual(results["a.jpg"]["action"], "accept")
        self.assertEqual(results["b.jpg"]["reason"], "duplicate")
        sent = json.loads(transport.calls[0]["body"])
        self.assertEqual(sent["assets"][1], {"id": "b.jpg", "checksum": "bb"})

    # -- multipart / upload --------------------------------------------------

    def test_multipart_streams_single_file_part(self):
        path = self.media("photo.jpg", b"DATA")
        ctype, body = self.mod.encode_multipart_streaming(
            [
                ("fileCreatedAt", "2024-01-01T00:00:00.000Z"),
                ("fileModifiedAt", "2024-01-01T00:00:00.000Z"),
            ],
            "assetData",
            "photo.jpg",
            "application/octet-stream",
            path,
            boundary="BOUNDARY",
        )
        self.assertEqual(ctype, "multipart/form-data; boundary=BOUNDARY")
        # The file is streamed, not buffered whole into a bytes object.
        self.assertFalse(isinstance(body, (bytes, bytearray)))
        self.assertTrue(hasattr(body, "readinto"))
        text = body.read().decode("latin-1")
        self.assertEqual(len(body), len(text))
        for field in ("fileCreatedAt", "fileModifiedAt", "assetData", "filename="):
            self.assertIn(field, text)
        self.assertIn("DATA", text)
        self.assertNotIn("deviceAssetId", text)
        self.assertNotIn("deviceId", text)

    def test_upload_asset_posts_to_assets_with_iso_dates(self):
        path = self.media("photo.jpg")
        transport = FakeTransport(
            lambda *a: response(self.mod, 201, {"status": "created", "id": "uuid"})
        )
        client = self.mod.ImmichClient("http://x", "k", transport=transport)
        when = datetime(2024, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
        resp = client.upload_asset(path, when)
        self.assertEqual(resp.status, 201)
        call = transport.posts("/assets")[0]
        self.assertTrue(call["headers"]["Content-Type"].startswith("multipart/form-data"))
        self.assertNotIn("device", call["body"].decode("latin-1"))
        self.assertIn(b"2024-01-01T00:00:00.000Z", call["body"])
        self.assertIn(call["headers"]["x-api-key"], ("k",))

    def test_upload_uses_generous_timeout(self):
        # Regression: the 60s request timeout failed every video over a few
        # hundred MB (the largest is 2 GB, ~8 min); uploads need their own knob.
        path = self.media("clip.mp4", b"VIDEO")
        transport = FakeTransport(
            lambda *a: response(self.mod, 201, {"status": "created", "id": "u"})
        )
        client = self.mod.ImmichClient(
            "http://x", "k", transport=transport, timeout=60
        )
        client.upload_asset(path, datetime(2024, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(transport.calls[-1]["timeout"], self.mod.UPLOAD_TIMEOUT)
        self.assertGreater(transport.calls[-1]["timeout"], 60)

    def test_upload_streams_file_instead_of_buffering(self):
        content = b"X" * 5000
        path = self.media("clip.mp4", content)
        transport = FakeTransport(
            lambda *a: response(self.mod, 201, {"status": "created", "id": "u"})
        )
        client = self.mod.ImmichClient("http://x", "k", transport=transport)
        client.upload_asset(path, datetime(2024, 1, 1, tzinfo=timezone.utc))
        call = transport.calls[-1]
        self.assertFalse(isinstance(call["raw_body"], (bytes, bytearray)))
        self.assertTrue(hasattr(call["raw_body"], "readinto"))
        self.assertEqual(len(call["raw_body"]), len(call["body"]))
        self.assertIn(content, call["body"])
        self.assertEqual(call["headers"]["Content-Length"], str(len(call["body"])))

    def test_upload_retry_rebuilds_fresh_body(self):
        # A streamed body is single-use; a 5xx retry must send a fresh stream,
        # not an exhausted one (which would upload zero bytes).
        path = self.media("clip.mp4", b"PAYLOAD")
        statuses = iter([503, 201])
        seen = []

        def handler(method, url, headers, body, index):
            seen.append(body)
            return response(self.mod, next(statuses), {"status": "created", "id": "u"})

        transport = FakeTransport(handler)
        client = self.mod.ImmichClient("http://x", "k", transport=transport)
        resp = client.upload_asset(path, datetime(2024, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(resp.status, 201)
        self.assertEqual(len(seen), 2)
        for body in seen:
            self.assertIn(b"PAYLOAD", body)

    def test_format_iso8601_utc_and_offset(self):
        aware = datetime(2024, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
        self.assertEqual(self.mod.format_iso8601(aware), "2024-01-01T00:00:00.000Z")
        offset = datetime(
            2024, 1, 1, 2, 0, 0, tzinfo=timezone(timedelta(hours=2))
        )
        self.assertEqual(
            self.mod.format_iso8601(offset), "2024-01-01T00:00:00.000Z"
        )

    # -- auth ----------------------------------------------------------------

    def test_api_key_from_file_is_trimmed(self):
        key_file = self.tmp_path / "api-key"
        key_file.write_text("  secret-key\n")
        self.assertEqual(self.mod.get_api_key(str(key_file)), "secret-key")

    def test_api_key_from_env_when_file_missing(self):
        os.environ["IMMICH_API_KEY"] = " env-key "
        missing = self.tmp_path / "nope"
        self.assertEqual(self.mod.get_api_key(str(missing)), "env-key")

    def test_api_key_missing_raises_config_error(self):
        os.environ.pop("IMMICH_API_KEY", None)
        with self.assertRaises(self.mod.ConfigError):
            self.mod.get_api_key(str(self.tmp_path / "nope"))

    # -- retry / isolation ---------------------------------------------------

    def test_request_retries_on_429_and_5xx(self):
        statuses = iter([429, 503, 200])

        def handler(*a):
            return response(self.mod, next(statuses), {})

        transport = FakeTransport(handler)
        client = self.mod.ImmichClient("http://x", "k", transport=transport)
        resp = client._request("GET", "/ping")
        self.assertEqual(resp.status, 200)
        self.assertEqual(len(transport.calls), 3)

    # -- cmd_upload end-to-end ----------------------------------------------

    def _upload_handler(self, fail_paths=(), duplicates=()):
        def handler(method, url, headers, body, index):
            if "/api/assets/bulk-upload-check" in url:
                ids = [a["id"] for a in json.loads(body)["assets"]]
                results = []
                for cid in ids:
                    if cid in duplicates:
                        results.append({"id": cid, "action": "reject", "reason": "duplicate"})
                    else:
                        results.append({"id": cid, "action": "accept"})
                return response(self.mod, 200, {"results": results})
            if url.endswith("/assets"):
                if any(p in body.decode("latin-1") for p in fail_paths):
                    return response(self.mod, 500, {"message": "boom"})
                return response(self.mod, 201, {"status": "created", "id": "uuid"})
            raise AssertionError(f"unexpected {method} {url}")

        return handler

    def test_cmd_upload_uploads_and_reports_summary(self):
        a = self.media("a.jpg", b"aaaa")
        b = self.media("b.jpg", b"bbbb")
        transport = FakeTransport(self._upload_handler())
        self.mod.http_transport = transport
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["upload", self.tmp.name, "--api-key-file", str(self.tmp_path / "k")])
        self.assertEqual(code, 0)
        self.assertEqual(len(transport.posts("/assets")), 2)
        out = buf.getvalue()
        self.assertIn("uploaded=2", out)
        self.assertIn("failed=0", out)

    def test_cmd_upload_skips_duplicates(self):
        a = self.media("a.jpg", b"aaaa")
        transport = FakeTransport(self._upload_handler(duplicates=(a,)))
        self.mod.http_transport = transport
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["upload", self.tmp.name, "--api-key-file", "x"])
        self.assertEqual(code, 0)
        self.assertEqual(len(transport.posts("/assets")), 0)
        self.assertIn("duplicate=1", buf.getvalue())

    def test_cmd_upload_isolates_per_file_failures(self):
        bad = self.media("bad.jpg", b"bad")
        good = self.media("good.jpg", b"good")
        transport = FakeTransport(
            self._upload_handler(fail_paths=(os.path.basename(bad),))
        )
        self.mod.http_transport = transport
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(
                ["upload", self.tmp.name, "--api-key-file", "x", "--workers", "1"]
            )
        self.assertEqual(code, 1)
        out = buf.getvalue()
        self.assertIn("uploaded=1", out)
        self.assertIn("failed=1", out)

    def test_cmd_upload_manifest_resume_skips_uploaded(self):
        self.media("a.jpg", b"aaaa")
        first = FakeTransport(self._upload_handler())
        self.mod.http_transport = first
        with redirect_stdout(io.StringIO()):
            self.mod.main(["upload", self.tmp.name, "--api-key-file", "x"])
        self.assertEqual(len(first.posts("/assets")), 1)

        second = FakeTransport(self._upload_handler())
        self.mod.http_transport = second
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["upload", self.tmp.name, "--api-key-file", "x"])
        self.assertEqual(code, 0)
        self.assertEqual(len(second.calls), 0)
        self.assertIn("skipped=1", buf.getvalue())

    def test_cmd_upload_dry_run_makes_no_post(self):
        self.media("a.jpg", b"aaaa")
        transport = FakeTransport(lambda *a: self.fail("no call expected"))
        self.mod.http_transport = transport
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["upload", "--dry-run", self.tmp.name])
        self.assertEqual(code, 0)
        self.assertEqual(transport.calls, [])
        self.assertIn("dry-run", buf.getvalue())

    def test_cmd_upload_limit_caps_files(self):
        for name in ("a.jpg", "b.jpg", "c.jpg"):
            self.media(name, name.encode())
        transport = FakeTransport(self._upload_handler())
        self.mod.http_transport = transport
        with redirect_stdout(io.StringIO()):
            code = self.mod.main(
                ["upload", self.tmp.name, "--api-key-file", "x", "--limit", "1"]
            )
        self.assertEqual(code, 0)
        self.assertEqual(len(transport.posts("/assets")), 1)

    def test_cmd_upload_passes_upload_timeout(self):
        self.media("a.jpg", b"aaaa")
        transport = FakeTransport(self._upload_handler())
        self.mod.http_transport = transport
        with redirect_stdout(io.StringIO()):
            code = self.mod.main(
                ["upload", self.tmp.name, "--api-key-file", "x", "--upload-timeout", "123"]
            )
        self.assertEqual(code, 0)
        self.assertEqual(transport.posts("/assets")[0]["timeout"], 123)

    # -- bootstrap-admin -----------------------------------------------------

    def test_bootstrap_admin_writes_mode_600_key_and_hides_secret(self):
        secret = "s3cr3t-value"

        def handler(method, url, headers, body, index):
            if "/auth/admin-sign-up" in url:
                return response(self.mod, 201, {"id": "u", "email": "a@b.c"})
            if url.endswith("/api-keys"):
                return response(
                    self.mod, 201, {"secret": secret, "apiKey": {"id": "k"}}
                )
            raise AssertionError(url)

        transport = FakeTransport(handler)
        self.mod.http_transport = transport
        key_file = self.tmp_path / "keys" / "api-key"
        buf = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("hunter2\n")):
            with redirect_stdout(buf):
                code = self.mod.main(
                    [
                        "bootstrap-admin",
                        "--email",
                        "a@b.c",
                        "--name",
                        "Admin",
                        "--key-file",
                        str(key_file),
                    ]
                )
        self.assertEqual(code, 0)
        self.assertEqual(key_file.read_text().strip(), secret)
        self.assertEqual(oct(key_file.stat().st_mode & 0o777), oct(0o600))
        self.assertNotIn(secret, buf.getvalue())
        self.assertIn(str(key_file), buf.getvalue())
        key_body = json.loads(transport.posts("/api-keys")[0]["body"])
        self.assertEqual(key_body["permissions"], ["asset.upload", "asset.read"])
        self.assertNotIn("hunter2", transport.posts("/api-keys")[0]["body"].decode())

    def test_bootstrap_admin_fails_cleanly_when_users_exist(self):
        def handler(method, url, headers, body, index):
            return response(
                self.mod, 400, {"message": "Admin already exists"}
            )

        transport = FakeTransport(handler)
        self.mod.http_transport = transport
        buf = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("pw\n")):
            with redirect_stdout(buf):
                code = self.mod.main(
                    [
                        "bootstrap-admin",
                        "--email",
                        "a@b.c",
                        "--name",
                        "Admin",
                        "--key-file",
                        str(self.tmp_path / "api-key"),
                    ]
                )
        self.assertNotEqual(code, 0)
        self.assertEqual(len(transport.posts("/api-keys")), 0)
        self.assertIn("already", buf.getvalue())


    def test_all_api_paths_use_api_prefix(self):
        # Regression: bulk-upload-check carried /api but /assets, /auth/* and
        # /api-keys did not, so a real server 404'd them; mocks hid it because
        # the fake transport ignores path validity. Every path needs /api.
        seen = []

        def handler(method, url, headers, body, index):
            seen.append(url)
            if url.endswith("/bulk-upload-check"):
                return response(self.mod, 200, {"results": []})
            if url.endswith("/assets"):
                return response(self.mod, 201, {"status": "created", "id": "x"})
            if url.endswith("/api-keys"):
                return response(self.mod, 201, {"secret": "s", "apiKey": {"id": "k"}})
            if url.endswith("/auth/admin-sign-up"):
                return response(self.mod, 201, {"id": "u"})
            return response(self.mod, 404, {})

        client = self.mod.ImmichClient("http://host", api_key="k", transport=handler)
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "a.jpg")
            with open(path, "wb") as handle:
                handle.write(JPEG)
            client.upload_asset(path, datetime(2020, 1, 2, tzinfo=timezone.utc))
        client.bulk_upload_check([("a", "sha1")])
        client.admin_sign_up("a@b.c", "p", "n")
        client.create_api_key("n", ["asset.upload"])
        self.assertTrue(seen)
        for url in seen:
            self.assertIn("/api/", url)


    def test_extensionless_file_gets_extension_from_magic(self):
        # Takeout can name a JPEG by date alone; Immich 400s "Unsupported file
        # type" without an extension, so the multipart filename must gain one.
        captured = {}

        def handler(method, url, headers, body, index):
            captured["body"] = body.read() if hasattr(body, "read") else body
            return response(self.mod, 201, {"status": "created", "id": "x"})

        client = self.mod.ImmichClient("http://host", api_key="k", transport=handler)
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "2013-01-08")
            with open(path, "wb") as handle:
                handle.write(JPEG)
            client.upload_asset(path, datetime(2013, 1, 8, tzinfo=timezone.utc))
        self.assertIn(b'filename="2013-01-08.jpg"', captured["body"])


if __name__ == "__main__":
    unittest.main()
