#!/usr/bin/env python3
"""Kanbei's guest-side TLS terminator and reverse proxy (smores56/sdlc#642, T5).

TLS still terminates here, in the guest: the host relay only splices bytes and the host
ACME responder only signs the guest's CSR. What changed is what sits behind the certificate.
The old static shell (``legacy_shell.py``, kept unreferenced) is replaced by nanobot's WebUI
on ``127.0.0.1:8080``; this process terminates TLS and proxies every request to it,
including the WebSocket upgrade the WebUI's chat lane needs.

Every connection must first present the relay token (``KANBEI-AUTH 1 <token>\\n``, see
``relay_auth``) on the raw vsock stream, before TLS. The host relay writes that line from a
root-only systemd credential; without it the connection is closed before a byte of HTTP or
TLS is read.

The proxy is deliberately dumb: it forwards the client's Host header, adds
``X-Forwarded-Proto: https`` (nanobot derives the public ``wss://`` URL from it), and adds
three response headers that do not constrain the app — ``nosniff``, a no-referrer policy,
and a CSP fragment that only forbids framing and ``<base>``. nanobot's own CSP, if any,
still applies alongside it.
"""

from __future__ import annotations

import argparse
import os
import select
import socket
import socketserver
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# relay_auth lives one directory up; a script run by path puts only its own directory on
# sys.path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import relay_auth  # noqa: E402

# A connection that cannot present the relay token inside this window is dropped before
# it can hold a thread. The token line and the TLS handshake it gates share the short
# window; only the authenticated request afterwards gets the long timeout.
AUTH_TIMEOUT = 10.0
REQUEST_TIMEOUT = 120.0
CONNECT_TIMEOUT = 10.0
VMADDR_CID_ANY = 0xFFFFFFFF
PROXY_HEADER = b"X-Forwarded-Proto: https\r\n"
RELAYED_HEADERS = [
    b"X-Content-Type-Options: nosniff",
    b"Referrer-Policy: no-referrer",
    # A CSP fragment without script/style restrictions: it only removes framing and
    # <base> tricks, so it cannot conflict with what the WebUI itself declares.
    b"Content-Security-Policy: frame-ancestors 'none'; base-uri 'none'",
]
# Never forwarded: they describe this hop, not the request.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class Config:
    def __init__(
        self,
        *,
        upstream_host: str = "127.0.0.1",
        upstream_port: int = 8080,
        auth_token: bytes | None = None,
    ) -> None:
        self.upstream_host = upstream_host
        self.upstream_port = upstream_port
        self.auth_token = auth_token

    @property
    def upstream_addr(self) -> tuple[str, int]:
        return (self.upstream_host, self.upstream_port)


class KanbeiHandler(BaseHTTPRequestHandler):
    server_version = "kanbei"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # keep request lines out of the journal
        sys.stderr.write("kanbei-ui: %s\n" % (fmt % args))

    # --- proxying ---------------------------------------------------------------------

    def do_GET(self) -> None:
        self._proxy()

    do_HEAD = do_GET
    do_POST = do_GET
    do_PUT = do_GET
    do_PATCH = do_GET
    do_DELETE = do_GET
    do_OPTIONS = do_GET

    def _upgrade_requested(self) -> bool:
        upgrade = (self.headers.get("Upgrade") or "").strip().lower()
        connection = (self.headers.get("Connection") or "").lower()
        return upgrade == "websocket" and "upgrade" in connection

    def _request_head(self) -> bytes:
        host = self.headers.get("Host") or ""
        peer = self.client_address[0]
        lines = [f"{self.command} {self.path} HTTP/1.1", f"Host: {host}"]
        for name, value in self.headers.items():
            if name.lower() in HOP_BY_HOP or name.lower() in ("host", "content-length"):
                continue
            if name.lower().startswith("x-forwarded-"):
                continue
            lines.append(f"{name}: {value}")
        if host:
            lines.append(f"X-Forwarded-Host: {host}")
        lines.append(f"X-Forwarded-For: {peer}")
        lines.append(PROXY_HEADER.decode().rstrip())
        length = self.headers.get("Content-Length")
        if length is not None:
            lines.append(f"Content-Length: {length}")
        else:
            # No chunked forwarding: a body without a length is refused rather than
            # streamed blindly.
            lines.append("Content-Length: 0")
        if self._upgrade_requested():
            lines.append("Connection: Upgrade")
            lines.append("Upgrade: websocket")
        else:
            lines.append("Connection: close")
        return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")

    def _proxy(self) -> None:
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._reject(400, "bad content-length")
            return
        if self.headers.get("Transfer-Encoding"):
            # The WebUI's own requests are Content-Length JSON; a chunked body would need
            # reframing, which this terminator does not do.
            self._reject(411, "chunked request bodies are not proxied")
            return
        body = self.rfile.read(length) if length > 0 else b""
        head = self._request_head()
        try:
            upstream = socket.create_connection(self.server.config.upstream_addr, timeout=CONNECT_TIMEOUT)
        except OSError as exc:
            self._reject(502, f"the WebUI is not reachable: {exc}")
            return
        try:
            upstream.sendall(head + body)
            if self._upgrade_requested():
                self._splice(upstream)
            else:
                self._relay_response(upstream)
        except OSError as exc:
            sys.stderr.write(f"kanbei-ui: proxy error: {exc}\n")
        finally:
            upstream.close()
            self.close_connection = True

    def _reject(self, status: int, message: str) -> None:
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for header in RELAYED_HEADERS:
            self.send_header(*header.decode().split(": ", 1))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _relay_response(self, upstream: socket.socket) -> None:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = upstream.recv(65536)
            if not chunk:
                break
            head += chunk
        header_part, separator, rest = head.partition(b"\r\n\r\n")
        if not separator:
            self._reject(502, "the WebUI sent no response headers")
            return
        self.wfile.write(header_part)
        for header in RELAYED_HEADERS:
            self.wfile.write(b"\r\n" + header)
        self.wfile.write(b"\r\n\r\n")
        if rest:
            self.wfile.write(rest)
        while True:
            chunk = upstream.recv(65536)
            if not chunk:
                return
            self.wfile.write(chunk)

    def _splice(self, upstream: socket.socket) -> None:
        """Hand the connection to the WebSocket once the upgrade request is sent."""
        client = self.connection
        client.settimeout(None)
        upstream.settimeout(None)
        while True:
            pending = (
                isinstance(client, ssl.SSLSocket) and client.pending() > 0
            )
            readable = [client] if pending else select.select([client, upstream], [], [])[0]
            for sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                (upstream if sock is client else client).sendall(data)


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
    tls_context = None
    if tls_cert and tls_key:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(tls_cert, tls_key)
    if vsock_port is not None:
        return KanbeiServer(
            (VMADDR_CID_ANY, vsock_port),
            KanbeiHandler,
            config,
            family=socket.AF_VSOCK,
            tls_context=tls_context,
        )
    return KanbeiServer(listen or ("127.0.0.1", 0), KanbeiHandler, config, tls_context=tls_context)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", help="host:port for TCP (tests); vsock otherwise")
    parser.add_argument("--vsock-port", type=int, default=10000)
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    parser.add_argument(
        "--upstream",
        default="http://127.0.0.1:8080",
        help="the WebUI to terminate TLS for (loopback only)",
    )
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

    upstream = args.upstream.rstrip("/")
    if not upstream.startswith("http://127.0.0.1:"):
        print("kanbei-ui: --upstream must be a loopback http URL", file=sys.stderr)
        return 2
    host, _, port = upstream[len("http://") :].partition(":")
    config = Config(upstream_host=host, upstream_port=int(port), auth_token=auth_token)

    listen = None
    vsock_port = None
    if args.listen:
        listen_host, _, listen_port = args.listen.rpartition(":")
        listen = (listen_host or "127.0.0.1", int(listen_port))
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
