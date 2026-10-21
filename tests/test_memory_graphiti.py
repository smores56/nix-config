import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import graphiti  # noqa: E402
from memory_mcp.client import ToolResult, UpstreamError  # noqa: E402


class FakeCall:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    async def __call__(self, config, name, arguments):
        self.calls.append((dict(config.headers), name, arguments))
        if self.error:
            raise self.error
        return self.result


class GraphitiBackendTests(unittest.IsolatedAsyncioTestCase):
    def backend(self, result=None, error=None):
        fake = FakeCall(result=result, error=error)
        self.patch = mock.patch.object(graphiti, "call_tool", fake)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        return graphiti.GraphitiBackend("http://127.0.0.1:8184/mcp"), fake

    async def test_add_episode_parses_success(self):
        backend, fake = self.backend(ToolResult(text='{"message": "queued"}', is_error=False))
        result = await backend.add_episode(
            name="n",
            episode_body="body",
            group_id="owner--repo",
            source_description="hash=abc",
        )
        self.assertEqual(result["message"], "queued")
        _headers, name, arguments = fake.calls[0]
        self.assertEqual(name, "add_memory")
        self.assertEqual(arguments["group_id"], "owner--repo")
        self.assertEqual(arguments["source"], "text")
        # graphiti-core 0.31.2 must not receive a caller uuid for a new episode.
        self.assertNotIn("uuid", arguments)

    async def test_error_payload_is_a_backend_error(self):
        backend, _fake = self.backend(ToolResult(text='{"error": "boom"}', is_error=False))
        with self.assertRaises(graphiti.BackendError):
            await backend.add_episode(
                name="n",
                episode_body="body",
                group_id="owner--repo",
                source_description="",
            )

    async def test_upstream_failure_is_a_backend_error(self):
        backend, _fake = self.backend(error=UpstreamError("connection refused"))
        with self.assertRaises(graphiti.BackendError):
            await backend.get_status()

    async def test_search_parses_nodes_facts_and_episodes(self):
        backend, _fake = self.backend(
            ToolResult(text='{"nodes": [{"uuid": "n1"}], "message": "ok"}', is_error=False)
        )
        self.assertEqual(await backend.search_nodes("q", ["g"], 5), [{"uuid": "n1"}])

        backend, _fake = self.backend(
            ToolResult(text='{"facts": [{"uuid": "e1"}], "message": "ok"}', is_error=False)
        )
        self.assertEqual(await backend.search_facts("q", ["g"], 5), [{"uuid": "e1"}])

        backend, _fake = self.backend(
            ToolResult(text='{"episodes": [{"uuid": "ep1"}], "message": "ok"}', is_error=False)
        )
        self.assertEqual(await backend.get_episodes(["g"], 3), [{"uuid": "ep1"}])

    async def test_non_json_text_is_preserved_as_a_message(self):
        backend, _fake = self.backend(ToolResult(text="plain text", is_error=False))
        self.assertEqual(await backend.get_status(), {"message": "plain text"})


if __name__ == "__main__":
    unittest.main()
