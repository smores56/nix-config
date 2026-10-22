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
"""

from __future__ import annotations

import json
import logging
import os
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


def create_app(
    *,
    upstream: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    timeout: float = DEFAULT_TIMEOUT,
    read_timeout: float = DEFAULT_READ_TIMEOUT,
    max_request_bytes: int = MAX_REQUEST_BYTES,
    api_key: str | None = None,
    key_file: str | None = None,
) -> Starlette:
    base_url = (upstream or os.environ.get("MEMORY_LLM_UPSTREAM", DEFAULT_UPSTREAM)).rstrip("/")
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
        try:
            upstream_response = await client.send(upstream_request, stream=True)
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

        return StreamingResponse(
            body_stream(),
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
    return app


def main() -> int:
    import uvicorn

    host = os.environ.get("MEMORY_LLM_PROXY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("MEMORY_LLM_PROXY_PORT", DEFAULT_PORT))
    uvicorn.run(create_app(), host=host, port=port, log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
