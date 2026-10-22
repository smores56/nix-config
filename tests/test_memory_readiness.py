import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

import httpx  # noqa: E402

from memory_mcp.readiness import HealthProbes, ReadinessError  # noqa: E402


def transport(*, chat=200, embedder=200, record=None):
    def handler(request: httpx.Request) -> httpx.Response:
        if record is not None:
            record.append(request)
        path = request.url.path
        status = chat if path == "/v1/models" else embedder
        return httpx.Response(status, json={})

    return httpx.MockTransport(handler)


class ReadinessTests(unittest.IsolatedAsyncioTestCase):
    async def test_the_local_default_probes_llama_cpp_health(self):
        seen = []
        probes = HealthProbes(
            llm_url="http://llm",
            embed_url="http://embed/",
            transport=transport(record=seen),
        )

        self.assertEqual(await probes.failures(), [])
        self.assertEqual(
            [(request.method, request.url.path) for request in seen],
            [("GET", "/v1/models"), ("GET", "/health")],
        )

    async def test_a_remote_embedder_sends_a_tiny_embedding_request(self):
        seen = []
        probes = HealthProbes(
            llm_url="http://gateway",
            embed_url="http://gateway",
            embed_model="qwen3-embedding-8b",
            transport=transport(record=seen),
        )

        self.assertEqual(await probes.failures(), [])
        embedding = seen[1]
        self.assertEqual((embedding.method, embedding.url.path), ("POST", "/v1/embeddings"))
        self.assertEqual(
            json.loads(embedding.content),
            {"input": "ready", "model": "qwen3-embedding-8b"},
        )

    async def test_a_failing_remote_embedder_blocks_search(self):
        probes = HealthProbes(
            llm_url="http://gateway",
            embed_url="http://gateway",
            embed_model="qwen3-embedding-8b",
            transport=transport(embedder=503),
        )

        with self.assertRaises(ReadinessError) as raised:
            await probes.require_search()
        self.assertIn("embedder unavailable", str(raised.exception))

    async def test_an_unreachable_endpoint_is_a_failure_not_an_exception(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("refused", request=request)

        probes = HealthProbes(
            llm_url="http://llm",
            embed_url="http://embed",
            transport=httpx.MockTransport(handler),
        )

        failed = await probes.failures()
        self.assertEqual(len(failed), 2)
        with self.assertRaises(ReadinessError) as raised:
            await probes.require_write()
        self.assertIn("memory write not queued", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
