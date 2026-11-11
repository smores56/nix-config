"""Host-side relay from Kanbei's vsock port to the search guest's query port.

Kanbei dials host CID 2 on port 7101; this unit listens on host AF_VSOCK directly. A
connection must come from the kanbei guest CID and its first line must carry the shared
root-only relay token, so a bare vsock dial gets `ERR` and nothing else. The relay then
opens a second connection to the search guest's Firecracker `notify.vsock`
(`CONNECT 7024`) and pipes bytes both ways. It never parses or logs payload; it logs
connection metadata and byte counts only.

A failed upstream dial closes Kanbei's connection without a response, so a dead search
guest reads to the client as a broken channel rather than an empty result.
"""

from __future__ import annotations

import argparse
import json
import os
import selectors
import socket
import sys
import time
from datetime import datetime, timezone

import relay_auth

CONNECT_TIMEOUT = 30.0
PIPE_TIMEOUT = 120.0
CHUNK = 65536
VMADDR_CID_ANY = 0xFFFFFFFF
KANBEI_CID = 4


def log(event: str, **fields: object) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unit": "search-relay",
        "event": event,
    }
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def connect_vsock(uds_path: str, port: int, timeout: float = CONNECT_TIMEOUT) -> socket.socket:
    """Ask Firecracker for a connection to the guest's vsock listener."""
    deadline = time.monotonic() + timeout
    while True:
        if os.path.exists(uds_path):
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(10)
            try:
                sock.connect(uds_path)
                sock.sendall(f"CONNECT {port}\n".encode())
                data = b""
                while not data.endswith(b"\n") and len(data) < 256:
                    chunk = sock.recv(256)
                    if not chunk:
                        break
                    data += chunk
                text = data.decode("utf-8", "replace").strip()
                if not text.startswith("OK ") or not text[3:].strip().isdigit():
                    raise ConnectionError(f"vsock refused CONNECT {port}: {text!r}")
                sock.settimeout(None)
                return sock
            except (ConnectionError, OSError):
                sock.close()
                raise
        if time.monotonic() >= deadline:
            raise TimeoutError(f"{uds_path} did not answer CONNECT {port}")
        time.sleep(0.5)


def pipe(left: socket.socket, right: socket.socket) -> tuple[int, int]:
    """Copy until either side closes. Returns (client->guest, guest->client) bytes."""
    selector = selectors.DefaultSelector()
    selector.register(left, selectors.EVENT_READ, "left")
    selector.register(right, selectors.EVENT_READ, "right")
    forward = 0
    backward = 0
    deadline = time.monotonic() + PIPE_TIMEOUT
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                log("timeout", forward=forward, backward=backward)
                return forward, backward
            for key, _ in selector.select(timeout=remaining):
                source = key.fileobj
                target = right if key.data == "left" else left
                chunk = source.recv(CHUNK)
                if not chunk:
                    return forward, backward
                target.sendall(chunk)
                if key.data == "left":
                    forward += len(chunk)
                else:
                    backward += len(chunk)
    finally:
        selector.close()


def handle(
    conn: socket.socket,
    vsock: str,
    port: int,
    token: bytes,
    expected_cid: int | None = None,
) -> None:
    """Serve one connection: peer gate, token gate, then splice to the search guest."""
    conn.settimeout(CONNECT_TIMEOUT)
    try:
        if expected_cid is not None:
            relay_auth.require_peer(conn, expected_cid)
        relay_auth.verify(conn, token)
    except relay_auth.AuthError as exc:
        log("reject", reason=str(exc))
        try:
            conn.sendall(b"ERR\n")
        except OSError:
            pass
        return
    try:
        upstream = connect_vsock(vsock, port)
    except (ConnectionError, OSError, TimeoutError) as exc:
        log("upstream-error", reason=str(exc))
        return
    with upstream:
        try:
            forward, backward = pipe(conn, upstream)
        except OSError as exc:
            log("pipe-error", reason=str(exc))
            return
        log("closed", forward=forward, backward=backward)


def serve(
    port: int,
    vsock: str,
    guest_port: int,
    token: bytes,
    expected_cid: int = KANBEI_CID,
) -> None:
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((VMADDR_CID_ANY, port))
    server.listen(4)
    log("listen", port=port, vsock=vsock, guest_port=guest_port, peer_cid=expected_cid)
    while True:
        conn, peer = server.accept()
        with conn:
            log("connection", peer_cid=peer[0])
            handle(conn, vsock, guest_port, token, expected_cid)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="search-relay")
    parser.add_argument("--port", type=int, required=True, help="host AF_VSOCK port")
    parser.add_argument("--vsock", required=True, help="search guest notify.vsock path")
    parser.add_argument("--guest-port", type=int, required=True, help="search guest query port")
    parser.add_argument("--token-file", required=True, help="root-only relay token")
    parser.add_argument(
        "--peer-cid", type=int, default=KANBEI_CID, help="the only guest CID allowed"
    )
    args = parser.parse_args(argv)
    try:
        token = relay_auth.read_token(args.token_file)
    except relay_auth.AuthError as exc:
        print(f"search-relay: {exc}", file=sys.stderr)
        return 2
    serve(args.port, args.vsock, args.guest_port, token, args.peer_cid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
