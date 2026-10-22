"""Shared secret for the wrapper's internal (ingest) routes.

The tunnel forwards raw TCP to the wrapper's loopback port, so Starlette sees
`request.client.host == "127.0.0.1"` for every tunneled request and the loopback
check alone cannot tell a local ingest from an Access-authenticated MCP client.
The wrapper therefore mints a random token at startup, writes it into the state
directory with mode 0640 (the directory is 0750, owned by the service group),
and requires it as `Authorization: Bearer <token>` on `/internal/*`. The local
CLI runs as a member of that group and reads the same file.

The loopback check stays: it is defence in depth, not the boundary.
"""

from __future__ import annotations

import hmac
import os
import secrets
from pathlib import Path

TOKEN_NAME = "internal.token"
DEFAULT_TOKEN_FILE = "/var/lib/memory/internal.token"
TOKEN_FILE_ENV = "MEMORY_INTERNAL_TOKEN_FILE"
TOKEN_BYTES = 32
TOKEN_MODE = 0o640


class TokenError(RuntimeError):
    """The internal token is missing, unreadable, or empty."""


def token_path(state_dir: str | os.PathLike[str]) -> Path:
    return Path(state_dir) / TOKEN_NAME


def write_token(state_dir: str | os.PathLike[str], token: str | None = None) -> str:
    """Write a fresh token to the state directory and return it."""
    value = token or secrets.token_urlsafe(TOKEN_BYTES)
    path = token_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, TOKEN_MODE)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(value + "\n")
        # A permissive umask on the caller's side can only clear bits, never add
        # them, so the explicit chmod is only about a narrower umask case and
        # about the temp file's identity before the rename.
        os.chmod(temporary, TOKEN_MODE)
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return value


def read_token(path: str | os.PathLike[str] | None = None) -> str:
    """Read the token from `path`, `$MEMORY_INTERNAL_TOKEN_FILE`, or the default."""
    target = Path(path or os.environ.get(TOKEN_FILE_ENV) or DEFAULT_TOKEN_FILE).expanduser()
    try:
        value = target.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise TokenError(
            f"cannot read the memory internal token at {target}: {exc}; "
            "the user must be in the memory group"
        ) from exc
    if not value:
        raise TokenError(f"the memory internal token at {target} is empty")
    return value


def bearer_ok(header: str | None, token: str | None) -> bool:
    """Constant-time check of an `Authorization: Bearer <token>` header."""
    if not token:
        return False
    scheme, _, presented = (header or "").strip().partition(" ")
    if scheme.lower() != "bearer":
        return False
    presented = presented.strip()
    if not presented:
        return False
    return hmac.compare_digest(presented.encode("utf-8"), token.encode("utf-8"))
