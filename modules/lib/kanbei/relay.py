#!/usr/bin/env python3
"""TCP-to-vsock pipe for the Kanbei chat channel.

The host tunnel (cloudflared) resolves the private hostname to loopback and connects to
the systemd socket unit on 127.0.0.1:443. This process accepts that TCP stream and splices
it byte-for-byte into an AF_VSOCK connection to the guest, where TLS terminates. It never
parses HTTP, holds no key material, and runs as the unprivileged ``kanbei-relay`` user.

The systemd socket unit performs the privileged bind and hands the listening descriptor in
``LISTEN_FDS``; ``--listen`` exists for tests and manual debugging only.

The first bytes written to the guest are the relay token line (``KANBEI-AUTH 1 <token>``,
read from a root-only systemd credential) before any client byte, so the guest's TLS
listener can require it on the raw stream and a bare vsock connection gets nothing.
"""

from __future__ import annotations

import argparse
import functools
import os
import selectors
import socket
import sys
import threading

import relay_auth

CHUNK = 64 * 1024
VMADDR_CID_HOST = 2


def systemd_listener() -> socket.socket | None:
    """Return the socket-activation listener, or None outside systemd."""
    fds = os.environ.get("LISTEN_FDS", "")
    pid = os.environ.get("LISTEN_PID", "")
    if fds != "1" or pid != str(os.getpid()):
        return None
    # sd_listen_fds moves the first descriptor to fd 3 (LISTEN_FDS_START).
    return socket.socket(fileno=3)


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
                except (ConnectionResetError, OSError):
                    data = b""
                if not data:
                    open_reads.discard(source)
                    selector.unregister(source)
                    try:
                        target.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    # A half-closed peer may still have data to deliver; the loop ends when
                    # both directions have seen EOF.
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


def handle(conn: socket.socket, connect, token: bytes | None = None) -> None:
    try:
        upstream = connect()
    except OSError as exc:
        print(f"kanbei-relay: vsock connect failed: {exc}", file=sys.stderr)
        conn.close()
        return
    try:
        if token is not None:
            # First bytes on the guest stream, before any client byte: the guest's
            # TLS listener consumes this line from the raw socket.
            upstream.sendall(relay_auth.encode(token))
        pipe(conn, upstream)
    finally:
        for sock in (conn, upstream):
            try:
                sock.close()
            except OSError:
                pass


def serve(
    listener: socket.socket,
    connect,
    stop: threading.Event | None = None,
    token: bytes | None = None,
) -> None:
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
        threading.Thread(target=handle, args=(conn, connect, token), daemon=True).start()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsock-cid", type=int, default=4, help="guest CID (2 = host)")
    parser.add_argument("--vsock-port", type=int, required=True)
    parser.add_argument("--listen", help="host:port for a manual listener instead of systemd")
    parser.add_argument("--token-file", help="root-only relay token credential")
    args = parser.parse_args(argv)

    listener = systemd_listener()
    token = None
    if args.token_file:
        try:
            token = relay_auth.read_token(args.token_file)
        except relay_auth.AuthError as exc:
            print(f"kanbei-relay: {exc}", file=sys.stderr)
            return 2
    # Socket activation means production: never splice an unauthenticated stream to the guest.
    if listener is not None and token is None:
        print("kanbei-relay: --token-file is required under socket activation", file=sys.stderr)
        return 2
    if listener is None:
        if not args.listen:
            print("kanbei-relay: no socket activation and no --listen", file=sys.stderr)
            return 2
        host, _, port = args.listen.rpartition(":")
        listener = socket.create_server((host or "127.0.0.1", int(port)))
    connect = functools.partial(connect_vsock, args.vsock_cid, args.vsock_port)
    print(
        f"kanbei-relay: forwarding to vsock {args.vsock_cid}:{args.vsock_port}",
        file=sys.stderr,
    )
    serve(listener, connect, token=token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
