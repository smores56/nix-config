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

    def test_an_http_date_is_not_a_delay(self):
        self.assertIsNone(llm_proxy._retry_after_seconds(None))
        self.assertIsNone(llm_proxy._retry_after_seconds("Wed, 21 Oct 2015 07:28:00 GMT"))

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
        kwargs.setdefault("reasoning_effort", "none")
        return create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(record),
            timeout=5.0,
            **kwargs,
        )

    async def call(self, app, method, path, *, json_body=None, headers=None):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1"
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

    async def test_no_rewrite_unless_an_effort_is_configured(self):
        app = self.app(lambda request: response(), reasoning_effort="")
        await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertNotIn("reasoning_effort", self.body(self.seen[0]))

    async def test_the_configured_effort_is_the_one_injected(self):
        app = self.app(lambda request: response(), reasoning_effort="low")
        await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(self.body(self.seen[0])["reasoning_effort"], "low")

    async def test_the_effort_comes_from_the_environment(self):
        with mock.patch.dict(os.environ, {"MEMORY_LLM_REASONING_EFFORT": "none"}):
            app = self.app(lambda request: response(), reasoning_effort=None)
        await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
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

    async def test_upstream_error_status_is_forwarded(self):
        # A 503 is retried first, so the final answer is the upstream's own.
        app = self.app(lambda request: response(status=503, payload={"error": {"message": "loading"}}))
        with mock.patch.object(llm_proxy.asyncio, "sleep", new=mock.AsyncMock()):
            reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 503)
        self.assertEqual(reply.json()["error"]["message"], "loading")
        self.assertEqual(len(self.seen), 6)

    async def raw(self, app, path, headers, method="GET"):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1"
        ) as client:
            return await client.request(method, path, headers=headers)

    async def test_a_browser_origin_is_refused(self):
        app = self.app(lambda request: response())
        reply = await self.raw(app, "/v1/models", {"origin": "https://evil.example"})
        self.assertEqual(reply.status_code, 403)
        self.assertEqual(self.seen, [])

    async def test_a_foreign_host_header_is_refused_before_routing(self):
        app = self.app(lambda request: response())
        for host in ("evil.example", "evil.example:8082", "127.0.0.1.evil.example", "host.docker.internal"):
            with self.subTest(host=host):
                reply = await self.raw(app, "/health", {"host": host})
                self.assertEqual(reply.status_code, 403)
        self.assertEqual(self.seen, [])

    async def test_loopback_hosts_pass(self):
        app = self.app(lambda request: response())
        for host in ("127.0.0.1", "127.0.0.1:8082", "localhost", "localhost:8082"):
            with self.subTest(host=host):
                self.assertEqual((await self.raw(app, "/health", {"host": host})).status_code, 200)

    async def test_an_extra_allowed_host_is_accepted_only_when_configured(self):
        app = self.app(lambda request: response(), allowed_hosts=("host.docker.internal",))
        reply = await self.raw(app, "/health", {"host": "host.docker.internal:8082"})
        self.assertEqual(reply.status_code, 200)
        self.assertEqual((await self.raw(app, "/health", {"host": "evil.example"})).status_code, 403)

    async def test_allowed_hosts_come_from_the_environment(self):
        with mock.patch.dict(os.environ, {"MEMORY_LLM_PROXY_ALLOWED_HOSTS": "host.docker.internal"}):
            app = self.app(lambda request: response())
        reply = await self.raw(app, "/health", {"host": "host.docker.internal:8082"})
        self.assertEqual(reply.status_code, 200)

    async def test_health_answers_locally_without_the_upstream(self):
        app = self.app(lambda request: response(status=500))
        reply = await self.call(app, "GET", "/health")
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(
            reply.json(),
            {"status": "ok", "service": "memory-llm-proxy", "scope": "local"},
        )
        self.assertEqual(self.seen, [])

    async def test_the_read_timeout_is_configured_on_the_upstream_client(self):
        app = create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(lambda request: response()),
            timeout=5.0,
            read_timeout=42.0,
            api_key="test-key",
        )
        self.assertEqual(app.state.client.timeout.read, 42.0)
        self.assertEqual(app.state.client.timeout.connect, 10.0)

    async def test_a_body_that_is_not_json_is_forwarded_untouched(self):
        app = self.app(lambda request: response())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1"
        ) as client:
            reply = await client.post(
                "/v1/chat/completions", content=b"{not json", headers={"content-type": "application/json"}
            )
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(self.seen[0].content, b"{not json")

    def test_no_upstream_configured_refuses_to_start(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MEMORY_LLM_UPSTREAM", None)
            with self.assertRaises(ValueError):
                create_app(api_key="k", transport=httpx.MockTransport(lambda r: response()))

    def test_no_configured_key_file_refuses_to_start(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MEMORY_LLM_KEY_FILE", None)
            with self.assertRaises(llm_proxy.MissingKeyError):
                self.app(lambda request: response(), api_key=None)

    def test_a_missing_or_blank_key_refuses_to_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            blank = Path(tmp) / "blank"
            blank.write_text("\n", encoding="utf-8")
            for key_file in ("/nonexistent/key", str(blank)):
                with self.subTest(key_file=key_file), self.assertRaises(llm_proxy.MissingKeyError):
                    self.app(lambda request: response(), api_key=None, key_file=key_file)

    async def test_the_neuralwatt_key_is_injected_when_the_client_sends_none(self):
        app = self.app(lambda request: response())
        await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer test-key")

    async def test_a_caller_credential_is_always_replaced_with_the_key(self):
        # Graphiti sends the placeholder "Bearer none"; anything else a caller
        # sends is replaced too, so the account key is the only credential upstream.
        app = self.app(lambda request: response())
        for header in ("Bearer none", "Bearer caller", "Basic Zm9vOmJhcg=="):
            with self.subTest(header=header):
                await self.call(
                    app,
                    "POST",
                    "/v1/chat/completions",
                    json_body={"messages": []},
                    headers={"authorization": header},
                )
                self.assertEqual(self.seen[-1].headers["authorization"], "Bearer test-key")
                self.assertEqual(self.seen[-1].headers.get_list("authorization"), ["Bearer test-key"])

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
            env = {"MEMORY_LLM_KEY_FILE": str(key_file)}
            with mock.patch.dict(os.environ, env):
                app = self.app(lambda request: response(), api_key=None)
        await self.call(app, "GET", "/v1/models")
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer from-env")

    async def test_embeddings_are_authorized_but_left_unrewritten(self):
        app = self.app(lambda request: response(payload={"data": []}))
        payload = {"input": "hello", "model": "qwen3-embedding-8b"}
        await self.call(app, "POST", "/v1/embeddings", json_body=payload)

        self.assertEqual(self.seen[0].headers["authorization"], "Bearer test-key")
        self.assertEqual(self.body(self.seen[0]), payload)

    async def test_only_the_three_graphiti_routes_are_forwarded(self):
        app = self.app(lambda request: response())
        for method, path in (
            ("POST", "/v1/completions"),
            ("POST", "/chat/completions"),
            ("GET", "/v1/files"),
            ("DELETE", "/v1/models"),
        ):
            with self.subTest(method=method, path=path):
                reply = await self.call(app, method, path, json_body={} if method == "POST" else None)
                self.assertIn(reply.status_code, (404, 405))
        self.assertEqual(self.seen, [])
        for method, path in (("POST", "/v1/chat/completions"), ("POST", "/v1/embeddings"), ("GET", "/v1/models")):
            reply = await self.call(app, method, path, json_body={} if method == "POST" else None)
            self.assertEqual(reply.status_code, 200)

    async def test_an_oversize_body_is_rejected_by_declared_length_and_while_reading(self):
        app = self.app(lambda request: response())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1"
        ) as client:
            declared = await client.post(
                "/v1/chat/completions",
                content=b"x" * (llm_proxy.MAX_REQUEST_BYTES + 1),
                headers={"content-type": "application/json"},
            )

            async def chunks():
                for _ in range(llm_proxy.MAX_REQUEST_BYTES // 1_000_000 + 2):
                    yield b"x" * 1_000_000

            streamed = await client.post(
                "/v1/chat/completions",
                content=chunks(),
                headers={"content-type": "application/json", "transfer-encoding": "chunked"},
            )
            small = await client.post("/v1/chat/completions", json={"messages": []})
        self.assertEqual(declared.status_code, 413)
        self.assertEqual(streamed.status_code, 413)
        self.assertEqual(small.status_code, 200)
        self.assertEqual(len(self.seen), 1)

    async def test_upstream_failures_map_to_502_and_504(self):
        for exc, status in ((httpx.ConnectError, 502), (httpx.ReadTimeout, 504)):
            with self.subTest(exc=exc.__name__):

                def handler(request, exc=exc):
                    raise exc("boom", request=request)

                app = self.app(handler)
                reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
                self.assertEqual(reply.status_code, status)
                self.assertIn("error", reply.json())

    async def test_extraction_permits_do_not_block_embeddings(self):
        release = asyncio.Event()

        async def handler(request):
            if request.url.path == "/v1/chat/completions":
                await release.wait()
            return response(payload={"data": []})

        app = self.app(handler, upstream_concurrency=2)
        held = [
            asyncio.create_task(
                self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
            )
            for _ in range(2)
        ]
        await asyncio.sleep(0.05)
        try:
            embed = await asyncio.wait_for(
                self.call(app, "POST", "/v1/embeddings", json_body={"input": "x", "model": "m"}), 2
            )
            models = await asyncio.wait_for(self.call(app, "GET", "/v1/models"), 2)
        finally:
            release.set()
        await asyncio.gather(*held)
        self.assertEqual((embed.status_code, models.status_code), (200, 200))

    async def test_a_gzipped_upstream_reply_is_relayed_decoded(self):
        import gzip

        payload = gzip.compress(b'{"ok": true}')
        app = self.app(
            lambda request: httpx.Response(
                200, content=payload, headers={"content-encoding": "gzip", "content-type": "application/json"}
            )
        )
        reply = await self.call(app, "GET", "/v1/models")
        self.assertEqual(reply.json(), {"ok": True})

    async def test_redirects_are_not_followed(self):
        app = self.app(lambda request: httpx.Response(302, headers={"location": "http://elsewhere/"}))
        reply = await self.call(app, "GET", "/v1/models")
        self.assertEqual(reply.status_code, 302)
        self.assertEqual(len(self.seen), 1)
        self.assertFalse(app.state.client.follow_redirects)

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
        with mock.patch.object(llm_proxy.asyncio, "sleep", new=mock.AsyncMock()) as sleep:
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
        with mock.patch.object(llm_proxy.asyncio, "sleep", new=mock.AsyncMock()) as sleep:
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
        with mock.patch.object(llm_proxy.asyncio, "sleep", new=mock.AsyncMock()):
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


if __name__ == "__main__":
    unittest.main()
