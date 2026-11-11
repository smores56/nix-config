"""Host-side relay from Kanbei's vsock port to the search guest's query port.

Kanbei dials host CID 2 on port 7101; Firecracker forwards that connection to this
AF_UNIX listener, which opens a second connection to the search guest's
Firecracker `notify.vsock` (`CONNECT 7024`) and pipes bytes both ways. The relay
never parses or logs payload; it logs connection metadata and byte counts only.

A failed upstream dial closes Kanbei's connection without a response, so a dead
search guest reads to the client as a broken channel rather than an empty result.
"""

from __future__ import annotations

import argparse
import grp
import json
import os
import selectors
import socket
import sys
import time
from datetime import datetime, timezone

CONNECT_TIMEOUT = 30.0
PIPE_TIMEOUT = 120.0
CHUNK = 65536


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


def serve(uds: str, vsock: str, port: int, group: str = "kvm") -> None:
    directory = os.path.dirname(uds)
    if not os.path.isdir(directory):
        raise SystemExit(f"search-relay: {directory} is missing; the Kanbei guest is not installed")
    try:
        os.unlink(uds)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(uds)
    # Firecracker (microvm:kvm) dials this socket to forward the guest connection.
    os.chmod(uds, 0o660)
    if group:
        os.chown(uds, 0, grp.getgrnam(group).gr_gid)
    server.listen(4)
    log("listen", path=uds, vsock=vsock, port=port)
    while True:
        conn, _ = server.accept()
        with conn:
            try:
                upstream = connect_vsock(vsock, port)
            except (ConnectionError, OSError, TimeoutError) as exc:
                log("upstream-error", reason=str(exc))
                continue
            with upstream:
                try:
                    forward, backward = pipe(conn, upstream)
                except OSError as exc:
                    log("pipe-error", reason=str(exc))
                    continue
                log("closed", forward=forward, backward=backward)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="search-relay")
    parser.add_argument("--uds", required=True)
    parser.add_argument("--vsock", required=True, help="search guest notify.vsock path")
    parser.add_argument("--port", type=int, required=True, help="search guest query port")
    parser.add_argument("--group", default="kvm", help="group allowed to connect (Firecracker)")
    args = parser.parse_args(argv)
    serve(args.uds, args.vsock, args.port, args.group)
    return 0


if __name__ == "__main__":
    sys.exit(main())
