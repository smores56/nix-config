import json
import sys
import unittest
from pathlib import Path

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
    def app(self, handler):
        self.seen = []

        def record(request: httpx.Request) -> httpx.Response:
            self.seen.append(request)
            return handler(request)

        return create_app(upstream="http://upstream", transport=httpx.MockTransport(record), timeout=5.0)

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
        self.assertEqual(reply.json(), {"status": "ok", "service": "memory-llm-proxy"})
        self.assertEqual(self.seen, [])

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
