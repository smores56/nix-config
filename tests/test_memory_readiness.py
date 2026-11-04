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
    async def test_probes_the_models_list_and_sends_a_tiny_embedding_request(self):
        seen = []
        probes = HealthProbes(llm_url="http://gateway/", transport=transport(record=seen))

        self.assertEqual(await probes.failures(), [])
        self.assertEqual(
            [(request.method, request.url.path) for request in seen],
            [("GET", "/v1/models"), ("POST", "/v1/embeddings")],
        )
        self.assertEqual(
            json.loads(seen[1].content),
            {"input": "ready", "model": "qwen3-embedding-8b"},
        )

    async def test_a_failing_embedder_blocks_search(self):
        probes = HealthProbes(llm_url="http://gateway", transport=transport(embedder=503))

        with self.assertRaises(ReadinessError) as raised:
            await probes.require_search()
        self.assertIn("embedder unavailable", str(raised.exception))

    async def test_an_unreachable_endpoint_is_a_failure_not_an_exception(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("refused", request=request)

        probes = HealthProbes(llm_url="http://gateway", transport=httpx.MockTransport(handler))

        self.assertEqual(len(await probes.failures()), 2)


if __name__ == "__main__":
    unittest.main()
