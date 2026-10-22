import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

import httpx  # noqa: E402

from memory_mcp import llm_proxy  # noqa: E402
from memory_mcp.llm_proxy import create_app  # noqa: E402


async def _chunks(items):
    for item in items:
        yield item


def response(*, status=200, payload=None, chunks=None, headers=None):
    """MockTransport reply with an async stream, which is what AsyncClient needs."""
    body = list(chunks) if chunks is not None else [json.dumps({} if payload is None else payload).encode()]
    return httpx.Response(
        status,
        content=_chunks(body),
        headers=headers if headers is not None else {"content-type": "application/json"},
    )


class RetryAfterTests(unittest.TestCase):
    def test_delay_seconds_are_honoured(self):
        self.assertEqual(llm_proxy._retry_after_seconds("7"), 7.0)

    def test_an_http_date_becomes_a_delay(self):
        self.assertIsNone(llm_proxy._retry_after_seconds(None))
        # A date in the past means retry now; a far one is still capped.
        self.assertEqual(llm_proxy._retry_after_seconds("Wed, 21 Oct 2015 07:28:00 GMT"), 0.0)
        self.assertEqual(llm_proxy._retry_after_seconds("Fri, 21 Oct 2095 07:28:00 GMT"), llm_proxy.MAX_RETRY_AFTER)

    def test_a_huge_delay_is_capped_and_a_garbage_value_is_ignored(self):
        self.assertEqual(llm_proxy._retry_after_seconds("99999"), llm_proxy.MAX_RETRY_AFTER)
        self.assertIsNone(llm_proxy._retry_after_seconds("soon"))

    def test_backoff_grows_and_is_capped(self):
        delays = [llm_proxy._backoff_seconds(attempt) for attempt in range(8)]
        self.assertLessEqual(delays[0], llm_proxy.RETRY_BACKOFF_BASE)
        self.assertLessEqual(delays[1], llm_proxy.RETRY_BACKOFF_BASE * 2)
        self.assertTrue(all(delay <= llm_proxy.RETRY_BACKOFF_CAP for delay in delays))


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    def app(self, handler, **kwargs):
        self.seen = []

        def record(request: httpx.Request) -> httpx.Response:
            self.seen.append(request)
            return handler(request)

        kwargs.setdefault("api_key", "test-key")
        return create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(record),
            timeout=5.0,
            **kwargs,
        )

    async def call(self, app, method, path, *, json_body=None, headers=None):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://proxy"
        ) as client:
            return await client.request(method, path, json=json_body, headers=headers)

    def body(self, request):
        return json.loads(request.content)

    async def test_chat_completion_gets_reasoning_effort_none(self):
        app = self.app(lambda request: response(payload={"choices": [{"message": {"content": "{}"}}]}))

        reply = await self.call(
            app,
            "POST",
            "/v1/chat/completions",
            json_body={"model": "qwen", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8192},
        )

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(self.body(self.seen[0])["reasoning_effort"], "none")
        self.assertEqual(self.body(self.seen[0])["model"], "qwen")
        self.assertEqual(reply.json()["choices"][0]["message"]["content"], "{}")

    async def test_bare_chat_completions_path_is_also_injected(self):
        app = self.app(lambda request: response())
        await self.call(app, "POST", "/chat/completions", json_body={"messages": []})
        self.assertEqual(self.body(self.seen[0])["reasoning_effort"], "none")

    async def test_explicit_reasoning_effort_is_preserved(self):
        app = self.app(lambda request: response())
        await self.call(
            app, "POST", "/v1/chat/completions", json_body={"reasoning_effort": "high", "messages": []}
        )
        self.assertEqual(self.body(self.seen[0])["reasoning_effort"], "high")

    async def test_non_chat_paths_pass_through_unchanged(self):
        app = self.app(
            lambda request: response(
                payload={"data": [{"id": "qwen"}]},
                headers={"content-type": "application/json", "x-upstream": "yes"},
            )
        )
        payload = {"input": "hello", "model": "bge-m3"}
        reply = await self.call(app, "POST", "/v1/embeddings", json_body=payload)

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.headers["x-upstream"], "yes")
        self.assertEqual(self.body(self.seen[0]), payload)
        self.assertNotIn("reasoning_effort", self.body(self.seen[0]))

    async def test_models_passthrough_keeps_method_and_query(self):
        app = self.app(lambda request: response(payload={"object": "list"}))
        reply = await self.call(app, "GET", "/v1/models?limit=1")

        self.assertEqual(reply.json(), {"object": "list"})
        self.assertEqual(self.seen[0].method, "GET")
        self.assertEqual(self.seen[0].url.path, "/v1/models")
        self.assertEqual(self.seen[0].url.query, b"limit=1")

    async def test_streaming_passthrough_is_not_buffered_away(self):
        chunks = [b'data: {"choices":[{"delta":{"content":"{"}}]}\n\n', b"data: [DONE]\n\n"]

        app = self.app(lambda request: response(chunks=chunks, headers={"content-type": "text/event-stream"}))
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"stream": True, "messages": []})

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.content, b"".join(chunks))
        self.assertEqual(reply.headers["content-type"], "text/event-stream")
        self.assertTrue(self.body(self.seen[0])["stream"])
        self.assertEqual(self.body(self.seen[0])["reasoning_effort"], "none")

    async def test_upstream_connection_error_is_502_with_message(self):
        def handler(request):
            raise httpx.ConnectError("connection refused", request=request)

        app = self.app(handler)
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})

        self.assertEqual(reply.status_code, 502)
        error = reply.json()["error"]
        self.assertEqual(error["type"], "upstream_unavailable")
        self.assertIn("http://upstream", error["message"])

    async def test_upstream_error_status_is_forwarded(self):
        # A 503 is retried first, so the final answer is the upstream's own.
        app = self.app(lambda request: response(status=503, payload={"error": {"message": "loading"}}))
        with mock.patch.object(llm_proxy, "_sleep", new=mock.AsyncMock()):
            reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 503)
        self.assertEqual(reply.json()["error"]["message"], "loading")
        self.assertEqual(len(self.seen), 6)

    async def test_health_answers_locally_without_the_upstream(self):
        app = self.app(lambda request: response(status=500))
        reply = await self.call(app, "GET", "/health")
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(
            reply.json(),
            {"status": "ok", "service": "memory-llm-proxy", "scope": "local"},
        )
        self.assertEqual(self.seen, [])

    async def test_an_oversize_request_body_is_rejected(self):
        app = self.app(lambda request: response(), max_request_bytes=64)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://proxy"
        ) as client:
            reply = await client.post(
                "/v1/chat/completions",
                content=b"x" * 200,
                headers={"content-type": "application/json"},
            )
        self.assertEqual(reply.status_code, 413)
        self.assertEqual(reply.json()["error"]["type"], "request_too_large")
        self.assertEqual(self.seen, [])

    async def test_a_small_body_still_reaches_the_upstream(self):
        app = self.app(lambda request: response(), max_request_bytes=64)
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(len(self.seen), 1)

    async def test_a_read_timeout_is_a_504(self):
        def handler(request):
            raise httpx.ReadTimeout("timed out reading", request=request)

        app = self.app(handler)
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 504)
        self.assertEqual(reply.json()["error"]["type"], "upstream_timeout")

    async def test_the_read_timeout_is_configured_on_the_upstream_client(self):
        app = create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(lambda request: response()),
            timeout=5.0,
            read_timeout=42.0,
        )
        self.assertEqual(app.state.client.timeout.read, 42.0)
        self.assertEqual(app.state.client.timeout.connect, 10.0)

    async def test_invalid_json_on_a_chat_path_is_400(self):
        app = self.app(lambda request: response())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://proxy"
        ) as client:
            reply = await client.post(
                "/v1/chat/completions", content=b"{not json", headers={"content-type": "application/json"}
            )
        self.assertEqual(reply.status_code, 400)
        self.assertEqual(self.seen, [])

    async def test_the_neuralwatt_key_is_injected_when_the_client_sends_none(self):
        app = self.app(lambda request: response())
        await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer test-key")

    async def test_a_client_supplied_authorization_is_never_overridden(self):
        app = self.app(lambda request: response())
        await self.call(
            app,
            "POST",
            "/v1/chat/completions",
            json_body={"messages": []},
            headers={"authorization": "Bearer caller"},
        )
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer caller")

    async def test_a_placeholder_authorization_is_replaced_with_the_key(self):
        # Graphiti's YAML needs a non-empty `api_key`, so it sends "Bearer none"
        # and the OpenAI SDK forwards it. That placeholder must not reach
        # Neuralwatt, or every extraction would 401.
        app = self.app(lambda request: response())
        await self.call(
            app,
            "POST",
            "/v1/chat/completions",
            json_body={"messages": []},
            headers={"authorization": "Bearer none"},
        )
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer test-key")

    async def test_the_key_is_read_from_the_configured_file_at_startup(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "neuralwatt-api-key"
            key_file.write_text("from-file\n", encoding="utf-8")
            app = self.app(lambda request: response(), api_key=None, key_file=str(key_file))
        await self.call(app, "GET", "/v1/models")
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer from-file")

    async def test_the_key_file_path_comes_from_the_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "neuralwatt-api-key"
            key_file.write_text("from-env\n", encoding="utf-8")
            env = {"MEMORY_NEURALWATT_KEY_FILE": str(key_file)}
            with mock.patch.dict(os.environ, env):
                app = self.app(lambda request: response(), api_key=None)
        await self.call(app, "GET", "/v1/models")
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer from-env")

    async def test_a_missing_key_refuses_proxied_requests_but_answers_health(self):
        app = self.app(lambda request: response(), api_key=None, key_file="/nonexistent/key")

        health = await self.call(app, "GET", "/health")
        self.assertEqual(health.status_code, 200)

        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 503)
        self.assertEqual(reply.json()["error"]["type"], "configuration_error")
        self.assertEqual(self.seen, [])

    async def test_a_blank_key_file_is_treated_as_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "neuralwatt-api-key"
            key_file.write_text("\n", encoding="utf-8")
            app = self.app(lambda request: response(), api_key=None, key_file=str(key_file))
        reply = await self.call(app, "GET", "/v1/models")
        self.assertEqual(reply.status_code, 503)
        self.assertEqual(self.seen, [])

    async def test_embeddings_are_authorized_but_left_unrewritten(self):
        app = self.app(lambda request: response(payload={"data": []}))
        payload = {"input": "hello", "model": "qwen3-embedding-8b"}
        await self.call(app, "POST", "/v1/embeddings", json_body=payload)

        self.assertEqual(self.seen[0].headers["authorization"], "Bearer test-key")
        self.assertEqual(self.body(self.seen[0]), payload)

    async def test_hop_by_hop_and_stale_content_length_are_dropped(self):
        app = self.app(lambda request: response())
        await self.call(
            app,
            "POST",
            "/v1/chat/completions",
            json_body={"messages": [], "reasoning_effort": "high"},
            headers={"connection": "keep-alive", "x-keep": "me"},
        )
        request = self.seen[0]
        self.assertNotIn("transfer-encoding", request.headers)
        self.assertEqual(request.headers["x-keep"], "me")
        # The forward request's length matches the rewritten body, not the input.
        self.assertEqual(int(request.headers["content-length"]), len(request.content))

    def test_the_default_limits_are_two_slots_and_six_attempts(self):
        app = self.app(lambda request: response())
        self.assertEqual(app.state.upstream_concurrency, 2)
        self.assertEqual(app.state.upstream_retries, 6)

    def test_the_limits_come_from_the_unit_environment(self):
        env = {"MEMORY_UPSTREAM_CONCURRENCY": "3", "MEMORY_UPSTREAM_RETRIES": "2"}
        with mock.patch.dict(os.environ, env):
            app = self.app(lambda request: response())
        self.assertEqual(app.state.upstream_concurrency, 3)
        self.assertEqual(app.state.upstream_retries, 2)

    async def test_concurrency_never_exceeds_the_configured_limit(self):
        gate = {"active": 0, "peak": 0, "calls": 0}

        async def handler(request):
            gate["active"] += 1
            gate["calls"] += 1
            gate["peak"] = max(gate["peak"], gate["active"])
            try:
                # Long enough that every caller would overlap without a permit.
                await asyncio.sleep(0.02)
                return response()
            finally:
                gate["active"] -= 1

        app = self.app(handler, upstream_concurrency=2)
        replies = await asyncio.gather(
            *(self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []}) for _ in range(6))
        )

        self.assertEqual([reply.status_code for reply in replies], [200] * 6)
        self.assertEqual(gate["calls"], 6)
        self.assertEqual(gate["peak"], 2)

    async def test_a_429_with_retry_after_is_retried_and_succeeds(self):
        outcomes = [
            response(status=429, payload={"error": {"message": "slow down"}}, headers={"retry-after": "0"}),
            response(payload={"choices": [{"message": {"content": "{}"}}]}),
        ]

        def handler(request):
            return outcomes.pop(0)

        app = self.app(handler, upstream_retries=3)
        with mock.patch.object(llm_proxy, "_sleep", new=mock.AsyncMock()) as sleep:
            reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.json()["choices"][0]["message"]["content"], "{}")
        self.assertEqual(len(self.seen), 2)
        sleep.assert_awaited_once_with(0.0)

    async def test_exhausted_retries_return_the_upstream_429(self):
        app = self.app(
            lambda request: response(status=429, payload={"error": {"message": "rate limited"}}),
            upstream_retries=3,
        )
        with mock.patch.object(llm_proxy, "_sleep", new=mock.AsyncMock()) as sleep:
            reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})

        self.assertEqual(reply.status_code, 429)
        self.assertEqual(reply.json()["error"]["message"], "rate limited")
        self.assertEqual(len(self.seen), 3)
        # Two retries, both backed off: no Retry-After was offered.
        self.assertEqual(sleep.await_count, 2)

    async def test_a_503_is_retried_too(self):
        outcomes = [
            response(status=503, payload={"error": {"message": "overloaded"}}),
            response(payload={"object": "list"}),
        ]
        app = self.app(lambda request: outcomes.pop(0), upstream_retries=2)
        with mock.patch.object(llm_proxy, "_sleep", new=mock.AsyncMock()):
            reply = await self.call(app, "GET", "/v1/models")

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.json(), {"object": "list"})
        self.assertEqual(len(self.seen), 2)

    async def test_a_400_is_not_retried(self):
        app = self.app(
            lambda request: response(status=400, payload={"error": {"message": "bad request"}}),
            upstream_retries=3,
        )
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})

        self.assertEqual(reply.status_code, 400)
        self.assertEqual(reply.json()["error"]["message"], "bad request")
        self.assertEqual(len(self.seen), 1)

    async def test_a_streaming_response_is_never_retried_after_it_starts(self):
        chunks = [b'data: {"choices":[{"delta":{"content":"{"}}]}\n\n', b"data: [DONE]\n\n"]

        app = self.app(
            lambda request: response(chunks=chunks, headers={"content-type": "text/event-stream"}),
            upstream_retries=3,
        )
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"stream": True, "messages": []})

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.content, b"".join(chunks))
        self.assertEqual(len(self.seen), 1)

    async def test_a_rejected_streaming_request_is_retried_before_any_body_is_sent(self):
        chunk = b'data: {"choices":[{"delta":{"content":"{}"}}]}\n\n'
        outcomes = [
            response(status=429, chunks=[b"busy"], headers={"retry-after": "0"}),
            response(chunks=[chunk], headers={"content-type": "text/event-stream"}),
        ]
        app = self.app(lambda request: outcomes.pop(0), upstream_retries=2)
        with mock.patch.object(llm_proxy, "_sleep", new=mock.AsyncMock()):
            reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"stream": True, "messages": []})

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.content, chunk)
        self.assertEqual(len(self.seen), 2)
    async def test_a_stream_that_never_starts_still_releases_its_slot(self):
        # A client that disconnects between the upstream send and the first
        # chunk never runs the body iterator; the response itself must return
        # the permit, or the limiter shrinks for the life of the process.
        released = []

        async def body():
            yield b"x"

        async def send(message):
            raise RuntimeError("client disconnected")

        async def receive():
            return {"type": "http.disconnect"}

        response = llm_proxy._ReleasingStreamingResponse(
            body(), release=lambda: released.append(True), status_code=200, headers={}
        )
        try:
            await response({"type": "http"}, receive, send)
        except BaseException:  # noqa: BLE001 - the failure mode is not the point
            pass
        self.assertEqual(released, [True])


if __name__ == "__main__":
    unittest.main()
