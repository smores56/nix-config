"""Unit tests for the Kanbei channel auth gates.

Every host listener a guest can dial now demands a peer CID and a root-only token as the
first line of the raw stream; the UI additionally requires that authenticated connection
for ``/api/*`` and a passkey session for ``/api/chat``. These tests drive the real
handshake over socket pairs, so a regression to "accept anything" fails here.
"""

from __future__ import annotations

import http.client
import http.server
import socketserver
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KANBEI = REPO / "modules/lib/kanbei"
UI_DIR = KANBEI / "ui"
INGEST = REPO / "modules/lib/ingest"
SEARCH = REPO / "modules/lib/search"
TOKEN = "a" * 64

sys.path.insert(0, str(KANBEI))


def load(name: str, directory: Path):
    sys.path.insert(0, str(directory))
    spec = importlib.util.spec_from_file_location(name, directory / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def relay_auth_module():
    return load("relay_auth", KANBEI)


class TokenFileTests(unittest.TestCase):
    def setUp(self):
        self.auth = relay_auth_module()
        self.dir = tempfile.mkdtemp()

    def write(self, text: str) -> str:
        path = os.path.join(self.dir, "token")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def test_a_valid_token_file_reads_to_bytes(self):
        self.assertEqual(self.auth.read_token(self.write(TOKEN + "\n")), TOKEN.encode())

    def test_a_short_or_whitespace_token_is_refused(self):
        for text in ("short\n", "", "a" * 200 + "\n", "two words " + TOKEN + "\n"):
            with self.assertRaises(self.auth.AuthError, msg=text):
                self.auth.read_token(self.write(text))

    def test_a_missing_token_file_is_an_error_not_a_bypass(self):
        with self.assertRaises(self.auth.AuthError):
            self.auth.read_token(os.path.join(self.dir, "absent"))


class HandshakeTests(unittest.TestCase):
    def setUp(self):
        self.auth = relay_auth_module()
        self.left, self.right = socket.socketpair()
        self.addCleanup(self.left.close)
        self.addCleanup(self.right.close)

    def test_the_exact_line_matches_and_a_near_miss_does_not(self):
        token = TOKEN.encode()
        presented = self.auth.PREFIX + token
        self.assertTrue(self.auth.matches(presented, token))
        self.assertFalse(self.auth.matches(self.auth.PREFIX + b"b" * 64, token))
        self.assertFalse(self.auth.matches(presented[:-1], token))

    def test_read_line_leaves_later_bytes_in_the_socket(self):
        self.right.sendall(self.auth.encode(TOKEN.encode()) + b"payload")
        self.assertEqual(self.auth.read_line(self.left), self.auth.encode(TOKEN.encode())[:-1])
        self.assertEqual(self.left.recv(64), b"payload")

    def test_verify_rejects_a_wrong_or_missing_line(self):
        self.right.sendall(b"KANBEI-AUTH 1 " + b"z" * 64 + b"\n")
        with self.assertRaises(self.auth.AuthError):
            self.auth.verify(self.left, TOKEN.encode())
        self.right.close()
        with self.assertRaises(self.auth.AuthError):
            self.auth.verify(self.left, TOKEN.encode())

    def test_peer_cid_must_match_exactly(self):
        class Fake:
            def __init__(self, cid):
                self.cid = cid

            def getpeername(self):
                return (self.cid, 1234)

        self.auth.require_peer(Fake(4), 4)
        for cid in (2, 3, 5):
            with self.assertRaises(self.auth.AuthError):
                self.auth.require_peer(Fake(cid), 4)


class SignerRateLimitTests(unittest.TestCase):
    def setUp(self):
        self.cert_host = load("cert_host", KANBEI)
        self.dir = tempfile.mkdtemp()
        self.addCleanup(lambda: None)

    def test_marker_round_trip_and_interval(self):
        marker = os.path.join(self.dir, "last-issue")
        self.assertFalse(self.cert_host.rate_limited(marker, 10_000_000))
        self.cert_host.record_issue(marker, 10_000_000)
        self.assertTrue(self.cert_host.rate_limited(marker, 10_000_000 + 6 * 3600 - 1))
        self.assertFalse(self.cert_host.rate_limited(marker, 10_000_000 + 6 * 3600))
        self.assertEqual(os.stat(marker).st_mode & 0o777, 0o600)

    def test_issue_refuses_inside_the_window_before_calling_lego(self):
        marker = os.path.join(self.dir, "last-issue")
        self.cert_host.record_issue(marker, 1_000_000)
        signer = self.cert_host.Signer(
            lego="/bin/false",
            openssl="/bin/false",
            state_dir=self.dir,
            email="owner@example.com",
            token_file=os.path.join(self.dir, "unused"),
            clock=lambda: 1_000_000 + 60,
        )
        csr = (REPO / "tests/fixtures/kanbei/good.csr").read_text()
        with self.assertRaises(RuntimeError) as raised:
            signer.issue(csr)
        self.assertIn("rate limited", str(raised.exception))


class AgeKeyChannelTests(unittest.TestCase):
    def setUp(self):
        self.age_key = load("age_key", INGEST)
        self.auth = relay_auth_module()
        self.dir = tempfile.mkdtemp()
        self.out = os.path.join(self.dir, "age-recipient")

    def run_handle(self, client: bytes) -> bytes:
        server, peer = socket.socketpair()
        worker = threading.Thread(
            target=self.age_key.handle,
            args=(server, self.out, TOKEN.encode(), None),
            daemon=True,
        )
        worker.start()
        peer.sendall(client)
        peer.shutdown(socket.SHUT_WR)
        reply = peer.recv(64)
        peer.close()
        worker.join(timeout=5)
        return reply

    def test_a_token_then_recipient_publishes_the_file(self):
        recipient = "age1" + "q" * 58
        reply = self.run_handle(self.auth.encode(TOKEN.encode()) + recipient.encode() + b"\n")
        self.assertEqual(reply, b"OK\n")
        with open(self.out, encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), recipient)
        self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o400)

    def test_a_missing_or_wrong_token_publishes_nothing(self):
        for prefix in (b"", b"KANBEI-AUTH 1 " + b"b" * 64 + b"\n"):
            reply = self.run_handle(prefix + b"age1" + b"q" * 58 + b"\n")
            self.assertEqual(reply, b"ERR\n")
            self.assertFalse(os.path.exists(self.out))


class SearchRelayGateTests(unittest.TestCase):
    def setUp(self):
        self.relay = load("search_relay", SEARCH)
        self.auth = relay_auth_module()
        self.dir = tempfile.mkdtemp()
        self.uds = os.path.join(self.dir, "notify.vsock")
        Path(self.uds).write_text("")
        self.upstream_peer = None

    def run_handle(self, client: bytes, token=TOKEN.encode(), bad_peer=None) -> bytes:
        client_sock, peer = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        self.upstreams = []

        def connect(uds, port, timeout=1):
            self.upstreams.append(upstream)
            return upstream

        self.relay.connect_vsock = connect

        def serve():
            self.relay.handle(client_sock, self.uds, 7024, token, bad_peer)
            client_sock.close()

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        peer.sendall(client)
        peer.shutdown(socket.SHUT_WR)
        reply = peer.recv(64)
        peer.close()
        worker.join(timeout=5)
        return reply

    def test_a_token_is_consumed_and_payload_is_piped(self):
        self.upstream_peer = None
        client_sock, peer = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        self.relay.connect_vsock = lambda uds, port, timeout=1: upstream
        worker = threading.Thread(
            target=self.relay.handle,
            args=(client_sock, self.uds, 7024, TOKEN.encode(), None),
            daemon=True,
        )
        worker.start()
        peer.sendall(self.auth.encode(TOKEN.encode()) + b'{"v":1}\n')
        self.assertEqual(upstream_peer.recv(64), b'{"v":1}\n')
        upstream_peer.sendall(b'{"decision":"block"}\n')
        self.assertEqual(peer.recv(64), b'{"decision":"block"}\n')
        peer.shutdown(socket.SHUT_WR)
        upstream_peer.shutdown(socket.SHUT_WR)
        worker.join(timeout=5)

    def test_a_wrong_token_never_reaches_the_search_guest(self):
        reply = self.run_handle(b"KANBEI-AUTH 1 " + b"b" * 64 + b"\n")
        self.assertEqual(reply, b"ERR\n")
        self.assertEqual(self.upstreams, [])


class EchoUpstream(http.server.BaseHTTPRequestHandler):
    """A tiny stand-in for nanobot's WebUI: echoes what it received."""

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _reply(self):
        length = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(length) if length else b""
        payload = json.dumps(
            {
                "method": self.command,
                "path": self.path,
                "host": self.headers.get("Host"),
                "forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                "forwarded_host": self.headers.get("X-Forwarded-Host"),
                "body": body.decode("utf-8", "replace"),
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _reply
    do_POST = _reply


class WebSocketUpstream(socketserver.ThreadingTCPServer):
    """Accepts one upgrade, answers 101, then uppercases everything it receives."""

    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), WebSocketHandler)


class WebSocketHandler(socketserver.BaseRequestHandler):
    def handle(self):
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            head += chunk
        self.request.sendall(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n\r\n"
        )
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data.upper())


class UiProxyTests(unittest.TestCase):
    def setUp(self):
        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), EchoUpstream)
        self.upstream.daemon_threads = True
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.addCleanup(self.upstream.server_close)
        self.addCleanup(self.upstream.shutdown)
        self.server_module = load("server", UI_DIR)
        self.serve(self.upstream.server_address[1], auth_token=TOKEN.encode())

    def serve(self, upstream_port, auth_token):
        config = self.server_module.Config(
            upstream_port=upstream_port, auth_token=auth_token
        )
        self.server = self.server_module.make_server(config, listen=("127.0.0.1", 0))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.host, self.port = self.server.server_address[:2]

    def connect(self):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=10)
        connection.connect()
        return connection

    def request(self, method, path, body=None, headers=None, authenticated=True):
        connection = self.connect()
        if authenticated:
            connection.sock.sendall(b"KANBEI-AUTH 1 " + TOKEN.encode() + b"\n")
        merged = dict(headers or {})
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            merged.setdefault("Content-Type", "application/json")
        connection.request(method, path, body=payload, headers=merged)
        response = connection.getresponse()
        data = response.read()
        result = (response.status, dict(response.getheaders()), data)
        connection.close()
        return result

    def test_every_connection_without_the_token_is_closed_before_http(self):
        for preamble in (b"", b"KANBEI-AUTH 1 " + b"b" * 64 + b"\n"):
            connection = self.connect()
            connection.sock.sendall(preamble + b"GET / HTTP/1.1\r\n\r\n")
            self.assertEqual(connection.sock.recv(64), b"", preamble)
            connection.close()

    def test_a_request_is_proxied_with_forwarding_headers(self):
        status, headers, body = self.request(
            "GET", "/api/health?x=1", headers={"Host": "kanbei.sammohr.dev"}
        )
        self.assertEqual(status, 200)
        seen = json.loads(body)
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(seen["path"], "/api/health?x=1")
        self.assertEqual(seen["host"], "kanbei.sammohr.dev")
        self.assertEqual(seen["forwarded_proto"], "https")
        self.assertEqual(seen["forwarded_host"], "kanbei.sammohr.dev")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertIn("no-referrer", headers["Referrer-Policy"])

    def test_a_post_body_reaches_the_webui(self):
        status, _headers, body = self.request("POST", "/api/chat", {"message": "hi"})
        self.assertEqual(status, 200)
        seen = json.loads(body)
        self.assertEqual(seen["method"], "POST")
        self.assertEqual(json.loads(seen["body"]), {"message": "hi"})

    def test_a_downstream_outage_is_a_502(self):
        self.server_module = load("server", UI_DIR)
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        dead_port = closed.getsockname()[1]
        closed.close()
        self.serve(dead_port, auth_token=TOKEN.encode())
        status, _headers, body = self.request("GET", "/")
        self.assertEqual(status, 502)
        self.assertIn(b"not reachable", body)

    def test_a_websocket_upgrade_is_spliced(self):
        upstream = WebSocketUpstream()
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        self.serve(upstream.server_address[1], auth_token=TOKEN.encode())
        client = self.connect()
        client.sock.sendall(b"KANBEI-AUTH 1 " + TOKEN.encode() + b"\n")
        client.sock.sendall(
            b"GET /ws HTTP/1.1\r\nHost: kanbei.sammohr.dev\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            b"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        response = client.sock.recv(4096)
        self.assertIn(b"101 Switching Protocols", response)
        client.sock.sendall(b"ping")
        self.assertEqual(client.sock.recv(4096), b"PING")
        client.close()

    def test_the_upstream_must_be_loopback(self):
        self.assertEqual(
            self.server_module.main(
                ["--auth-token-file", self.token_file(), "--upstream", "http://10.0.0.1:8080"]
            ),
            2,
        )

    def token_file(self):
        path = os.path.join(tempfile.mkdtemp(), "token")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(TOKEN + "\n")
        return path


if __name__ == "__main__":
    unittest.main()
