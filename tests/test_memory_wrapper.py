import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402

from memory_mcp.graphiti import BackendError  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402
from memory_mcp.readiness import ReadinessError  # noqa: E402
from memory_mcp.schema import FALLBACK_TOOLS, FALLBACK_TOOL_NAMES  # noqa: E402
from memory_mcp.store import Store  # noqa: E402
from memory_mcp.wrapper import (  # noqa: E402
    MAX_CONTENT_CHARS,
    MAX_QUERY_CHARS,
    WrapperConfig,
    build_server,
)


class FakeBackend:
    def __init__(self):
        self.added = []
        self.nodes = []
        self.facts = []
        self.episodes = []
        self.fail = False
        self.fail_facts = False
        self.status = {"status": "ok", "message": "connected"}

    async def add_episode(self, **kwargs):
        if self.fail:
            raise RuntimeError("graph exploded")
        self.added.append(kwargs)
        return {"message": "episode queued"}

    async def search_nodes(self, query, group_ids, max_nodes):
        if self.fail:
            raise RuntimeError("graph exploded")
        return self.nodes[:max_nodes]

    async def search_facts(self, query, group_ids, max_facts):
        if self.fail:
            raise RuntimeError("graph exploded")
        if self.fail_facts:
            raise BackendError("facts unavailable")
        return self.facts[:max_facts]

    async def get_episodes(self, group_ids, max_episodes):
        return self.episodes[:max_episodes]

    async def get_status(self):
        return self.status


class FakeProbes:
    def __init__(self):
        self.failures_list = []

    async def require_write(self):
        if self.failures_list:
            raise ReadinessError("; ".join(self.failures_list) + " (memory write not queued)")

    async def require_search(self):
        if any("embedder" in failure for failure in self.failures_list):
            raise ReadinessError("embedder unavailable (memory search not attempted)")

    async def failures(self):
        return list(self.failures_list)


def headers(**overrides):
    values = {
        "x-memory-group": "owner--repo",
        "x-memory-cwd": "/home/smores/code/example",
        "x-memory-actor": "maki",
    }
    values.update(overrides)
    return values


class WrapperTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)
        self.backend = FakeBackend()
        self.probes = FakeProbes()
        self.header_values = headers()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self):
        config = WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp")
        return build_server(
            config,
            backend=self.backend,
            store=self.store,
            probes=self.probes,
            headers_provider=lambda _ctx: self.header_values,
        )

    async def call(self, name, arguments):
        async with create_connected_server_and_client_session(self.build()) as session:
            return await session.call_tool(name, arguments)

    def audit(self):
        return [json.loads(line) for line in self.store.audit_path.read_text().splitlines()]

    async def test_tool_names_match_the_shim_fallback(self):
        async with create_connected_server_and_client_session(self.build()) as session:
            tools = await session.list_tools()
        names = tuple(tool.name for tool in tools.tools)
        self.assertEqual(set(names), set(FALLBACK_TOOL_NAMES))
        fallback = {tool["name"]: tool for tool in FALLBACK_TOOLS}
        for tool in tools.tools:
            self.assertEqual(tool.inputSchema.get("type"), "object")
            # Maki reads only text, and the shim proxies text; an output
            # schema would make clients demand structured content.
            self.assertIsNone(tool.outputSchema)
            fallback_schema = fallback[tool.name]["inputSchema"]
            self.assertEqual(
                set(tool.inputSchema.get("properties", {})),
                set(fallback_schema.get("properties", {})),
            )
            self.assertEqual(
                set(tool.inputSchema.get("required", [])),
                set(fallback_schema.get("required", [])),
            )

    async def test_write_stores_provenance_and_audit(self):
        result = await self.call("memory_write", {"content": "Use pytest fixtures\r\n", "tags": ["Tests!"]})
        self.assertFalse(result.isError)
        self.assertIn("Queued memory", result.content[0].text)
        added = self.backend.added[0]
        self.assertEqual(added["group_id"], "owner--repo")
        self.assertEqual(added["source"], "text")
        digest = content_hash(normalize_content("Use pytest fixtures"))
        # graphiti-core 0.31.2 treats `uuid` as a lookup of an existing episode,
        # so the wrapper keeps its uuid5 identity locally and sends it in provenance.
        self.assertNotIn("uuid", added)
        self.assertIn(f"id={episode_uuid('owner--repo', digest)}", added["source_description"])
        self.assertIn(f"hash={digest}", added["source_description"])
        self.assertIn("cwd=/home/smores/code/example", added["source_description"])
        self.assertIn("tags=tests", added["source_description"])
        self.assertEqual(added["episode_body"], "Use pytest fixtures")
        self.assertEqual(self.store.stats("owner--repo")["total"], 1)
        self.assertEqual(self.audit()[-1]["status"], "queued")

    async def test_write_dedupes_normalized_duplicates(self):
        first = await self.call("memory_write", {"content": "line one\r\nline two"})
        second = await self.call("memory_write", {"content": "line one \nline two\n\n"})
        self.assertFalse(first.isError)
        self.assertIn("Duplicate memory", second.content[0].text)
        self.assertEqual(len(self.backend.added), 1)
        self.assertEqual(self.audit()[-1]["status"], "duplicate")

    async def test_write_requires_headers(self):
        self.header_values = {}
        result = await self.call("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("X-Memory-Group", result.content[0].text)
        self.assertEqual(self.backend.added, [])

    async def test_write_requires_absolute_cwd(self):
        self.header_values = headers(**{"x-memory-cwd": "relative/path"})
        result = await self.call("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("X-Memory-Cwd", result.content[0].text)

    async def test_write_refuses_work_groups_without_calling_graph(self):
        self.header_values = headers(**{"x-memory-group": "blitzy-org--service"})
        result = await self.call("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("employer", result.content[0].text)
        self.assertEqual(self.backend.added, [])

    async def test_write_is_refused_when_models_are_down(self):
        self.probes.failures_list = ["chat model unavailable at http://127.0.0.1:8081"]
        result = await self.call("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("not queued", result.content[0].text)
        self.assertEqual(self.backend.added, [])
        self.assertEqual(self.store.stats("owner--repo")["total"], 0)

    async def test_write_rolls_back_the_index_on_graph_failure(self):
        self.backend.fail = True
        result = await self.call("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("rolled back", result.content[0].text)
        self.assertEqual(self.store.stats("owner--repo")["total"], 0)
        self.assertEqual(self.audit()[-1]["status"], "error")

    async def test_empty_content_is_a_tool_error(self):
        result = await self.call("memory_write", {"content": " \n "})
        self.assertTrue(result.isError)
        self.assertEqual(self.backend.added, [])

    async def test_oversized_content_is_rejected(self):
        result = await self.call("memory_write", {"content": "x" * (MAX_CONTENT_CHARS + 1)})
        self.assertTrue(result.isError)
        self.assertIn("limit", result.content[0].text)
        self.assertEqual(self.backend.added, [])

    async def test_oversized_query_is_rejected(self):
        result = await self.call("memory_search", {"query": "x" * (MAX_QUERY_CHARS + 1)})
        self.assertTrue(result.isError)
        self.assertIn("longer than", result.content[0].text)

    def seed(self):
        self.backend.nodes = [
            {
                "uuid": "node-1",
                "name": "FalkorDB",
                "labels": ["Entity", "Database"],
                "summary": "Graph store for memory",
                "group_id": "owner--repo",
                "created_at": "2026-02-01T12:00:00Z",
            }
        ]
        self.backend.facts = [
            {
                "uuid": "edge-1",
                "fact": "The memory stack uses FalkorDB",
                "group_id": "global",
                "valid_at": "2026-02-02T00:00:00Z",
                "episodes": ["ep-1"],
            }
        ]
        self.backend.episodes = [
            {
                "uuid": "ep-1",
                "name": "memory decision",
                "content": "decision text",
                "created_at": "2026-02-02T00:00:00Z",
                "source_description": "hash=abc; cwd=/home/smores/code/example; source=maki",
                "group_id": "global",
            }
        ]

    async def test_search_formats_quoted_memory_with_provenance(self):
        self.seed()
        result = await self.call("memory_search", {"query": "graph store", "limit": 3})
        self.assertFalse(result.isError)
        text = result.content[0].text
        self.assertIn("Quoted memory", text)
        self.assertIn("untrusted", text)
        self.assertIn("group=owner--repo", text)
        self.assertIn("group=global", text)
        self.assertIn("2026-02-01T12:00:00Z", text)
        self.assertIn("episodes: memory decision (2026-02-02T00:00:00Z)", text)
        self.assertEqual(self.audit()[-1]["status"], "ok")
        self.assertLessEqual(len(text), 6000)

    async def test_search_no_results_shape(self):
        result = await self.call("memory_search", {"query": "nothing here"})
        text = result.content[0].text
        self.assertIn("No memory results", text)
        self.assertIn("owner--repo", text)

    async def test_search_returns_partial_results_when_facts_fail(self):
        self.seed()
        self.backend.fail_facts = True
        result = await self.call("memory_search", {"query": "graph store"})
        self.assertFalse(result.isError)
        self.assertIn("FalkorDB", result.content[0].text)

    async def test_path_like_query_returns_note_without_searching(self):
        self.backend.fail = True  # would error if search were attempted
        result = await self.call("memory_search", {"query": "modules/nixos/memory.nix"})
        self.assertFalse(result.isError)
        self.assertIn("grep", result.content[0].text)
        self.assertIn("Nothing was invented", result.content[0].text)
        self.assertEqual(self.audit()[-1]["status"], "path-note")

    async def test_search_requires_the_embedder(self):
        self.probes.failures_list = ["embedder unavailable at http://127.0.0.1:8183"]
        result = await self.call("memory_search", {"query": "anything"})
        self.assertTrue(result.isError)
        self.assertIn("embedder", result.content[0].text)

    async def write(self, content="promote me"):
        return await self.call("memory_write", {"content": content})

    async def test_promote_copies_content_and_keeps_the_source(self):
        await self.write()
        entry = self.store.find("owner--repo", content_hash("promote me"))
        result = await self.call("memory_promote", {"ref": entry.content_hash[:12]})
        self.assertFalse(result.isError)
        self.assertIn("Promoted", result.content[0].text)
        promoted = self.store.lookup("global", entry.content_hash)
        self.assertIsNotNone(promoted)
        self.assertEqual(promoted.promoted_from, "owner--repo")
        self.assertEqual(self.store.lookup("owner--repo", entry.content_hash).status, "active")
        self.assertTrue(self.store.is_promoted(entry.uuid, "global"))
        self.assertIn("promoted_from=owner--repo", self.backend.added[-1]["source_description"])
        self.assertEqual(self.audit()[-1]["status"], "promoted")

        again = await self.call("memory_promote", {"ref": entry.uuid})
        self.assertIn("already promoted", again.content[0].text)
        self.assertEqual(len(self.backend.added), 2)

    async def test_promote_refuses_work_targets(self):
        await self.write()
        result = await self.call("memory_promote", {"ref": "promote me", "to": "blitzy-org--repo"})
        self.assertTrue(result.isError)
        self.assertIn("employer", result.content[0].text)

    async def test_promote_refuses_tombstoned_sources(self):
        await self.write()
        entry = self.store.find("owner--repo", content_hash("promote me"))
        await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "wrong"})
        result = await self.call("memory_promote", {"ref": entry.uuid})
        self.assertTrue(result.isError)
        self.assertIn("tombstoned", result.content[0].text)

    async def test_tombstone_is_index_only_and_idempotent(self):
        await self.write()
        entry = self.store.find("owner--repo", content_hash("promote me"))
        first = await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "superseded"})
        second = await self.call("memory_tombstone", {"ref": entry.uuid})
        self.assertIn("tombstoned", first.content[0].text)
        self.assertIn("already tombstoned", second.content[0].text)
        self.assertEqual(self.store.lookup("owner--repo", entry.content_hash).status, "tombstoned")
        self.assertEqual(len(self.backend.added), 1)

    async def test_status_reports_group_counts_and_readiness(self):
        await self.write()
        result = await self.call("memory_status", {})
        text = result.content[0].text
        self.assertIn("group: owner--repo", text)
        self.assertIn("1 active", text)
        self.assertIn("models: ok", text)
        self.assertIn("graph: ok", text)

    async def test_search_output_is_capped(self):
        self.backend.nodes = [
            {
                "uuid": f"node-{index}",
                "name": f"node {index}",
                "summary": "x" * 800,
                "group_id": "owner--repo",
                "created_at": "2026-02-01T12:00:00Z",
            }
            for index in range(10)
        ]
        self.backend.facts = [
            {
                "uuid": f"edge-{index}",
                "fact": "y" * 800,
                "group_id": "owner--repo",
                "created_at": "2026-02-01T12:00:00Z",
            }
            for index in range(10)
        ]
        result = await self.call("memory_search", {"query": "cap", "limit": 10})
        text = result.content[0].text
        self.assertLessEqual(len(text), 6000)
        self.assertIn("truncated", text)


if __name__ == "__main__":
    unittest.main()
