import base64
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).parents[1] / "modules/lib/agent-broker/src"
sys.path.insert(0, str(SRC))

from agent_broker import (  # noqa: E402
    Auth,
    allowed,
    build_headers,
    load_config,
    normalize_path,
    read_credential,
)


class BrokerTests(unittest.TestCase):
    def test_bearer_replaces_the_caller_credential(self):
        headers = build_headers(
            {"Authorization": "Bearer dummy", "Content-Type": "application/json", "Host": "x"},
            Auth("bearer", "", "", "k"),
            "real",
        )
        self.assertEqual(headers["Authorization"], "Bearer real")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertNotIn("Host", headers)

    def test_header_auth_replaces_the_named_header(self):
        headers = build_headers({"X-Api-Key": "dummy"}, Auth("header", "X-Api-Key", "", "k"), "real")
        self.assertEqual(headers["X-Api-Key"], "real")

    def test_basic_auth_encodes_user_and_key(self):
        headers = build_headers({}, Auth("basic", "", "smores56", "pw"), "pw")
        want = base64.b64encode(b"smores56:pw").decode()
        self.assertEqual(headers["Authorization"], f"Basic {want}")

    def test_none_auth_leaves_no_credential(self):
        self.assertEqual(build_headers({"Authorization": "x"}, Auth("none", "", "", ""), ""), {})

    def test_allow_rules_match_method_and_path(self):
        rules = ("POST /v1/chat/completions", "GET /v1/models", "DELETE /mcp")
        self.assertTrue(allowed(rules, "POST", "/v1/chat/completions"))
        self.assertFalse(allowed(rules, "GET", "/v1/chat/completions"))
        self.assertFalse(allowed(rules, "POST", "/v1/embeddings"))
        self.assertFalse(allowed((), "GET", "/anything"))

    def test_normalize_path(self):
        self.assertEqual(normalize_path("/a/./b/../c"), "/a/c")
        self.assertEqual(normalize_path("//a//b"), "/a/b")
        self.assertEqual(normalize_path("/a%2Fb"), "/a/b")
        self.assertEqual(normalize_path("/a%252Fb"), "/a%2Fb")
        with self.assertRaises(ValueError):
            normalize_path("/a/\x00/b")

    def test_traversal_cannot_escape_a_rule(self):
        rules = ("POST /api/search/metadata",)
        for path in (
            "/api/search/../assets/1/original",
            "/api/search/%2e%2e/assets/1/original",
            "/api/search/%2E%2E/assets/1/original",
        ):
            with self.subTest(path=path):
                self.assertFalse(allowed(rules, "POST", normalize_path(path)))

    def test_prefix_rule_cannot_be_escaped(self):
        self.assertFalse(allowed(("GET /api/*",), "GET", normalize_path("/api/../admin")))
        self.assertTrue(allowed(("GET /api/*",), "GET", normalize_path("/api/../api/admin")))

    def test_allow_prefix_rule(self):
        self.assertTrue(allowed(("POST /mcp*",), "POST", "/mcp/messages"))
        self.assertFalse(allowed(("POST /mcp*",), "POST", "/other"))

    def test_config_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "c.json")
            path.write_text(
                '{"listen": "127.0.0.1:9", "upstream": "https://example.com",'
                ' "allow": ["GET /"], "auth": {"kind": "bearer", "credential": "k"}}'
            )
            config = load_config(path)
            self.assertEqual(config.host, "127.0.0.1")
            self.assertEqual(config.port, 9)
            path.write_text(
                '{"listen": "127.0.0.1:9", "upstream": "https://e",'
                ' "allow": ["GET /"], "auth": {"kind": "bearer"}}'
            )
            with self.assertRaises(ValueError):
                load_config(path)
            path.write_text('{"listen": "nope", "upstream": "https://e", "allow": ["GET /"]}')
            with self.assertRaises(ValueError):
                load_config(path)

    def test_config_rejects_empty_allow(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "c.json")
            path.write_text(
                '{"listen": "127.0.0.1:9", "upstream": "https://example.com",'
                ' "auth": {"kind": "none"}}'
            )
            with self.assertRaises(ValueError):
                load_config(path)

    def test_config_rejects_malformed_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "c.json")
            for rule in ("GET", "GET api", "/api"):
                with self.subTest(rule=rule):
                    path.write_text(
                        '{"listen": "127.0.0.1:9", "upstream": "https://example.com",'
                        f' "allow": ["{rule}"], "auth": {{"kind": "none"}}}}'
                    )
                    with self.assertRaises(ValueError):
                        load_config(path)

    def test_credential_comes_from_the_credentials_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "k").write_text("s3cret\n")
            old = os.environ.get("CREDENTIALS_DIRECTORY")
            os.environ["CREDENTIALS_DIRECTORY"] = tmp
            try:
                self.assertEqual(read_credential("k"), "s3cret")
            finally:
                if old is None:
                    del os.environ["CREDENTIALS_DIRECTORY"]
                else:
                    os.environ["CREDENTIALS_DIRECTORY"] = old
            os.environ.pop("CREDENTIALS_DIRECTORY", None)
            with self.assertRaises(RuntimeError):
                read_credential("k")


if __name__ == "__main__":
    unittest.main()
