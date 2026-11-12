#!/usr/bin/env python3
"""Publish the guest's age recipient to the host ingest writer.

The host's `ingest-age-key` listener accepts connections from the kanbei guest CID only,
requires the shared relay-token line, then reads exactly one `age1...` line and answers
`OK`. Only the public recipient crosses vsock; the identity stays on the LUKS volume.
"""

from __future__ import annotations

import argparse
import re
import socket
import sys

import relay_auth

VMADDR_CID_HOST = 2
HOST_VSOCK_PORT = 7100
# The host validator (modules/lib/ingest/policy.py) accepts exactly this shape:
# `age1` plus 58 bech32 characters (52 data + 6 checksum).
AGE_RECIPIENT_RE = re.compile(r"\Aage1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}\Z")


class PublishError(RuntimeError):
    """The local recipient or the host's answer is unusable."""


def read_recipient(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = [line.strip() for line in handle if line.strip()]
    except OSError as exc:
        raise PublishError(f"recipient file {path} is unreadable: {exc}") from exc
    if len(lines) != 1 or not AGE_RECIPIENT_RE.match(lines[0]):
        raise PublishError(f"recipient file {path} does not hold one age1 X25519 recipient")
    return lines[0]


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


def read_line(conn: socket.socket, max_line: int = 16) -> bytes:
    data = b""
    while b"\n" not in data and len(data) < max_line:
        chunk = conn.recv(max_line - len(data))
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0]


def publish(recipient: str, token: bytes, connect) -> None:
    with connect() as conn:
        # One write keeps the token line and the recipient line in order on the wire.
        conn.sendall(relay_auth.encode(token) + recipient.encode("ascii") + b"\n")
        reply = read_line(conn)
    if reply != b"OK":
        raise PublishError(f"host refused the recipient: {reply.decode('ascii', 'replace')!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="kanbei-age-publish")
    parser.add_argument("--recipient-file", required=True)
    parser.add_argument("--token-file", required=True, help="root-only relay token")
    parser.add_argument("--vsock-cid", type=int, default=VMADDR_CID_HOST)
    parser.add_argument("--vsock-port", type=int, default=HOST_VSOCK_PORT)
    args = parser.parse_args(argv)
    try:
        token = relay_auth.read_token(args.token_file)
        recipient = read_recipient(args.recipient_file)
        publish(
            recipient,
            token,
            lambda: connect_vsock(args.vsock_cid, args.vsock_port),
        )
    except (relay_auth.AuthError, PublishError, OSError) as exc:
        print(f"kanbei-age-publish: {exc}", file=sys.stderr)
        return 1
    print(
        f"kanbei-age-publish: published recipient to vsock {args.vsock_cid}:{args.vsock_port}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
