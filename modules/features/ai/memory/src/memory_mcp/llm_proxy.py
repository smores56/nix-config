"""Loopback OpenAI-compatible proxy that turns off thinking for Graphiti.

Graphiti's generic OpenAI client sends no per-request thinking control, and the
qwen3.8 chat server defaults to thinking on: extraction spends the whole
max_tokens budget as reasoning and returns empty content, which Graphiti drops.
llama.cpp parses `reasoning_effort` on each chat completion, so this proxy adds
`reasoning_effort: "none"` to chat requests only. Maki keeps talking to the
same server directly, so its thinking behavior is unchanged.

Everything except chat completions is forwarded untouched; streaming responses
are passed through without buffering because extraction progress is not the
only consumer of this port.

`/health` is a local liveness answer: it reports that this proxy is running, not
that the chat model behind it is loaded. Operators check the model through the
proxied `/v1/models` (see `docs/manual-steps.md`).

Request bodies are capped at `MAX_REQUEST_BYTES` (extraction prompts are large,
but a runaway or hostile client must not park gigabytes in memory), and reads
have their own deadline so a stalled upstream cannot pin a worker forever.
"""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

DEFAULT_UPSTREAM = "http://127.0.0.1:8081"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8082
DEFAULT_TIMEOUT = 600.0
# A stalled upstream (no bytes, including during a stream) must not hold a
# connection forever. Long extraction streams still emit tokens well inside it.
DEFAULT_READ_TIMEOUT = 300.0
DEFAULT_CONNECT_TIMEOUT = 10.0
# Graphiti's largest extraction prompt is far below this; the cap bounds a
# hostile client's memory instead of the legitimate case.
MAX_REQUEST_BYTES = 10 * 1024 * 1024
CHAT_COMPLETION_PATHS = frozenset({"/v1/chat/completions", "/chat/completions"})
REASONING_EFFORT = "none"

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


def _request_headers(request: Request) -> dict[str, str]:
    return {key: value for key, value in request.headers.items() if key.lower() not in REQUEST_STRIP}


def _response_headers(response: httpx.Response) -> dict[str, str]:
    return {key: value for key, value in response.headers.items() if key.lower() not in RESPONSE_STRIP}


def create_app(
    *,
    upstream: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    timeout: float = DEFAULT_TIMEOUT,
    read_timeout: float = DEFAULT_READ_TIMEOUT,
    max_request_bytes: int = MAX_REQUEST_BYTES,
) -> Starlette:
    base_url = (upstream or os.environ.get("MEMORY_LLM_UPSTREAM", DEFAULT_UPSTREAM)).rstrip("/")
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
            headers=_request_headers(request),
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
