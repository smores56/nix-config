"""Loopback OpenAI-compatible gateway in front of Neuralwatt.

Graphiti's generic OpenAI client sends no per-request thinking control, and a
reasoning model spends the whole max_tokens budget as reasoning on extraction,
returning empty content that Graphiti drops. This gateway adds
`reasoning_effort: "none"` to chat completions and leaves every other path
(models, embeddings, health, streaming) untouched.

It is also the single egress point for Neuralwatt: the account key comes from a
systemd credential (or `MEMORY_NEURALWATT_KEY_FILE`), and the gateway adds
`Authorization: Bearer …` when the caller sent none. Graphiti and the wrapper
stay key-less. A client-supplied credential is never overridden, but the
dummy `api_key: "none"` that Graphiti's YAML requires (sent upstream as
`Bearer none`) is treated as absent and replaced.

A missing or empty key does not crash the process: `/health` still answers so
the unit stays up, but every proxied request fails closed with a 503
configuration error instead of leaking an unauthenticated call upstream.

`/health` is a local liveness answer: it reports that this gateway is running,
not that Neuralwatt is reachable. Operators check upstream access through the
proxied `/v1/models` (see `docs/manual-steps.md`).

Request bodies are capped at `MAX_REQUEST_BYTES` (extraction prompts are large,
but a runaway or hostile client must not park gigabytes in memory), and reads
have their own deadline so a stalled upstream cannot pin a worker forever.

The account's PAYG tier allows three concurrent upstream slots, and Graphiti's
own in-flight limit is not the same thing: a permit is held here for as long as
the upstream request is open, including the streamed response body, so
`MEMORY_UPSTREAM_CONCURRENCY` is the real ceiling on upstream slots. Overrunning
it earns 429s that starve every queued extraction, so exceeding it is never
worth it.

A 429 (rate limited) or 503 (overloaded) is a rejection, not a result: the
request never ran, so it is safe to retry. Those two statuses are retried up to
`MEMORY_UPSTREAM_RETRIES` attempts, honouring `Retry-After` when present and
falling back to jittered exponential backoff. Every other status, including all
other 4xx, is returned unchanged, and nothing is retried once a response body
has been handed to the client.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
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
# systemd's LoadCredential drops the sops secret here; the unit points
# MEMORY_NEURALWATT_KEY_FILE at $CREDENTIALS_DIRECTORY instead.
DEFAULT_KEY_FILE = "/run/secrets/neuralwatt-api-key"
KEY_FILE_ENV = "MEMORY_NEURALWATT_KEY_FILE"
# A stalled upstream (no bytes, including during a stream) must not hold a
# connection forever. Long extraction streams still emit tokens well inside it.
DEFAULT_READ_TIMEOUT = 300.0
DEFAULT_CONNECT_TIMEOUT = 10.0
# Graphiti's largest extraction prompt is far below this; the cap bounds a
# hostile client's memory instead of the legitimate case.
MAX_REQUEST_BYTES = 10 * 1024 * 1024
CHAT_COMPLETION_PATHS = frozenset({"/v1/chat/completions", "/chat/completions"})
REASONING_EFFORT = "none"
# Graphiti's config requires a non-empty `api_key`, so it ships "none" and the
# OpenAI SDK forwards it as `Authorization: Bearer none`. That placeholder is no
# credential: the gateway replaces it instead of leaking it upstream.
PLACEHOLDER_BEARERS = frozenset({"", "none"})
# The PAYG tier has three concurrent slots and Maki's chat shares the key, so
# two leaves one of them for interactive use. This is the ceiling on real
# upstream slots; Graphiti's SEMAPHORE_LIMIT only bounds its own queue.
DEFAULT_UPSTREAM_CONCURRENCY = 2
UPSTREAM_CONCURRENCY_ENV = "MEMORY_UPSTREAM_CONCURRENCY"
# Attempts, not retries: one try plus five retries covers a burst of 429s with
# `Retry-After` without outliving the caller's own read deadline.
DEFAULT_UPSTREAM_RETRIES = 6
UPSTREAM_RETRIES_ENV = "MEMORY_UPSTREAM_RETRIES"
# Rejections only. A 429 or 503 means the request never ran, so replaying it
# cannot duplicate work; every other status is a real answer (or a client bug).
RETRY_STATUSES = frozenset({429, 503})
# An upstream `Retry-After` of minutes would park the request past the read
# deadline and hold a permit for nothing; one minute is already generous.
MAX_RETRY_AFTER = 60.0
RETRY_BACKOFF_BASE = 1.0
RETRY_BACKOFF_CAP = 30.0

# Connection-scoped headers are ours to terminate at each hop. The request
# content-length is stale once a chat body is rewritten, and the upstream
# length is left to the server when the response is streamed.
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

    Non-object JSON (rare, but legal) is forwarded byte-for-byte; an explicit
    effort, including `"none"`, is never overridden.
    """
    try:
        payload: Any = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError(f"request body is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        return body
    if payload.get("reasoning_effort") is not None:
        return body
    payload["reasoning_effort"] = REASONING_EFFORT
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_api_key(*, api_key: str | None = None, key_file: str | None = None) -> str | None:
    """The Neuralwatt key, or None when no usable credential is configured.

    `api_key` is the test seam (and a debugging override); production reads the
    path from `key_file`, then `MEMORY_NEURALWATT_KEY_FILE`, then
    `DEFAULT_KEY_FILE`. Whitespace-only content counts as missing.
    """
    if api_key is not None:
        return api_key.strip() or None
    path = Path(key_file or os.environ.get(KEY_FILE_ENV, DEFAULT_KEY_FILE))
    try:
        key = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        logger.warning("no Neuralwatt API key at %s: %s; proxied requests will fail closed", path, exc)
        return None
    if not key:
        logger.warning("empty Neuralwatt API key at %s; proxied requests will fail closed", path)
    return key or None


def _is_placeholder_authorization(value: str) -> bool:
    scheme, _, token = value.partition(" ")
    return scheme.lower() == "bearer" and token.strip().lower() in PLACEHOLDER_BEARERS


def _request_headers(request: Request, api_key: str | None) -> dict[str, str]:
    headers = {key: value for key, value in request.headers.items() if key.lower() not in REQUEST_STRIP}
    # A real caller credential wins: a direct client may hold a different
    # Neuralwatt key, and silently swapping it would be surprising.
    authorization = next((value for key, value in headers.items() if key.lower() == "authorization"), None)
    if api_key and (authorization is None or _is_placeholder_authorization(authorization)):
        headers["authorization"] = f"Bearer {api_key}"
    return headers


def _response_headers(response: httpx.Response) -> dict[str, str]:
    return {key: value for key, value in response.headers.items() if key.lower() not in RESPONSE_STRIP}


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
    """A positive integer from the environment, or `default` with a warning.

    A typo in the unit environment must not silently disable the limiter or
    make every request fail; the boundary the caller asked for is the default.
    """
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        logger.warning("%s=%r is not an integer; using %d", name, raw, default)
        return default
    if value < 1:
        logger.warning("%s=%r must be at least 1; using %d", name, raw, default)
        return default
    return value


def _retry_after_seconds(value: str | None, *, cap: float = MAX_RETRY_AFTER) -> float | None:
    """The upstream's `Retry-After` as seconds, in `[0, cap]`, or None.

    Both HTTP forms are legal: delay-seconds and an HTTP-date. A date in the
    past (clock skew, a slow hop) means "retry now", not "give up".
    """
    if value is None:
        return None
    value = value.strip()
    try:
        seconds = float(value)
    except ValueError:
        try:
            deadline = parsedate_to_datetime(value)
        except (TypeError, ValueError):
            return None
        if deadline is None:
            return None
        if deadline.tzinfo is None:
            deadline = deadline.replace(tzinfo=timezone.utc)
        seconds = (deadline - datetime.now(timezone.utc)).total_seconds()
    return min(max(seconds, 0.0), cap)


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
    max_request_bytes: int = MAX_REQUEST_BYTES,
    api_key: str | None = None,
    key_file: str | None = None,
    upstream_concurrency: int | None = None,
    upstream_retries: int | None = None,
) -> Starlette:
    base_url = (upstream or os.environ.get("MEMORY_LLM_UPSTREAM", DEFAULT_UPSTREAM)).rstrip("/")
    concurrency = upstream_concurrency or _env_int(UPSTREAM_CONCURRENCY_ENV, DEFAULT_UPSTREAM_CONCURRENCY)
    retries = upstream_retries or _env_int(UPSTREAM_RETRIES_ENV, DEFAULT_UPSTREAM_RETRIES)
    # Per app, not module-level: two apps in one process (tests, an embedder
    # sidecar) must not share or exhaust each other's permits.
    upstream_slots = asyncio.Semaphore(concurrency)
    # Read once at startup: a credential rotation restarts the unit, and a
    # per-request read would turn a missing file into a partial outage.
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
        # Local answer: a readiness probe should fail when this process is
        # gone, not when the chat model is merely loading. It says nothing
        # about the upstream; `/v1/models` does.
        return JSONResponse(
            {"status": "ok", "service": "memory-llm-proxy", "scope": "local"}
        )

    async def read_body(request: Request) -> bytes | None:
        """Read at most `max_request_bytes`, or None when the body is larger."""
        declared = request.headers.get("content-length")
        if declared:
            try:
                if int(declared) > max_request_bytes:
                    return None
            except ValueError:
                pass
        chunks: list[bytes] = []
        total = 0
        async for chunk in request.stream():
            total += len(chunk)
            if total > max_request_bytes:
                return None
            chunks.append(chunk)
        return b"".join(chunks)

    async def proxy(request: Request) -> Response:
        # Fail closed before reading a body we would only refuse: forwarding
        # without the account key would bill nothing but return 401s from
        # Neuralwatt, which is harder to diagnose than an explicit error.
        if resolved_key is None:
            return JSONResponse(
                {
                    "error": {
                        "message": (
                            "memory-llm-proxy has no Neuralwatt API key "
                            f"(set {KEY_FILE_ENV}); refusing to proxy"
                        ),
                        "type": "configuration_error",
                    }
                },
                status_code=503,
            )
        body = await read_body(request)
        if body is None:
            return JSONResponse(
                {
                    "error": {
                        "message": f"request body exceeds {max_request_bytes} bytes",
                        "type": "request_too_large",
                    }
                },
                status_code=413,
            )
        if request.method == "POST" and request.url.path in CHAT_COMPLETION_PATHS:
            try:
                body = inject_thinking_off(body)
            except ValueError as exc:
                return JSONResponse({"error": {"message": str(exc), "type": "invalid_request_error"}}, status_code=400)

        upstream_request = client.build_request(
            request.method,
            request.url.path,
            params=request.url.query,
            headers=_request_headers(request, resolved_key),
            content=body,
        )

        # Released by the body iterator, or by the response when a client
        # disconnects before the first chunk. Either way, exactly once per
        # returned response, so a permit can never leak.
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
                # Nothing has reached the client yet: this response is drained
                # here, so a retry cannot follow a partially streamed body.
                await upstream_response.aclose()
                upstream_slots.release()
                await _sleep(delay)
            raise AssertionError("retry loop fell through")  # unreachable: last attempt returns

        try:
            upstream_response = await open_upstream(upstream_request)
        except httpx.TimeoutException as exc:
            return JSONResponse(
                {
                    "error": {
                        "message": f"upstream {base_url} timed out: {type(exc).__name__}: {exc}",
                        "type": "upstream_timeout",
                    }
                },
                status_code=504,
            )
        except httpx.HTTPError as exc:
            return JSONResponse(
                {
                    "error": {
                        "message": f"upstream {base_url} unavailable: {type(exc).__name__}: {exc}",
                        "type": "upstream_unavailable",
                    }
                },
                status_code=502,
            )

        async def body_stream() -> AsyncIterator[bytes]:
            try:
                # Raw bytes: the upstream's content-encoding header is kept, so
                # decoding here would corrupt the stream.
                async for chunk in upstream_response.aiter_raw():
                    yield chunk
            finally:
                await upstream_response.aclose()
                # The slot is free only once the upstream request is done, not
                # when its headers arrived: a streamed generation still holds
                # one of the tier's three places.
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
    # Tests close the client through the ASGI lifespan; the server closes it on
    # shutdown. Exposing it keeps that explicit instead of implicit.
    app.state.client = client
    # The effective limits are visible for tests and for an operator reading a
    # live process, instead of being buried in the environment.
    app.state.upstream_concurrency = concurrency
    app.state.upstream_retries = retries
    return app


def main() -> int:
    import uvicorn

    host = os.environ.get("MEMORY_LLM_PROXY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("MEMORY_LLM_PROXY_PORT", DEFAULT_PORT))
    uvicorn.run(create_app(), host=host, port=port, log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
