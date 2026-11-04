"""Bearer-token gate for the memory MCP HTTP listener.

The Cloudflare Tunnel forwards raw TCP to the wrapper's loopback port, so every
tunneled client also reaches Starlette as `request.client.host == "127.0.0.1"`;
being on loopback is not an authority. Every request to the MCP listener
therefore has to carry `Authorization: Bearer <token>`, where the token is the
`memory-mcp-token` sops secret (`modules/nixos/secrets-common.nix`), rendered at
`/run/secrets/memory-mcp-token` root-owned and group-readable by `memory`. The
service, the user's shim, and the CLI all read that one file.

Fail closed: a missing, unreadable, or empty token file rejects every request
with 503, and a missing or mismatched header is a 401. The token is re-read per
request, so re-deploying the secret takes effect without a rebuild.

`/health` is exempt: it answers a static `{"status": "ok", "service":
"memory-mcp"}` with no state, no data, and no token-derived information, which
is what systemd and the readiness probes need from an unauthenticated caller.
"""

from __future__ import annotations

import hmac
import json
import os
import sys
from pathlib import Path
from typing import Any

from starlette.datastructures import Headers


DEFAULT_TOKEN_FILE = "/run/secrets/memory-mcp-token"
TOKEN_FILE_ENV = "MEMORY_MCP_TOKEN_FILE"
EXEMPT_PATHS = frozenset({"/health"})
CHALLENGE = 'Bearer realm="memory-mcp"'


class TokenMissingError(RuntimeError):
    """The MCP bearer token file is missing, unreadable, or empty."""


def token_path(path: str | os.PathLike[str] | None = None) -> Path:
    return Path(path or os.environ.get(TOKEN_FILE_ENV) or DEFAULT_TOKEN_FILE).expanduser()


def read_token(path: str | os.PathLike[str] | None = None) -> str:
    """Read the bearer token from `path`, `$MEMORY_MCP_TOKEN_FILE`, or the default."""
    target = token_path(path)
    try:
        value = target.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise TokenMissingError(
            f"cannot read the memory MCP token at {target}: {exc}; "
            "the caller must be able to read the memory-mcp-token sops secret"
        ) from exc
    if not value:
        raise TokenMissingError(f"the memory MCP token at {target} is empty")
    return value


def authorization(path: str | os.PathLike[str] | None = None) -> tuple[str, str]:
    """The header a client sends for the token at `path` (default: the secret)."""
    return ("Authorization", f"Bearer {read_token(path)}")


def bearer_ok(header: str | None, token: str | None) -> bool:
    """Constant-time check of an `Authorization: Bearer <token>` header."""
    if not token:
        return False
    scheme, _, presented = (header or "").strip().partition(" ")
    presented = presented.strip()
    if scheme.lower() != "bearer" or not presented:
        return False
    return hmac.compare_digest(presented.encode("utf-8"), token.encode("utf-8"))


async def _reject(send: Any, status: int, detail: str, *, challenge: bool = False) -> None:
    body = json.dumps({"error": detail}).encode()
    headers = [
        (b"content-type", b"application/json"),
        (b"content-length", str(len(body)).encode()),
        (b"connection", b"close"),
    ]
    if challenge:
        headers.append((b"www-authenticate", CHALLENGE.encode()))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


class BearerAuthMiddleware:
    """Require the MCP bearer token on every request that is not exempt.

    Authorization is decided before the body is read, so an unauthenticated
    caller never gets a request body buffered on its behalf. `token` is an
    explicit override used by tests; production leaves it `None` and reads the
    secret file on every request.
    """

    def __init__(
        self,
        app: Any,
        *,
        token: str | None = None,
        token_file: str | os.PathLike[str] | None = None,
        exempt: frozenset[str] = EXEMPT_PATHS,
    ) -> None:
        self.app = app
        self.token = token
        self.token_file = token_file
        self.exempt = exempt
        self._warned = False

    def _expected(self) -> str | None:
        if self.token is not None:
            return self.token
        try:
            return read_token(self.token_file)
        except TokenMissingError as exc:
            # One line, not one per request: a secret that is not deployed yet
            # must not turn every health check into log noise.
            if not self._warned:
                self._warned = True
                print(f"memory-mcp: rejecting requests: {exc}", file=sys.stderr)
            return None

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if scope.get("path") in self.exempt:
            await self.app(scope, receive, send)
            return
        expected = self._expected()
        if expected is None:
            await _reject(send, 503, "the memory MCP token is unavailable")
            return
        if not bearer_ok(Headers(scope=scope).get("authorization"), expected):
            await _reject(send, 401, "missing or invalid bearer token", challenge=True)
            return
        await self.app(scope, receive, send)
