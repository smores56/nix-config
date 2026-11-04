import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from datetime import datetime, timezone  # noqa: E402

from memory_mcp.graph import (  # noqa: E402
    EPISODIC_CONTENTS_QUERY,
    EPISODIC_MATCHES_QUERY,
    RELATES_TO,
    GraphStore,
    GraphUnavailable,
    not_older,
)
from unittest import mock
from memory_mcp import graphiti  # noqa: E402
from memory_mcp.client import ToolResult, UpstreamError  # noqa: E402
import json
import httpx  # noqa: E402
from memory_mcp.readiness import HealthProbes, ReadinessError  # noqa: E402


class FakeRedis:
    def __init__(self, *, graph_names=("global",), reply=None, error=None, list_error=None, replies=None):
        self.graph_names = graph_names
        self.reply = reply
        self.replies = list(replies or [])
        self.error = error
        self.list_error = list_error
        self.calls = []

    def execute_command(self, *args):
        self.calls.append(args)
        if args[0] == "GRAPH.LIST":
            if self.list_error is not None:
                raise self.list_error
            return [name.encode() for name in self.graph_names]
        if self.replies:
            return self.replies.pop(0)
        if self.error is not None:
            raise self.error
        return self.reply


def reply(rows):
    return [["header"], rows, []]


class GraphPresenceTests(unittest.TestCase):
    def test_presence_returns_the_newest_exact_content_match(self):
        client = FakeRedis(
            graph_names=("owner--repo",),
            reply=reply([["graph-uuid", "2026-01-01T00:00:00Z"]]),
        )
        ref = GraphStore(client=client).episode_for("owner--repo", "the content")
        self.assertEqual(ref.uuid, "graph-uuid")
        self.assertEqual(ref.created_at, "2026-01-01T00:00:00Z")
        _command, graph, query = client.calls[-1]
        self.assertEqual(graph, "owner--repo")
        self.assertTrue(query.startswith('CYPHER g="owner--repo" c="the content" '))
        self.assertIn(EPISODIC_MATCHES_QUERY, query)
        self.assertIn("ORDER BY e.created_at DESC", query)

    def test_content_with_quotes_and_newlines_is_escaped(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", 'say "hi"\nnext \\ line')
        query = client.calls[-1][2]
        self.assertIn('c="say \\"hi\\"\\nnext \\\\ line"', query)
        self.assertNotIn("\\u", query)

    def test_every_match_is_returned_newest_first(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply(
                [
                    ["ep-new", "2026-02-01T00:00:00Z"],
                    ["ep-old", "2026-01-01T00:00:00Z"],
                ]
            ),
        )
        store = GraphStore(client=client)
        self.assertEqual(store.episode_uuids("global", "c"), ["ep-new", "ep-old"])
        self.assertEqual(store.episode_for("global", "c").uuid, "ep-new")

    def test_a_since_bound_drops_an_episode_that_predates_it(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply([["ep-old", "2026-01-01T00:00:00+00:00"]]),
        )
        store = GraphStore(client=client)
        self.assertIsNone(store.episode_for("global", "c", since="2026-01-02T00:00:00Z"))
        # Tombstoning counts on the unbounded helpers still seeing it.
        self.assertEqual(store.episode_uuids("global", "c"), ["ep-old"])

    def test_a_since_bound_keeps_an_episode_at_or_after_it(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply(
                [
                    ["ep-new", "2026-01-02T00:00:00+00:00"],
                    ["ep-old", "2026-01-01T00:00:00Z"],
                ]
            ),
        )
        ref = GraphStore(client=client).episode_for("global", "c", since="2026-01-01T12:00:00Z")
        self.assertEqual(ref.uuid, "ep-new")

    def test_a_missing_graph_has_no_matches(self):
        client = FakeRedis(graph_names=("other",))
        self.assertEqual(GraphStore(client=client).episode_uuids("global", "c"), [])
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_a_missing_graph_is_empty_and_is_not_created_by_a_query(self):
        client = FakeRedis(graph_names=("global",))
        self.assertIsNone(GraphStore(client=client).episode_for("nope", "x"))
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_a_trailing_backslash_does_not_escape_the_closing_quote(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", "path C:\\")
        self.assertIn('c="path C:\\\\"', client.calls[-1][2])

    def test_a_literal_unicode_escape_is_not_decoded(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", "literal \\u0000 escape")
        query = client.calls[-1][2]
        self.assertIn('c="literal \\\\u0000 escape"', query)

    def test_unknown_content_is_absent(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        self.assertIsNone(GraphStore(client=client).episode_for("global", "x"))

    def test_contents_groups_timestamps_by_content(self):
        client = FakeRedis(
            graph_names=("owner--repo",),
            reply=reply(
                [
                    ["a", "2026-01-01T00:00:00Z"],
                    ["a", "2026-01-02T00:00:00Z"],
                    ["b", None],
                ]
            ),
        )
        contents = GraphStore(client=client).contents("owner--repo")
        self.assertEqual(contents["a"], ("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"))
        self.assertEqual(contents["b"], ("",))
        _command, graph, query = client.calls[-1]
        self.assertEqual(graph, "owner--repo")
        self.assertIn(EPISODIC_CONTENTS_QUERY, query)

    def test_contents_of_a_missing_graph_is_empty(self):
        client = FakeRedis(graph_names=("global",))
        self.assertEqual(GraphStore(client=client).contents("owner--repo"), {})
        self.assertEqual([call[0] for call in client.calls], ["GRAPH.LIST"])

    def test_contents_raises_when_the_database_is_unreachable(self):
        client = FakeRedis(list_error=RuntimeError("connection refused"))
        with self.assertRaises(GraphUnavailable):
            GraphStore(client=client).contents("owner--repo")

    def test_not_older_treats_an_unreadable_stamp_as_no_match(self):
        bound = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.assertTrue(not_older("2026-01-02T00:00:00Z", bound))
        self.assertFalse(not_older("", bound))
        self.assertFalse(not_older("not-a-time", bound))
        self.assertTrue(not_older("", None))

    def test_an_unknown_graph_error_is_an_empty_group(self):
        client = FakeRedis(
            graph_names=("nope",), error=RuntimeError("ERR Invalid graph name 'nope'")
        )
        self.assertIsNone(GraphStore(client=client).episode_for("nope", "x"))

    def test_an_unreachable_database_raises_graph_unavailable(self):
        client = FakeRedis(list_error=ConnectionError("connection refused"))
        with self.assertRaises(GraphUnavailable):
            GraphStore(client=client).episode_for("global", "x")


class TombstoneTests(unittest.TestCase):
    def test_exclusive_edges_are_invalidated_and_shared_edges_detached(self):
        client = FakeRedis(
            graph_names=("global",),
            replies=[reply([[2]]), reply([[3]])],
        )
        result = GraphStore(client=client).tombstone(
            "global", "ep-1", now="2026-01-01T00:00:00Z"
        )
        self.assertEqual((result.invalidated, result.shared), (2, 3))
        exclusive_query = client.calls[-2][2]
        shared_query = client.calls[-1][2]
        self.assertIn('ep="ep-1"', exclusive_query)
        self.assertIn('now="2026-01-01T00:00:00Z"', exclusive_query)
        self.assertIn('ep="ep-1"', shared_query)
        self.assertIn(f"r:{RELATES_TO}", exclusive_query)
        self.assertIn("size(r.episodes) <= 1", exclusive_query)
        self.assertIn("size(r.episodes) > 1", shared_query)

    def test_a_missing_graph_has_no_edges(self):
        client = FakeRedis(graph_names=("other",))
        result = GraphStore(client=client).tombstone("global", "ep-1", now="now")
        self.assertEqual((result.invalidated, result.shared), (0, 0))
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_the_edge_type_constant_is_relates_to(self):
        self.assertEqual(RELATES_TO, "RELATES_TO")


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
            source_description="sdlc issue-1#body",
            source="json",
            reference_time="2026-10-03T00:00:00Z",
        )
        self.assertEqual(result["message"], "queued")
        _headers, name, arguments = fake.calls[0]
        self.assertEqual(name, "add_memory")
        self.assertEqual(arguments["group_id"], "owner--repo")
        self.assertEqual(arguments["source"], "json")
        self.assertEqual(arguments["reference_time"], "2026-10-03T00:00:00Z")
        # graphiti-core must not receive a caller uuid for a new episode.
        self.assertNotIn("uuid", arguments)

    async def test_reference_time_is_omitted_when_unknown(self):
        backend, fake = self.backend(ToolResult(text='{"message": "queued"}', is_error=False))
        await backend.add_episode(
            name="n",
            episode_body="body",
            group_id="owner--repo",
            source_description="agent",
        )
        self.assertNotIn("reference_time", fake.calls[0][2])
        self.assertEqual(fake.calls[0][2]["source"], "text")

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
        probes = HealthProbes(llm_url="http://gateway/", embed_model="qwen3-embedding-8b", transport=transport(record=seen))

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
        probes = HealthProbes(llm_url="http://gateway", embed_model="m", transport=transport(embedder=503))

        with self.assertRaises(ReadinessError) as raised:
            await probes.require_search()
        self.assertIn("embedder unavailable", str(raised.exception))

    async def test_an_unreachable_endpoint_is_a_failure_not_an_exception(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("refused", request=request)

        probes = HealthProbes(llm_url="http://gateway", embed_model="m", transport=httpx.MockTransport(handler))

        self.assertEqual(len(await probes.failures()), 2)


if __name__ == "__main__":
    unittest.main()
