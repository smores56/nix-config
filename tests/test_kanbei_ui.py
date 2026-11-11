"""Unit tests for the Kanbei UI shell.

Covers the response contract (exact CSP, JSON only), the passkey challenge lifecycle, and the
renderer policy. The renderer runs in the browser, so its DOM behaviour is exercised through
Node when the test environment provides one (``NODE`` in the unit-tests check); without Node
those assertions skip instead of pretending to pass. The full browser run lives in
``tests/kanbei_browser.py``.
"""

from __future__ import annotations

import http.client
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
UI_DIR = REPO / "modules/lib/kanbei/ui"
EXPECTED_CSP = (
    "default-src 'none'; connect-src 'self'; img-src 'self' data:; style-src 'self'; "
    "script-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
)
PLANTED = (
    "Here is an image ![](https://example.com/x.png) and a link "
    "[click](https://example.com). Neither is fetched or opened."
)


def load_server():
    spec = importlib.util.spec_from_file_location("kanbei_ui_server", UI_DIR / "server.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def node_binary() -> str | None:
    candidate = os.environ.get("NODE") or shutil.which("node")
    if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        return candidate
    return None


class ServerCase(unittest.TestCase):
    stub_reply = PLANTED

    def setUp(self):
        self.server_module = load_server()
        config = self.server_module.Config(ui_dir=str(UI_DIR), stub_reply=self.stub_reply)
        self.server = self.server_module.make_server(config, listen=("127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host, self.port = self.server.server_address[:2]
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, content_type="application/json", headers=None):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=10)
        payload = None
        merged = dict(headers or {})
        if body is not None:
            payload = body if isinstance(body, bytes) else json.dumps(body).encode()
            merged.setdefault("Content-Type", content_type)
        connection.request(method, path, body=payload, headers=merged)
        response = connection.getresponse()
        data = response.read()
        result = (response.status, dict(response.getheaders()), data)
        connection.close()
        return result


class CspAndStaticTests(ServerCase):
    def test_every_response_carries_the_exact_csp(self):
        for method, path, body in (
            ("GET", "/", None),
            ("GET", "/app.js", None),
            ("GET", "/render.js", None),
            ("GET", "/style.css", None),
            ("GET", "/api/health", None),
            ("GET", "/missing", None),
            ("POST", "/api/chat", {"message": "hi"}),
            ("POST", "/api/nope", {}),
        ):
            status, headers, _body = self.request(method, path, body)
            self.assertEqual(headers.get("Content-Security-Policy"), EXPECTED_CSP, path)
            self.assertNotIn("unsafe-inline", headers["Content-Security-Policy"])
            self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
            self.assertEqual(headers.get("Referrer-Policy"), "no-referrer")
            self.assertLess(status, 500)

    def test_index_is_self_contained(self):
        status, headers, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("text/html"))
        html = body.decode()
        self.assertIn('<script src="/render.js"', html)
        self.assertIn('<script src="/app.js"', html)
        self.assertIn('<link rel="stylesheet" href="/style.css"', html)
        self.assertNotIn("<script>", html)
        self.assertNotIn("style=", html)
        self.assertNotIn("http://", html)
        self.assertNotIn("https://", html.replace("/api/", ""))

    def test_unknown_paths_are_json_and_content_is_not_a_directory(self):
        for path in ("/missing", "/../etc/passwd", "/server.py", "/favicon.ico"):
            status, headers, body = self.request("GET", path)
            self.assertEqual(status, 404, path)
            self.assertIn("application/json", headers["Content-Type"])
            self.assertEqual(json.loads(body), {"error": "not found"})

    def test_api_health_is_json(self):
        status, headers, body = self.request("GET", "/api/health")
        self.assertEqual(status, 200)
        self.assertIn("application/json", headers["Content-Type"])
        self.assertEqual(json.loads(body), {"ok": True})


class ChatTests(ServerCase):
    def test_stub_keeps_planted_output_as_plain_json_string(self):
        status, headers, body = self.request("POST", "/api/chat", {"message": "hello"})
        self.assertEqual(status, 200)
        self.assertIn("application/json", headers["Content-Type"])
        payload = json.loads(body)
        self.assertEqual(payload["lane"], "stub")
        self.assertEqual(payload["reply"], PLANTED)
        self.assertIn("![](https://example.com/x.png)", payload["reply"])
        self.assertIn("[click](https://example.com)", payload["reply"])
        self.assertNotIn("<", payload["reply"])

    def test_rejects_wrong_media_type_and_bad_bodies(self):
        statuses = [
            self.request("POST", "/api/chat", b"hi", content_type="text/plain")[0],
            self.request("POST", "/api/chat", b"not json")[0],
            self.request("POST", "/api/chat", b"[]")[0],
            self.request("POST", "/api/chat", {})[0],
            self.request("POST", "/api/chat", {"message": "x" * 9000})[0],
        ]
        self.assertEqual(statuses, [415, 400, 400, 400, 413])

    def test_missing_lane_is_a_json_error(self):
        self.server.config.chat_upstream = "http://127.0.0.1:1"
        status, headers, body = self.request("POST", "/api/chat", {"message": "hello"})
        self.assertEqual(status, 502)
        self.assertIn("application/json", headers["Content-Type"])
        self.assertIn("error", json.loads(body))


class PasskeyTests(ServerCase):
    def test_register_challenge_is_single_use(self):
        _status, _headers, body = self.request("POST", "/api/passkey/register/options", {})
        options = json.loads(body)
        self.assertGreaterEqual(len(options["challenge"]), 32)
        self.assertEqual(options["rp"]["id"], "kanbei.sammohr.dev")
        credential = {"id": "cred-1", "type": "public-key"}

        first = self.request(
            "POST",
            "/api/passkey/register/verify",
            {"challenge": options["challenge"], "credential": credential},
        )
        self.assertEqual(first[0], 200)
        replay = self.request(
            "POST",
            "/api/passkey/register/verify",
            {"challenge": options["challenge"], "credential": credential},
        )
        self.assertEqual(replay[0], 403)

    def test_challenges_are_bound_to_their_purpose(self):
        _status, _headers, body = self.request("POST", "/api/passkey/auth/options", {})
        challenge = json.loads(body)["challenge"]
        response = self.request(
            "POST",
            "/api/passkey/register/verify",
            {"challenge": challenge, "credential": {"id": "cred-1"}},
        )
        self.assertEqual(response[0], 403)

    def test_unknown_and_expired_challenges_are_refused(self):
        response = self.request(
            "POST", "/api/passkey/auth/verify", {"challenge": "made-up"}
        )
        self.assertEqual(response[0], 403)

        clock = [1000.0]
        store = self.server_module.ChallengeStore(ttl=10, clock=lambda: clock[0])
        challenge = store.issue("auth")
        clock[0] += 11
        self.assertFalse(store.consume(challenge, "auth"))

    def test_store_is_bounded(self):
        store = self.server_module.ChallengeStore(max_pending=2)
        first = store.issue("auth")
        store.issue("auth")
        store.issue("auth")
        self.assertFalse(store.consume(first, "auth"))


class RendererPolicyTests(unittest.TestCase):
    def setUp(self):
        self.node = node_binary()
        self.render_js = UI_DIR / "render.js"

    def test_sources_never_build_html(self):
        for name in ("render.js", "app.js"):
            source = (UI_DIR / name).read_text()
            for sink in (
                "innerHTML",
                "outerHTML",
                "insertAdjacentHTML",
                "document.write",
                "eval(",
                "new Function",
                "setAttribute(\"href\"",
            ):
                self.assertNotIn(sink, source, f"{name} uses {sink}")
        app = (UI_DIR / "app.js").read_text()
        self.assertIn("createTextNode", app)
        self.assertIn("renderModelText", app)
        self.assertNotIn("http://", app)
        self.assertNotIn("https://", app)

    def run_node(self, script: str) -> None:
        result = subprocess.run(
            [self.node, "-e", script, str(self.render_js)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_renderer_is_text_only_and_never_links(self):
        if not self.node:
            self.skipTest("node is not available in this environment")
        self.run_node(
            r"""
const assert = require("assert");
const renderer = require(process.argv[1]);

function el(tag) {
  return {
    tag,
    children: [],
    appendChild(child) { this.children.push(child); },
    set innerHTML(_value) { throw new Error("innerHTML is forbidden"); },
  };
}
const document = {
  createElement: (tag) => el(tag),
  createTextNode: (text) => ({ text }),
};
const root = el("div");
renderer.renderModelText(
  root,
  "plain <img src=x onerror=alert(1)>\n![](https://example.com/x.png)\n[click](https://example.com)"
);
assert.strictEqual(root.children.length, 3);
const tags = root.children.map((child) => child.tag);
assert.deepStrictEqual(tags, ["p", "p", "p"]);
const texts = root.children.map((child) => child.children[0].text);
assert.strictEqual(texts[0], "plain <img src=x onerror=alert(1)>");
assert.strictEqual(texts[1], "![](https://example.com/x.png)");
assert.strictEqual(texts[2], "[click](https://example.com)");
for (const child of root.children) {
  assert.strictEqual(child.children.length, 1);
  assert.ok(typeof child.children[0].text === "string");
  assert.strictEqual(child.children[0].tag, undefined);
}

assert.strictEqual(renderer.safeHref("javascript:alert(1)"), null);
assert.strictEqual(renderer.safeHref("JaVaScRiPt:alert(1)"), null);
assert.strictEqual(renderer.safeHref("data:text/html,<script>"), null);
assert.strictEqual(renderer.safeHref("data:image/png;base64,AA=="), null);
assert.strictEqual(renderer.safeHref("http://example.com"), null);
assert.strictEqual(renderer.safeHref("//example.com"), null);
assert.strictEqual(renderer.safeHref("https://example.com/a"), "https://example.com/a");
assert.strictEqual(renderer.safeHref("/api/health"), "/api/health");
assert.strictEqual(renderer.safeHref("java\nscript:alert(1)"), null);
assert.strictEqual(renderer.safeHref(42), null);
"""
        )


if __name__ == "__main__":
    unittest.main()
