"""Loopback OpenAI-compatible gateway in front of Graphiti's model providers.

What it adds, per instance configuration; everything else is relayed:

- the account key: the gateway always sends `Authorization: Bearer <key>`;
  Graphiti's placeholder `Bearer none` and any other caller credential are
  replaced. A missing or empty key fails startup, so the unit fails visibly
  instead of serving unauthenticated calls.
- `reasoning_effort` on chat completions, only when `MEMORY_LLM_REASONING_EFFORT`
  names one: a reasoning model otherwise spends the whole max_tokens budget on
  extraction and returns empty content that Graphiti drops, and graphiti-core
  cannot set the field per request.
- `MEMORY_LLM_CHAT_BACKEND=claude` serves chat completions from headless Claude
  Code (`claude_chat`) instead of the upstream; embeddings and the model list
  still go upstream.

Two behaviours Graphiti's requests depend on, kept on purpose: the upstream
allows a few concurrent slots, so extraction (chat completions) holds
one of `MEMORY_UPSTREAM_CONCURRENCY` permits for the whole call
(Graphiti's own semaphore bounds only one fan-out, not the process), and a 429 or
503, which never ran, is retried up to `MEMORY_UPSTREAM_RETRIES` attempts,
honouring a numeric `Retry-After`, because one rejected extraction call otherwise
drops the whole episode. Embeddings and the model list run in their own lane so
search and readiness stay answerable while the extraction queue drains.

Only the routes Graphiti and the readiness probe use are forwarded
(`POST /v1/chat/completions`, `POST /v1/embeddings`, `GET /v1/models`), request
bodies are capped at `MAX_REQUEST_BYTES`, and upstream replies are buffered
(Graphiti never streams), so no caller-chosen request can pin a connection. The
caller's `Authorization` is always replaced with the account key.

`/health` is a local liveness answer; check upstream access through `/v1/models`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import claude_chat

logger = logging.getLogger("memory-mcp.llm-proxy")

DEFAULT_UPSTREAM = "https://api.neuralwatt.com"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8082
DEFAULT_TIMEOUT = 600.0
# The key file is per instance (a systemd credential or a sops path); there is no default.
KEY_FILE_ENV = "MEMORY_LLM_KEY_FILE"
REASONING_EFFORT_ENV = "MEMORY_LLM_REASONING_EFFORT"
CHAT_BACKEND_ENV = "MEMORY_LLM_CHAT_BACKEND"
CHAT_BACKENDS = ("upstream", "claude")
ALLOWED_HOSTS_ENV = "MEMORY_LLM_PROXY_ALLOWED_HOSTS"
# A browser page or a DNS-rebinding name must not be able to spend the account's key; callers are
# local processes that dial one of these names.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "[::1]"})
# A stalled upstream must not hold a connection forever.
DEFAULT_READ_TIMEOUT = 300.0
DEFAULT_CONNECT_TIMEOUT = 10.0
# Bounds a caller's memory use; Graphiti's largest prompt is far below it.
MAX_REQUEST_BYTES = 10 * 1024 * 1024
CHAT_PATH = "/v1/chat/completions"
EMBEDDINGS_PATH = "/v1/embeddings"
MODELS_PATH = "/v1/models"
ALLOWED_ROUTES = {CHAT_PATH: "POST", EMBEDDINGS_PATH: "POST", MODELS_PATH: "GET"}
# Graphiti's SEMAPHORE_LIMIT only bounds its own queue; this bounds the process. Two leaves a slot
# of a three-slot tier free for interactive use and keeps two `claude -p` children at most.
DEFAULT_UPSTREAM_CONCURRENCY = 2
# Embeddings and the model list are short and run beside extraction, one at a time.
LIGHT_LANE_CONCURRENCY = 1
UPSTREAM_CONCURRENCY_ENV = "MEMORY_UPSTREAM_CONCURRENCY"
# Attempts, not retries: covers a burst of 429s without outliving the caller's read deadline.
DEFAULT_UPSTREAM_RETRIES = 6
UPSTREAM_RETRIES_ENV = "MEMORY_UPSTREAM_RETRIES"
# Rejections only: a 429 or 503 never ran, so replay cannot duplicate work.
RETRY_STATUSES = frozenset({429, 503})
# A minutes-long `Retry-After` would outlast the read deadline and hold a permit for nothing.
MAX_RETRY_AFTER = 60.0
RETRY_BACKOFF_BASE = 1.0
RETRY_BACKOFF_CAP = 30.0

# Connection-scoped headers terminate at each hop. Request content-length is stale once a
# chat body is rewritten, and httpx decodes the reply, so its encoding and length are stale too.
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }
)
REQUEST_STRIP = HOP_BY_HOP | {"host", "content-length", "authorization"}
RESPONSE_STRIP = HOP_BY_HOP | {"content-length", "content-encoding"}


def inject_reasoning_effort(body: bytes, effort: str) -> bytes:
    """Add `reasoning_effort` to a chat-completion body unless it is already set.

    Anything that is not a JSON object is forwarded byte-for-byte, and an
    explicit effort is never overridden.
    """
    try:
        payload: Any = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body
    if not isinstance(payload, dict) or payload.get("reasoning_effort") is not None:
        return body
    payload["reasoning_effort"] = effort
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_api_key(*, api_key: str | None = None, key_file: str | None = None) -> str:
    """The upstream key from `api_key` (test seam), `key_file`, `MEMORY_LLM_KEY_FILE`."""
    if api_key is not None:
        key = api_key.strip()
    else:
        configured = key_file or os.environ.get(KEY_FILE_ENV)
        if not configured:
            raise MissingKeyError(f"no LLM API key file configured ({KEY_FILE_ENV})")
        path = Path(configured)
        try:
            key = path.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise MissingKeyError(f"cannot read the LLM API key at {path}: {exc}") from exc
    if not key:
        raise MissingKeyError("the LLM API key is empty")
    return key


def _request_headers(request: Request, api_key: str) -> dict[str, str]:
    headers = {key: value for key, value in request.headers.items() if key.lower() not in REQUEST_STRIP}
    headers["authorization"] = f"Bearer {api_key}"
    return headers


def _response_headers(response: httpx.Response) -> dict[str, str]:
    return {key: value for key, value in response.headers.items() if key.lower() not in RESPONSE_STRIP}


class MissingKeyError(RuntimeError):
    """No usable upstream API key is configured."""


def _env_int(name: str, default: int) -> int:
    return max(1, int(os.environ.get(name) or default))


def _retry_after_seconds(value: str | None, *, cap: float = MAX_RETRY_AFTER) -> float | None:
    """A numeric `Retry-After` in `[0, cap]` seconds, or None for anything else."""
    try:
        return min(max(float(value), 0.0), cap)
    except (TypeError, ValueError):
        return None


def _backoff_seconds(attempt: int, *, base: float = RETRY_BACKOFF_BASE, cap: float = RETRY_BACKOFF_CAP) -> float:
    """Jittered exponential backoff for retry `attempt` (0-based).

    Half the window is fixed and half is random, so a burst of clients hitting
    the same 429 does not retry in lockstep and re-trigger it.
    """
    ceiling = min(cap, base * 2**attempt)
    return ceiling / 2 + random.uniform(0.0, ceiling / 2)


def create_app(
    *,
    upstream: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    timeout: float = DEFAULT_TIMEOUT,
    read_timeout: float = DEFAULT_READ_TIMEOUT,
    api_key: str | None = None,
    key_file: str | None = None,
    upstream_concurrency: int | None = None,
    upstream_retries: int | None = None,
    reasoning_effort: str | None = None,
    chat_backend: str | None = None,
    claude: claude_chat.ClaudeConfig | None = None,
    allowed_hosts: tuple[str, ...] | None = None,
) -> Starlette:
    base_url = (upstream or os.environ.get("MEMORY_LLM_UPSTREAM", DEFAULT_UPSTREAM)).rstrip("/")
    concurrency = upstream_concurrency or _env_int(UPSTREAM_CONCURRENCY_ENV, DEFAULT_UPSTREAM_CONCURRENCY)
    retries = upstream_retries or _env_int(UPSTREAM_RETRIES_ENV, DEFAULT_UPSTREAM_RETRIES)
    effort = (os.environ.get(REASONING_EFFORT_ENV, "") if reasoning_effort is None else reasoning_effort).strip()
    backend = chat_backend or os.environ.get(CHAT_BACKEND_ENV) or "upstream"
    if backend not in CHAT_BACKENDS:
        raise ValueError(f"{CHAT_BACKEND_ENV} must be one of {CHAT_BACKENDS}, not {backend!r}")
    claude_config = (claude or claude_chat.config_from_env()) if backend == "claude" else None
    if claude_config is not None:
        claude_chat.check_binary(claude_config)
    extra_hosts = (
        allowed_hosts
        if allowed_hosts is not None
        else tuple(h for h in os.environ.get(ALLOWED_HOSTS_ENV, "").split(",") if h.strip())
    )
    hosts = LOOPBACK_HOSTS | {h.strip().lower() for h in extra_hosts}
    # Per app, so two apps in one process (tests) do not share permits.
    extraction_lane = asyncio.Semaphore(concurrency)
    light_lane = asyncio.Semaphore(LIGHT_LANE_CONCURRENCY)
    # Read once: a rotation restarts the unit.
    resolved_key = load_api_key(api_key=api_key, key_file=key_file)
    client = httpx.AsyncClient(
        base_url=base_url,
        timeout=httpx.Timeout(timeout, connect=DEFAULT_CONNECT_TIMEOUT, read=read_timeout),
        follow_redirects=False,
        transport=transport,
    )

    @asynccontextmanager
    async def lifespan(_app: Starlette) -> AsyncIterator[None]:
        try:
            yield
        finally:
            await client.aclose()

    async def health(_request: Request) -> JSONResponse:
        # Local answer: readiness fails when this process is gone, not while the chat model loads. `/v1/models` probes upstream.
        return JSONResponse(
            {"status": "ok", "service": "memory-llm-proxy", "scope": "local"}
        )

    async def read_body(request: Request) -> bytes | None:
        """Read at most `MAX_REQUEST_BYTES`, or None when the body is larger."""
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > MAX_REQUEST_BYTES:
            return None
        chunks: list[bytes] = []
        total = 0
        async for chunk in request.stream():
            total += len(chunk)
            if total > MAX_REQUEST_BYTES:
                return None
            chunks.append(chunk)
        return b"".join(chunks)

    async def send(request: Request, body: bytes) -> httpx.Response:
        """Forward one buffered request, retrying only a rejection.

        The permit covers one upstream call and is released before backing off, so
        sleeping never blocks the other slots.
        """
        lane = extraction_lane if request.url.path == CHAT_PATH else light_lane
        headers = _request_headers(request, resolved_key)
        for attempt in range(retries):
            async with lane:
                upstream_response = await client.request(
                    request.method,
                    request.url.path,
                    params=request.url.query,
                    headers=headers,
                    content=body,
                )
            if upstream_response.status_code not in RETRY_STATUSES or attempt + 1 >= retries:
                return upstream_response
            delay = _retry_after_seconds(upstream_response.headers.get("retry-after"))
            if delay is None:
                delay = _backoff_seconds(attempt)
            logger.warning(
                "upstream %s %s returned %d (attempt %d/%d); retrying in %.1fs",
                request.method,
                request.url.path,
                upstream_response.status_code,
                attempt + 1,
                retries,
                delay,
            )
            await asyncio.sleep(delay)
        raise AssertionError("retry loop fell through")  # unreachable: the last attempt returns

    def error(status: int, kind: str, message: str) -> JSONResponse:
        return JSONResponse({"error": {"message": message, "type": kind}}, status_code=status)

    async def chat_via_claude(config: claude_chat.ClaudeConfig, body: bytes) -> Response:
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = None
        if not isinstance(payload, dict):
            return error(400, "invalid_request", "the chat body must be a JSON object")
        try:
            async with extraction_lane:
                reply = await claude_chat.complete(config, payload)
        except claude_chat.ClaudeTimeout as exc:
            return error(504, "claude_timeout", str(exc))
        except claude_chat.ClaudeError as exc:
            logger.warning("claude chat failed: %s", exc)
            return error(502, "claude_failed", str(exc))
        return JSONResponse(reply)

    async def proxy(request: Request) -> Response:
        expected = ALLOWED_ROUTES.get(request.url.path)
        if expected is None:
            return error(404, "not_found", f"{request.url.path} is not forwarded")
        if request.method != expected:
            return error(405, "method_not_allowed", f"{request.url.path} takes {expected}")
        body = await read_body(request)
        if body is None:
            return error(413, "request_too_large", f"request body exceeds {MAX_REQUEST_BYTES} bytes")
        if request.url.path == CHAT_PATH:
            if claude_config is not None:
                return await chat_via_claude(claude_config, body)
            if effort:
                body = inject_reasoning_effort(body, effort)
        try:
            upstream_response = await send(request, body)
        except httpx.TimeoutException as exc:
            return error(504, "upstream_timeout", f"upstream {base_url} timed out: {type(exc).__name__}")
        except httpx.HTTPError as exc:
            return error(502, "upstream_unavailable", f"upstream {base_url} unavailable: {type(exc).__name__}")
        return Response(
            upstream_response.content,
            status_code=upstream_response.status_code,
            headers=_response_headers(upstream_response),
        )

    def host_name(header: str) -> str:
        value = header.strip().lower()
        if value.startswith("["):
            return value[: value.find("]") + 1]
        return value.partition(":")[0]

    async def guard(request: Request, call_next):
        if "origin" in request.headers:
            return error(403, "forbidden", "browser requests are not served")
        if host_name(request.headers.get("host", "")) not in hosts:
            return error(403, "forbidden", "unexpected Host header")
        return await call_next(request)

    app = Starlette(
        middleware=[Middleware(BaseHTTPMiddleware, dispatch=guard)],
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/{path:path}", proxy, methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]),
        ],
        lifespan=lifespan,
    )
    # Exposed so tests can close it; the server closes it on shutdown.
    app.state.client = client
    # Visible to tests and operators instead of buried in the environment.
    app.state.upstream_concurrency = concurrency
    app.state.upstream_retries = retries
    app.state.chat_backend = backend
    return app


def main() -> int:
    import uvicorn

    host = os.environ.get("MEMORY_LLM_PROXY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("MEMORY_LLM_PROXY_PORT", DEFAULT_PORT))
    try:
        app = create_app()
    except (MissingKeyError, claude_chat.ClaudeError) as exc:
        raise SystemExit(f"memory-llm-proxy: {exc}") from exc
    uvicorn.run(app, host=host, port=port, log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
