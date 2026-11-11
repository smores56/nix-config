"""Shared root-only token handshake for every host-side Kanbei vsock channel.

Each listener a guest can dial (the chat relay, the ACME responder, the age-recipient
listener and the search relay) requires the first line of the raw stream to be
``KANBEI-AUTH 1 <token>\\n``. The token is a root-only systemd credential on the host and
the same file on the guest's read-only ``kanbei-secrets`` share, so a bare AF_VSOCK
connection from any CID cannot use the channel. The comparison is constant time and a
missing, short or whitespace-bearing token is a configuration error, never a bypass.

The handshake runs *before* TLS on the chat channel: the relay writes this line first and
the guest's TLS server consumes it from the raw socket before wrapping the connection.
"""

from __future__ import annotations

import hmac
import os
import re
import socket

PREFIX = b"KANBEI-AUTH 1 "
MAX_LINE = 512
TOKEN_PATTERN = re.compile(r"\A[A-Za-z0-9._-]{32,128}\Z")


class AuthError(Exception):
    """The token file, the peer, or the presented line failed the handshake."""


def read_token(path: str) -> bytes:
    """Read and validate a token file; raise instead of falling back to no auth."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise AuthError(f"token file {path} is unreadable: {exc}") from exc
    token = text.strip()
    if not TOKEN_PATTERN.match(token):
        raise AuthError(f"token file {path} does not hold a 32..128 character token")
    return token.encode("utf-8")


def encode(token: bytes) -> bytes:
    """The exact first line a peer must send."""
    return PREFIX + token + b"\n"


def read_line(conn: socket.socket, max_line: int = MAX_LINE) -> bytes:
    """Read one newline-terminated line without consuming bytes past it.

    One byte at a time on purpose: the remainder of the stream is either a TLS
    ClientHello or a protocol frame and must stay in the kernel buffer.
    """
    buf = bytearray()
    while len(buf) < max_line:
        chunk = conn.recv(1)
        if not chunk:
            raise AuthError("peer closed before the auth line")
        if chunk == b"\n":
            return bytes(buf)
        buf += chunk
    raise AuthError("auth line is longer than the channel allows")


def matches(line: bytes, token: bytes) -> bool:
    """Constant-time comparison of a presented line against the expected frame."""
    return hmac.compare_digest(line + b"\n", encode(token))


def verify(conn: socket.socket, token: bytes, max_line: int = MAX_LINE) -> None:
    """Consume the first line and raise :class:`AuthError` unless it is the token."""
    line = read_line(conn, max_line)
    if not matches(line, token):
        raise AuthError("auth line does not match the host token")


def peer_cid(conn: socket.socket) -> int | None:
    """The AF_VSOCK peer CID, or ``None`` when the socket is not a vsock."""
    try:
        return conn.getpeername()[0]
    except (OSError, IndexError, TypeError):
        return None


def require_peer(conn: socket.socket, cid: int) -> None:
    """Raise unless the connection comes from exactly ``cid``."""
    actual = peer_cid(conn)
    if actual != cid:
        raise AuthError(f"peer cid {actual!r} is not the expected {cid}")


def token_from_environment(variable: str) -> bytes:
    """A token handed on the service's stdin environment (tests and manual runs only)."""
    value = os.environ.get(variable, "").strip()
    if not TOKEN_PATTERN.match(value):
        raise AuthError(f"${variable} does not hold a 32..128 character token")
    return value.encode("utf-8")
