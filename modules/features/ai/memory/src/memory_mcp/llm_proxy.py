"""Loopback OpenAI-compatible gateway in front of Neuralwatt.

Two request rewrites, everything else is relayed:

- the account key: the gateway sends `Authorization: Bearer <key>` when the
  caller sent none or Graphiti's placeholder `Bearer none`; a real client
  credential is never overridden. A missing or empty key fails startup, so the
  unit fails visibly instead of serving unauthenticated calls.
- `reasoning_effort: "none"` on chat completions: a reasoning model spends the
  whole max_tokens budget on extraction and returns empty content that Graphiti
  drops, and graphiti-core cannot set the field per request.

Two behaviours Graphiti's requests depend on, kept on purpose: the account's tier
allows three concurrent upstream slots, so a permit is held for the whole
upstream request (`MEMORY_UPSTREAM_CONCURRENCY`; Graphiti's own semaphore bounds
only one fan-out, not the process), and a 429 or 503, which never ran, is retried
up to `MEMORY_UPSTREAM_RETRIES` attempts, honouring a numeric `Retry-After`,
because one rejected extraction call otherwise drops the whole episode.

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
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

logger = logging.getLogger("memory-mcp.llm-proxy")

DEFAULT_UPSTREAM = "https://api.neuralwatt.com"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8082
DEFAULT_TIMEOUT = 600.0
# systemd LoadCredential drops the sops secret here; MEMORY_NEURALWATT_KEY_FILE points at it.
DEFAULT_KEY_FILE = "/run/secrets/neuralwatt-api-key"
KEY_FILE_ENV = "MEMORY_NEURALWATT_KEY_FILE"
# A stalled upstream (even mid-stream) must not hold a connection forever.
DEFAULT_READ_TIMEOUT = 300.0
DEFAULT_CONNECT_TIMEOUT = 10.0
CHAT_COMPLETION_PATHS = frozenset({"/v1/chat/completions", "/chat/completions"})
REASONING_EFFORT = "none"
# Graphiti requires a non-empty `api_key`, so it sends the placeholder "none"; the gateway replaces it.
PLACEHOLDER_BEARERS = frozenset({"", "none"})
# The PAYG tier has three slots and maki's chat shares the key; two leaves one for interactive use.
# Graphiti's SEMAPHORE_LIMIT only bounds its own queue.
DEFAULT_UPSTREAM_CONCURRENCY = 2
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
# chat body is rewritten; upstream length is left to the server when streaming.
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
REQUEST_STRIP = HOP_BY_HOP | {"host", "content-length"}
RESPONSE_STRIP = HOP_BY_HOP | {"content-length"}


def inject_thinking_off(body: bytes) -> bytes:
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
    payload["reasoning_effort"] = REASONING_EFFORT
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_api_key(*, api_key: str | None = None, key_file: str | None = None) -> str:
    """The Neuralwatt key from `api_key` (test seam), `key_file`, `MEMORY_NEURALWATT_KEY_FILE`, or the default path."""
    if api_key is not None:
        key = api_key.strip()
    else:
        path = Path(key_file or os.environ.get(KEY_FILE_ENV, DEFAULT_KEY_FILE))
        try:
            key = path.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise MissingKeyError(f"cannot read the Neuralwatt API key at {path}: {exc}") from exc
    if not key:
        raise MissingKeyError("the Neuralwatt API key is empty")
    return key


def _is_placeholder_authorization(value: str) -> bool:
    scheme, _, token = value.partition(" ")
    return scheme.lower() == "bearer" and token.strip().lower() in PLACEHOLDER_BEARERS


def _request_headers(request: Request, api_key: str) -> dict[str, str]:
    headers = {key: value for key, value in request.headers.items() if key.lower() not in REQUEST_STRIP}
    # A caller's own credential wins; silently swapping it would be surprising.
    authorization = next((value for key, value in headers.items() if key.lower() == "authorization"), None)
    if authorization is None or _is_placeholder_authorization(authorization):
        headers["authorization"] = f"Bearer {api_key}"
    return headers


def _response_headers(response: httpx.Response) -> dict[str, str]:
    return {key: value for key, value in response.headers.items() if key.lower() not in RESPONSE_STRIP}


class MissingKeyError(RuntimeError):
    """No usable Neuralwatt API key is configured."""


class _ReleasingStreamingResponse(StreamingResponse):
    """A proxied reply that gives its upstream slot back exactly once.

    The body iterator normally releases the slot in its `finally`, but a client
    that disconnects before the first iteration never runs it, and a leaked
    permit would silently shrink the tier for the life of the process. The
    release is idempotent, so both paths are safe.
    """

    def __init__(self, content: AsyncIterator[bytes], *, release, **kwargs: Any) -> None:
        super().__init__(content, **kwargs)
        self._release = release

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        try:
            await super().__call__(scope, receive, send)
        finally:
            self._release()


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


async def _sleep(seconds: float) -> None:
    await asyncio.sleep(seconds)


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
) -> Starlette:
    base_url = (upstream or os.environ.get("MEMORY_LLM_UPSTREAM", DEFAULT_UPSTREAM)).rstrip("/")
    concurrency = upstream_concurrency or _env_int(UPSTREAM_CONCURRENCY_ENV, DEFAULT_UPSTREAM_CONCURRENCY)
    retries = upstream_retries or _env_int(UPSTREAM_RETRIES_ENV, DEFAULT_UPSTREAM_RETRIES)
    # Per app, so two apps in one process (tests) do not share permits.
    upstream_slots = asyncio.Semaphore(concurrency)
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

    async def proxy(request: Request) -> Response:
        body = await request.body()
        if request.method == "POST" and request.url.path in CHAT_COMPLETION_PATHS:
            body = inject_thinking_off(body)

        upstream_request = client.build_request(
            request.method,
            request.url.path,
            params=request.url.query,
            headers=_request_headers(request, resolved_key),
            content=body,
        )

        # Released exactly once per response, by the body iterator or on early client disconnect.
        slot_released = False

        def release_slot() -> None:
            nonlocal slot_released
            if not slot_released:
                slot_released = True
                upstream_slots.release()

        async def open_upstream(upstream_request: httpx.Request) -> httpx.Response:
            """Send the request, retrying only a rejection, holding one slot.

            The permit is taken before the send and handed to the response
            body, so it covers the whole upstream request: a queued extraction
            calls no model slot until it actually has one. On a retryable
            status the response is closed and the permit released before
            backing off, so sleeping never blocks the other slots.
            """
            for attempt in range(retries):
                await upstream_slots.acquire()
                try:
                    upstream_response = await client.send(upstream_request, stream=True)
                except BaseException:
                    upstream_slots.release()
                    raise
                if upstream_response.status_code not in RETRY_STATUSES or attempt + 1 >= retries:
                    return upstream_response
                retry_after = upstream_response.headers.get("retry-after")
                delay = _retry_after_seconds(retry_after)
                if delay is None:
                    delay = _backoff_seconds(attempt)
                logger.warning(
                    "upstream %s %s returned %d (attempt %d/%d); retrying in %.1fs",
                    upstream_request.method,
                    upstream_request.url.path,
                    upstream_response.status_code,
                    attempt + 1,
                    retries,
                    delay,
                )
                # Nothing has reached the client yet, so a retry cannot follow a partial stream.
                await upstream_response.aclose()
                upstream_slots.release()
                await _sleep(delay)
            raise AssertionError("retry loop fell through")  # unreachable: last attempt returns

        upstream_response = await open_upstream(upstream_request)

        async def body_stream() -> AsyncIterator[bytes]:
            try:
                # Raw bytes: content-encoding is kept, so decoding here would corrupt the stream.
                async for chunk in upstream_response.aiter_raw():
                    yield chunk
            finally:
                await upstream_response.aclose()
                # The slot frees when the upstream request ends, not when headers arrive: a stream still holds it.
                release_slot()

        return _ReleasingStreamingResponse(
            body_stream(),
            release=release_slot,
            status_code=upstream_response.status_code,
            headers=_response_headers(upstream_response),
        )

    app = Starlette(
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
    return app


def main() -> int:
    import uvicorn

    host = os.environ.get("MEMORY_LLM_PROXY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("MEMORY_LLM_PROXY_PORT", DEFAULT_PORT))
    try:
        app = create_app()
    except MissingKeyError as exc:
        raise SystemExit(f"memory-llm-proxy: {exc}") from exc
    uvicorn.run(app, host=host, port=port, log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
