#!/usr/bin/env python3
"""Kanbei's guest-side UI shell and JSON API.

TLS terminates here, in the guest. The server answers with:

- ``/``, ``/app.js``, ``/render.js``, ``/style.css``: the human-owned static bundle, served
  with a strict CSP. There is no framework build and no remote resource.
- ``/api/*``: JSON only. Model text is never converted to HTML by this process; the browser
  renderer creates text nodes only.

The shell is deliberately small: chat against the local lane (or a deterministic stub when no
lane is wired), plus a WebAuthn stub whose challenges are stored server-side, single-use and
short-lived. Real attestation/assertion verification is a later task; the stub still refuses
a challenge it did not issue, a replayed challenge, and an expired one.

Every connection must first present the relay token (``KANBEI-AUTH 1 <token>\n``, see
``relay_auth``) on the raw vsock stream, before TLS. The host relay writes that line from a
root-only systemd credential; without it the connection is closed before a byte of HTTP or
TLS is read. ``/api/*`` additionally requires that authenticated connection, and
``/api/chat`` requires a session token issued only by a completed passkey assertion.
"""

from __future__ import annotations

import argparse
import base64
import functools
import json
import os
import secrets
import socket
import socketserver
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The UI bundle ships as `<tools>/ui/`, with relay_auth.py beside the bundle's parent; a
# script run by path puts only `<tools>/ui` on sys.path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import relay_auth  # noqa: E402

CSP = (
    "default-src 'none'; connect-src 'self'; img-src 'self' data:; style-src 'self'; "
    "script-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
)
RP_ID = "kanbei.sammohr.dev"
ORIGIN = f"https://{RP_ID}"
MAX_BODY = 64 * 1024
MAX_MESSAGE = 8000
# A connection that cannot present the relay token inside this window is dropped before
# it can hold a thread. The token line and the TLS handshake it gates share the short
# window; only the authenticated request afterwards gets the long timeout.
AUTH_TIMEOUT = 10.0
REQUEST_TIMEOUT = 120.0
VMADDR_CID_ANY = 0xFFFFFFFF
SESSION_TTL = 12 * 3600.0

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/render.js": ("render.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}

STUB_REPLY = "Kanbei stub: no chat lane is attached to this guest yet."


class ChallengeStore:
    """Server-side WebAuthn challenges: unguessable, single-use, expiring."""

    def __init__(self, ttl: float = 300.0, max_pending: int = 16, clock=time.monotonic) -> None:
        self.ttl = ttl
        self.max_pending = max_pending
        self.clock = clock
        self.lock = threading.Lock()
        self.pending: dict[str, tuple[str, float]] = {}

    def _prune(self, now: float) -> None:
        expired = [key for key, (_purpose, deadline) in self.pending.items() if deadline <= now]
        for key in expired:
            del self.pending[key]

    def issue(self, purpose: str) -> str:
        now = self.clock()
        with self.lock:
            self._prune(now)
            if len(self.pending) >= self.max_pending:
                oldest = min(self.pending, key=lambda key: self.pending[key][1])
                del self.pending[oldest]
            challenge = secrets.token_urlsafe(32)
            self.pending[challenge] = (purpose, now + self.ttl)
            return challenge

    def consume(self, challenge: str, purpose: str) -> bool:
        now = self.clock()
        with self.lock:
            self._prune(now)
            entry = self.pending.pop(challenge, None)
            if entry is None:
                return False
            stored_purpose, deadline = entry
            return stored_purpose == purpose and deadline > now


class SessionStore:
    """Passkey sessions: minted only after a completed assertion, expiring, bounded."""

    def __init__(
        self, ttl: float = SESSION_TTL, max_sessions: int = 32, clock=time.monotonic
    ) -> None:
        self.ttl = ttl
        self.max_sessions = max_sessions
        self.clock = clock
        self.lock = threading.Lock()
        self.sessions: dict[str, float] = {}

    def _prune(self, now: float) -> None:
        for token in [key for key, deadline in self.sessions.items() if deadline <= now]:
            del self.sessions[token]

    def issue(self) -> str:
        now = self.clock()
        with self.lock:
            self._prune(now)
            if len(self.sessions) >= self.max_sessions:
                oldest = min(self.sessions, key=lambda key: self.sessions[key])
                del self.sessions[oldest]
            token = secrets.token_urlsafe(32)
            self.sessions[token] = now + self.ttl
            return token

    def validate(self, token: str | None) -> bool:
        if not isinstance(token, str) or not token:
            return False
        now = self.clock()
        with self.lock:
            self._prune(now)
            deadline = self.sessions.get(token)
            return deadline is not None and deadline > now


class Config:
    def __init__(
        self,
        *,
        ui_dir: str,
        stub_reply: str = STUB_REPLY,
        chat_upstream: str | None = None,
        rp_id: str = RP_ID,
        challenges: ChallengeStore | None = None,
        auth_token: bytes | None = None,
        sessions: SessionStore | None = None,
    ) -> None:
        self.ui_dir = ui_dir
        self.stub_reply = stub_reply
        self.chat_upstream = chat_upstream
        self.rp_id = rp_id
        self.challenges = challenges or ChallengeStore()
        self.auth_token = auth_token
        self.sessions = sessions or SessionStore()


class KanbeiHandler(BaseHTTPRequestHandler):
    server_version = "kanbei"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # keep request lines out of the journal
        sys.stderr.write("kanbei-ui: %s\n" % (fmt % args))

    # --- plumbing ---------------------------------------------------------------------

    def _common_headers(self) -> None:
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self._common_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self._send(status, "application/json; charset=utf-8", body)

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": message})

    def _read_json(self) -> dict | None:
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if content_type != "application/json":
            # The body stays unread; never parse it as the next request on this connection.
            self.close_connection = True
            self._error(415, "content-type must be application/json")
            return None
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._error(400, "bad content-length")
            return None
        if length <= 0 or length > MAX_BODY:
            self.close_connection = True
            self._error(413, "body is missing or too large")
            return None
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._error(400, "body must be UTF-8 JSON")
            return None
        if not isinstance(body, dict):
            self._error(400, "body must be a JSON object")
            return None
        return body

    # --- authentication ----------------------------------------------------------------

    def _authenticated(self) -> bool:
        """True when this connection proved the relay token (or auth is disabled)."""
        if self.server.config.auth_token is None:
            return True
        # finish_request runs the handler in the same thread it authenticated in.
        return bool(getattr(self.server.auth_state, "authenticated", False))

    def _require_api_auth(self, path: str) -> bool:
        if path.startswith("/api/") and not self._authenticated():
            self.close_connection = True
            self._error(401, "this connection did not present the relay token")
            return False
        return True

    def _session_ok(self) -> bool:
        header = self.headers.get("Authorization") or ""
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer":
            return False
        return self.server.config.sessions.validate(token.strip())

    # --- routing ----------------------------------------------------------------------

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if not self._require_api_auth(path):
            return
        if path in STATIC_FILES:
            name, content_type = STATIC_FILES[path]
            try:
                with open(os.path.join(self.server.config.ui_dir, name), "rb") as handle:
                    body = handle.read()
            except OSError:
                self._error(500, "the UI bundle is incomplete")
                return
            self._send(200, content_type, body)
            return
        if path == "/api/health":
            self._json(200, {"ok": True})
            return
        self._error(404, "not found")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if not self._require_api_auth(path):
            return
        routes = {
            "/api/chat": self._chat,
            "/api/passkey/register/options": self._register_options,
            "/api/passkey/register/verify": self._register_verify,
            "/api/passkey/auth/options": self._auth_options,
            "/api/passkey/auth/verify": self._auth_verify,
        }
        handler = routes.get(path)
        if handler is None:
            self.close_connection = True
            self._error(404, "not found")
            return
        body = self._read_json()
        if body is not None:
            handler(body)

    # --- chat -------------------------------------------------------------------------

    def _chat(self, body: dict) -> None:
        # No lane-less stub bypass: a chat turn needs a passkey session, full stop.
        if not self._session_ok():
            self._error(401, "a passkey session is required")
            return
        message = body.get("message")
        if not isinstance(message, str) or not message.strip():
            self._error(400, "message must be a non-empty string")
            return
        if len(message) > MAX_MESSAGE:
            self._error(413, "message is too long")
            return
        upstream = self.server.config.chat_upstream
        if not upstream:
            self._json(200, {"reply": self.server.config.stub_reply, "lane": "stub"})
            return
        payload = json.dumps(
            {
                "model": "kanbei",
                "stream": False,
                "messages": [{"role": "user", "content": message}],
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            upstream.rstrip("/") + "/v1/chat/completions",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                reply = json.loads(response.read().decode("utf-8"))
            text = reply["choices"][0]["message"]["content"]
        except (urllib.error.URLError, KeyError, IndexError, TypeError, ValueError):
            self._error(502, "the chat lane did not answer")
            return
        if not isinstance(text, str):
            self._error(502, "the chat lane returned no text")
            return
        self._json(200, {"reply": text, "lane": "local"})

    # --- passkey stub -----------------------------------------------------------------

    def _register_options(self, _body: dict) -> None:
        challenge = self.server.config.challenges.issue("register")
        self._json(
            200,
            {
                "challenge": challenge,
                "rp": {"id": self.server.config.rp_id, "name": "Kanbei"},
                "user": {
                    "id": base64.urlsafe_b64encode(b"kanbei-owner").decode().rstrip("="),
                    "name": "owner",
                    "displayName": "Kanbei owner",
                },
                "pubKeyCredParams": [{"type": "public-key", "alg": -7}],
                "authenticatorSelection": {"residentKey": "preferred", "userVerification": "required"},
                "timeout": 120000,
                "attestation": "none",
                "origin": ORIGIN,
            },
        )

    def _register_verify(self, body: dict) -> None:
        challenge = body.get("challenge")
        credential = body.get("credential")
        if not isinstance(challenge, str) or not isinstance(credential, dict):
            self._error(400, "challenge and credential are required")
            return
        if not isinstance(credential.get("id"), str) or not credential.get("id"):
            self._error(400, "credential.id is required")
            return
        if not self.server.config.challenges.consume(challenge, "register"):
            self._error(403, "unknown, expired, or already used challenge")
            return
        # Stub: the challenge lifecycle is enforced; cryptographic attestation verification
        # is deliberately not implemented yet (documented in docs/kanbei-access.md).
        self._json(200, {"ok": True, "stub": True})

    def _auth_options(self, _body: dict) -> None:
        self._json(
            200,
            {
                "challenge": self.server.config.challenges.issue("auth"),
                "rpId": self.server.config.rp_id,
                "allowCredentials": [],
                "userVerification": "required",
                "timeout": 120000,
            },
        )

    def _auth_verify(self, body: dict) -> None:
        challenge = body.get("challenge")
        if not isinstance(challenge, str):
            self._error(400, "challenge is required")
            return
        if not self.server.config.challenges.consume(challenge, "auth"):
            self._error(403, "unknown, expired, or already used challenge")
            return
        self._json(200, {"ok": True, "stub": True, "session": self.server.config.sessions.issue()})


class KanbeiServer(ThreadingHTTPServer):
    address_family = socket.AF_INET

    def __init__(
        self,
        address,
        handler,
        config: Config,
        family: int = socket.AF_INET,
        tls_context: ssl.SSLContext | None = None,
    ):
        self.address_family = family
        self.config = config
        self.tls_context = tls_context
        # socket.socket has __slots__, so the per-connection flag lives on the thread.
        self.auth_state = threading.local()
        super().__init__(address, handler)

    def server_bind(self) -> None:
        # HTTPServer.server_bind names the server with socket.getfqdn(host), which expects a
        # string; on AF_VSOCK the host is an integer CID.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "kanbei"
        self.server_port = self.server_address[1]

    def finish_request(self, request, client_address) -> None:
        request.settimeout(AUTH_TIMEOUT)
        try:
            # The relay token is the first line on the raw stream, before TLS. A
            # connection that cannot prove it never reaches the handler and never
            # completes a TLS handshake.
            if self.config.auth_token is not None:
                relay_auth.verify(request, self.config.auth_token)
            connection = request
            if self.tls_context is not None:
                connection = self.tls_context.wrap_socket(request, server_side=True)
        except (OSError, relay_auth.AuthError, ssl.SSLError) as exc:
            sys.stderr.write(f"kanbei-ui: rejected connection: {exc}\n")
            self.shutdown_request(request)
            return
        # Only the authenticated connection may take its time on a request; the raw socket
        # has been detached by wrap_socket, so the timeout is set on the wrapping socket.
        connection.settimeout(REQUEST_TIMEOUT)
        self.auth_state.authenticated = True
        try:
            super().finish_request(connection, client_address)
        finally:
            self.auth_state.authenticated = False


def make_server(
    config: Config,
    *,
    listen: tuple[str, int] | None = None,
    vsock_port: int | None = None,
    tls_cert: str | None = None,
    tls_key: str | None = None,
) -> KanbeiServer:
    handler = functools.partial(KanbeiHandler)
    tls_context = None
    if tls_cert and tls_key:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(tls_cert, tls_key)
    if vsock_port is not None:
        server = KanbeiServer(
            (VMADDR_CID_ANY, vsock_port),
            handler,
            config,
            family=socket.AF_VSOCK,
            tls_context=tls_context,
        )
    else:
        server = KanbeiServer(
            listen or ("127.0.0.1", 0), handler, config, tls_context=tls_context
        )
    return server


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui-dir", default=os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--listen", help="host:port for TCP (tests); vsock otherwise")
    parser.add_argument("--vsock-port", type=int, default=10000)
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    parser.add_argument("--chat-upstream")
    parser.add_argument("--stub-reply", default=STUB_REPLY)
    parser.add_argument(
        "--auth-token-file",
        help="root-only relay token; required (the guest refuses a bare vsock connection)",
    )
    args = parser.parse_args(argv)

    if not args.auth_token_file:
        print("kanbei-ui: --auth-token-file is required", file=sys.stderr)
        return 2
    try:
        auth_token = relay_auth.read_token(args.auth_token_file)
    except relay_auth.AuthError as exc:
        print(f"kanbei-ui: {exc}", file=sys.stderr)
        return 2

    config = Config(
        ui_dir=args.ui_dir,
        stub_reply=args.stub_reply,
        chat_upstream=args.chat_upstream,
        auth_token=auth_token,
    )
    listen = None
    vsock_port = None
    if args.listen:
        host, _, port = args.listen.rpartition(":")
        listen = (host or "127.0.0.1", int(port))
    else:
        vsock_port = args.vsock_port
    server = make_server(
        config, listen=listen, vsock_port=vsock_port, tls_cert=args.tls_cert, tls_key=args.tls_key
    )
    print(f"kanbei-ui: serving on {server.server_address}", file=sys.stderr)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
