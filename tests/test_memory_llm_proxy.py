import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

import httpx  # noqa: E402

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
        app = self.app(lambda request: response(status=503, payload={"error": {"message": "loading"}}))
        reply = await self.call(app, "POST", "/v1/chat/completions", json_body={"messages": []})
        self.assertEqual(reply.status_code, 503)
        self.assertEqual(reply.json()["error"]["message"], "loading")

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


if __name__ == "__main__":
    unittest.main()
