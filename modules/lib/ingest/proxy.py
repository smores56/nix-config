"""Host egress proxy for the ingest taps.

One listener per tap on its host address (`10.77.<index>.1:3128`). A request is
accepted only from that tap's guest address and only for a hostname in the
source's allowlist. CONNECT is additionally gated on the TLS SNI inside the
first ClientHello, so a client cannot tunnel to a different allowlisted name
(or an address) through a permitted CONNECT. Absolute-form HTTP is checked on
both the request target and the Host header.

Logs are metadata only: time, source, target host/port, decision, byte counts.
Paths, queries and payload bytes never reach a log line.
"""

from __future__ import annotations

import argparse
import json
import select
import socket
import sys
import threading
import time
from datetime import datetime, timezone

import policy

MAX_HEADER_BYTES = 16384
MAX_HELLO_BYTES = 16384


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-proxy", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def load_policy(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def response(code: int, reason: str) -> bytes:
    return f"HTTP/1.1 {code} {reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".encode()


class Proxy:
    def __init__(self, policy_data: dict, force_source: str | None, verify_allow: list[str], port: int):
        self.constants = policy_data.get("constants", {})
        self.sources = policy_data["sources"]
        self.by_gateway = {entry["gateway"]: (name, entry) for name, entry in self.sources.items()}
        self.by_client = {entry["client"]: name for name, entry in self.sources.items()}
        self.force_source = force_source
        self.port = port
        self.verify_allow = {policy.normalize_host(h) for h in verify_allow}

    def allowlist(self, source: str) -> set[str]:
        entry = self.sources[source]
        return {policy.normalize_host(h) for h in entry.get("allow", [])} | self.verify_allow

    def source_for(self, peer: str, local: str) -> str | None:
        if self.force_source:
            return self.force_source if self.force_source in self.sources else None
        name = self.by_client.get(peer)
        if name is None:
            return None
        if name in self.by_gateway and self.by_gateway[name][1]["gateway"] != local:
            return None
        return name

    def handle(self, conn: socket.socket, peer: tuple[str, int], local: tuple[str, int]) -> None:
        started = time.monotonic()
        source = self.source_for(peer[0], local[0])
        if source is None:
            log("deny", reason="unknown_peer", peer=peer[0], listen=local[0])
            conn.sendall(response(403, "Forbidden"))
            conn.close()
            return
        try:
            header, rest = self._read_header(conn)
            request_line, headers = self._parse(header)
            method, target, version = request_line
            if method.upper() == "CONNECT":
                self._connect(conn, source, target, rest, started)
            else:
                self._absolute(conn, source, method, target, version, headers, rest, started)
        except (policy.PolicyError, socket.timeout, OSError) as exc:
            log("deny", source=source, reason=str(exc), peer=peer[0])
            try:
                conn.sendall(response(403, "Forbidden"))
            except OSError:
                pass
            conn.close()

    @staticmethod
    def _read_header(conn: socket.socket) -> tuple[bytes, bytes]:
        conn.settimeout(15)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                raise policy.PolicyError("client closed before headers")
            buf += chunk
            if len(buf) > MAX_HEADER_BYTES:
                raise policy.PolicyError("header too large")
        head, _, rest = buf.partition(b"\r\n\r\n")
        return head, rest

    @staticmethod
    def _parse(header: bytes) -> tuple[tuple[str, str, str], dict[str, str]]:
        lines = header.decode("iso-8859-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3 or not parts[2].startswith("HTTP/"):
            raise policy.PolicyError("malformed request line")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, sep, value = line.partition(":")
            if not sep:
                raise policy.PolicyError("malformed header")
            headers[name.strip().lower()] = value.strip()
        return (parts[0], parts[1], parts[2]), headers

    def _connect(
        self, conn: socket.socket, source: str, target: str, rest: bytes, started: float
    ) -> None:
        host, port = policy.parse_authority(target, default_port=443)
        if port != 443:
            raise policy.PolicyError("CONNECT is HTTPS-only (443)")
        if host not in self.allowlist(source):
            log("deny", source=source, action="connect", host=host, port=port, reason="not_allowlisted")
            raise policy.PolicyError(f"{host} is not allowlisted for {source}")
        # The SNI is verified before any upstream connection exists, so a mismatched
        # ClientHello never reaches the internet.
        hello = self._read_client_hello(conn, rest)
        sni = policy.parse_client_hello_sni(hello)
        if sni != host:
            log(
                "deny",
                source=source,
                action="connect",
                host=host,
                sni=sni,
                reason="sni_mismatch",
            )
            conn.close()
            return
        upstream = self._dial(host, port)
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        log("allow", source=source, action="connect", host=host, port=port, sni=sni)
        upstream.sendall(hello)
        self._splice(conn, upstream, source, host, port, started)

    def _absolute(
        self,
        conn: socket.socket,
        source: str,
        method: str,
        target: str,
        version: str,
        headers: dict[str, str],
        rest: bytes,
        started: float,
    ) -> None:
        host, port, path = policy.parse_absolute_form(target)
        if host not in self.allowlist(source):
            log("deny", source=source, action="http", host=host, port=port, reason="not_allowlisted")
            raise policy.PolicyError(f"{host} is not allowlisted for {source}")
        header_host = headers.get("host")
        if header_host is not None:
            header_hostname, _ = policy.parse_host_header(header_host)
            if header_hostname != host:
                log("deny", source=source, action="http", host=host, header_host=header_hostname, reason="host_mismatch")
                raise policy.PolicyError("Host header does not match the absolute-form target")
        upstream = self._dial(host, port)
        forwarded = [
            f"{method} {path} {version}",
            f"Host: {host}",
        ]
        for name, value in headers.items():
            if name in {"host", "proxy-connection", "proxy-authorization"}:
                continue
            forwarded.append(f"{name}: {value}")
        upstream.sendall(("\r\n".join(forwarded) + "\r\n\r\n").encode("iso-8859-1") + rest)
        log("allow", source=source, action="http", host=host, port=port)
        self._splice(conn, upstream, source, host, port, started)

    @staticmethod
    def _dial(host: str, port: int) -> socket.socket:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        last: OSError | None = None
        for family, socktype, proto, _canon, addr in infos:
            sock = socket.socket(family, socktype, proto)
            sock.settimeout(15)
            try:
                sock.connect(addr)
                return sock
            except OSError as exc:
                last = exc
                sock.close()
        raise policy.PolicyError(f"upstream {host}:{port} unreachable: {last}")

    @staticmethod
    def _read_client_hello(conn: socket.socket, first: bytes) -> bytes:
        buf = first
        conn.settimeout(10)
        while True:
            try:
                policy.parse_client_hello_sni(buf)
                return buf
            except policy.NeedMoreData:
                pass
            chunk = conn.recv(4096)
            if not chunk:
                raise policy.PolicyError("client closed before ClientHello")
            buf += chunk
            if len(buf) > MAX_HELLO_BYTES:
                raise policy.PolicyError("ClientHello too large")

    @staticmethod
    def _splice(
        client: socket.socket,
        upstream: socket.socket,
        source: str,
        host: str,
        port: int,
        started: float,
    ) -> None:
        client.setblocking(False)
        upstream.setblocking(False)
        sent = received = 0
        socks = [client, upstream]
        while socks:
            readable, _, errored = select.select(socks, [], socks, 30)
            if errored:
                break
            if not readable:
                break
            for sock in readable:
                other = upstream if sock is client else client
                try:
                    data = sock.recv(65536)
                except BlockingIOError:
                    continue
                if not data:
                    socks = []
                    break
                if sock is client:
                    sent += len(data)
                else:
                    received += len(data)
                try:
                    other.sendall(data)
                except OSError:
                    socks = []
                    break
        for sock in (client, upstream):
            try:
                sock.close()
            except OSError:
                pass
        log(
            "close",
            source=source,
            host=host,
            port=port,
            bytes_in=sent,
            bytes_out=received,
            ms=int((time.monotonic() - started) * 1000),
        )

    def serve(self, bind: tuple[str, int] | None) -> None:
        listeners: list[socket.socket] = []
        if bind is not None:
            listeners.append(self._listen(bind))
        else:
            for gateway, (name, entry) in self.by_gateway.items():
                try:
                    listeners.append(self._listen((gateway, self.port)))
                except OSError as exc:
                    log("bind-wait", source=name, gateway=gateway, reason=str(exc))
        if not listeners:
            raise SystemExit(1)
        while True:
            readable, _, _ = select.select(listeners, [], [], 30)
            if not readable:
                # The taps appear after the VMs start; retry any gateway that failed.
                if bind is None and len(listeners) < len(self.by_gateway):
                    for gateway, (name, _entry) in self.by_gateway.items():
                        if any(sock.getsockname()[0] == gateway for sock in listeners):
                            continue
                        try:
                            listeners.append(self._listen((gateway, self.port)))
                        except OSError:
                            pass
                continue
            for listener in readable:
                conn, peer = listener.accept()
                local = conn.getsockname()
                threading.Thread(target=self.handle, args=(conn, peer, local), daemon=True).start()

    def _listen(self, bind: tuple[str, int]) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(bind)
        sock.listen(16)
        log("listen", address=f"{bind[0]}:{bind[1]}")
        return sock


def parse_bind(text: str) -> tuple[str, int]:
    host, port = text.rsplit(":", 1)
    return host, int(port)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-proxy")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--bind", help="verification only: single ADDR:PORT listener")
    parser.add_argument("--force-source", help="verification only: treat every peer as this source")
    parser.add_argument("--verify-allow", action="append", default=[], help="verification only: temporary allow entry")
    args = parser.parse_args(argv)

    data = load_policy(args.policy)
    port = args.port or int(data.get("constants", {}).get("proxyPort", 3128))
    verify = bool(args.force_source or args.verify_allow or args.bind)
    if verify and not args.bind:
        parser.error("verification flags require --bind")
    if verify:
        host, _ = parse_bind(args.bind)
        if host not in {"127.0.0.1", "::1", "localhost"}:
            parser.error("verification flags are only valid on a loopback bind")
        if args.force_source and args.force_source not in data["sources"]:
            parser.error(f"unknown source {args.force_source}")
    proxy = Proxy(data, args.force_source, args.verify_allow, port)
    proxy.serve(parse_bind(args.bind) if args.bind else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
