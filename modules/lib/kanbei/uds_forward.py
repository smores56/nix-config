#!/usr/bin/env python3
"""AF_UNIX-to-AF_VSOCK forwarder for a Kanbei guest channel.

The agent dials a fixed AF_UNIX path (`KANBEI_CSR_SOCKET`, `KANBEI_SEARCH_SOCKET`), but
the host listener is an AF_VSOCK socket on CID 2. Deno has no UDS-to-vsock bridge, so this
process accepts each UDS connection and splices it byte-for-byte into a fresh vsock
connection. It never parses the channel protocol: the agent already writes the relay-token
line and the framed request itself.

It runs as the kernel uid in the guest and creates the socket 0600, so a later sandbox
running as the payload uid cannot reach the host channel without going through the kernel.
Under systemd it signals readiness only after the socket is bound, and every corresponding
`kanbei.service` is ordered after it.
"""

from __future__ import annotations

import argparse
import functools
import os
import selectors
import socket
import sys
import threading

CHUNK = 64 * 1024
VMADDR_CID_HOST = 2


def connect_vsock(cid: int, port: int, timeout: float = 10.0) -> socket.socket:
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((cid, port))
    except OSError:
        sock.close()
        raise
    sock.settimeout(None)
    return sock


def pipe(left: socket.socket, right: socket.socket) -> None:
    """Splice two connected sockets until both directions close."""
    selector = selectors.DefaultSelector()
    selector.register(left, selectors.EVENT_READ, right)
    selector.register(right, selectors.EVENT_READ, left)
    open_reads = {left, right}
    try:
        while open_reads:
            for key, _events in selector.select(timeout=30.0):
                source = key.fileobj
                target = key.data
                try:
                    data = source.recv(CHUNK)
                except OSError:
                    data = b""
                if not data:
                    open_reads.discard(source)
                    selector.unregister(source)
                    try:
                        target.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    continue
                try:
                    target.sendall(data)
                except OSError:
                    open_reads.discard(source)
                    open_reads.discard(target)
                    for sock in (source, target):
                        try:
                            selector.unregister(sock)
                        except (KeyError, ValueError):
                            pass
                    break
    finally:
        selector.close()


def handle(conn: socket.socket, connect) -> None:
    try:
        upstream = connect()
    except OSError as exc:
        print(f"kanbei-forward: vsock connect failed: {exc}", file=sys.stderr)
        conn.close()
        return
    try:
        pipe(conn, upstream)
    finally:
        for sock in (conn, upstream):
            try:
                sock.close()
            except OSError:
                pass


def serve(listener: socket.socket, connect, stop: threading.Event | None = None) -> None:
    listener.settimeout(0.5)
    while stop is None or not stop.is_set():
        try:
            conn, _peer = listener.accept()
        except TimeoutError:
            continue
        except OSError:
            if stop is not None and stop.is_set():
                return
            raise
        conn.settimeout(None)
        threading.Thread(target=handle, args=(conn, connect), daemon=True).start()


def listen_uds(path: str) -> socket.socket:
    """Bind the guest-side socket; a restart replaces the previous run's path."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    os.chmod(path, 0o600)
    listener.listen(16)
    return listener


def notify(message: str = "READY=1") -> None:
    """sd_notify without a dependency: systemd hands the datagram address in the env."""
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(address)
        sock.sendall(message.encode("ascii"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", required=True, help="guest-side AF_UNIX path")
    parser.add_argument("--vsock-cid", type=int, default=VMADDR_CID_HOST, help="2 = host")
    parser.add_argument("--vsock-port", type=int, required=True)
    args = parser.parse_args(argv)

    listener = listen_uds(args.listen)
    notify()
    print(
        f"kanbei-forward: {args.listen} -> vsock {args.vsock_cid}:{args.vsock_port}",
        file=sys.stderr,
    )
    serve(listener, functools.partial(connect_vsock, args.vsock_cid, args.vsock_port))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
