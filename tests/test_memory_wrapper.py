import asyncio
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402

from memory_mcp.graph import GraphUnavailable, TombstoneResult  # noqa: E402
from memory_mcp.graphiti import BackendError  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402
from memory_mcp.registry import Registry, RegistryEpisode, utcnow  # noqa: E402
from memory_mcp.schema import FALLBACK_TOOLS, FALLBACK_TOOL_NAMES  # noqa: E402
from memory_mcp.wrapper import (  # noqa: E402
    DEFAULT_TOOL_TIMEOUT,
    DEFAULT_UPSTREAM_TIMEOUT,
    MAX_CONTENT_CHARS,
    MAX_QUERY_CHARS,
    WrapperConfig,
    build_server,
    is_loopback,
)


class FakeBackend:
    def __init__(self):
        self.added = []
        self.nodes = []
        self.facts = []
        self.episodes = []
        self.fail = False
        self.fail_nodes = False
        self.fail_facts = False
        self.delay = 0.0
        self.calls = []
        self.status = {"status": "ok", "message": "connected"}

    async def _maybe_sleep(self):
        if self.delay:
            await asyncio.sleep(self.delay)

    async def add_episode(self, **kwargs):
        self.calls.append("add_episode")
        await self._maybe_sleep()
        if self.fail:
            raise RuntimeError("graph exploded")
        self.added.append(kwargs)
        return {"message": "episode queued"}

    async def search_nodes(self, query, group_ids, max_nodes):
        self.calls.append("search_nodes")
        await self._maybe_sleep()
        if self.fail or self.fail_nodes:
            raise BackendError("nodes unavailable")
        return self.nodes[:max_nodes]

    async def search_facts(self, query, group_ids, max_facts):
        self.calls.append("search_facts")
        await self._maybe_sleep()
        if self.fail or self.fail_facts:
            raise BackendError("facts unavailable")
        return self.facts[:max_facts]

    async def get_episodes(self, group_ids, max_episodes):
        self.calls.append("get_episodes")
        return self.episodes[:max_episodes]

    async def get_status(self):
        return self.status


class FakeProbes:
    def __init__(self):
        self.failures_list = []

    async def require_search(self):
        if any("embedder" in failure for failure in self.failures_list):
            raise RuntimeError("embedder unavailable (memory search not attempted)")

    async def failures(self):
        return list(self.failures_list)


class FakeGraph:
    def __init__(self):
        self.tombstoned = []
        self.result = TombstoneResult(invalidated=2, shared=1)
        self.unavailable = False

    def tombstone(self, group, episode_uuid_value, *, now):
        if self.unavailable:
            raise GraphUnavailable("connection refused")
        self.tombstoned.append((group, episode_uuid_value, now))
        return self.result


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
        self.registry = Registry(self.tmp.name)
        self.backend = FakeBackend()
        self.probes = FakeProbes()
        self.graph = FakeGraph()
        self.header_values = headers()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, **overrides):
        values = {"state_dir": self.tmp.name, "graphiti_url": "http://127.0.0.1:1/mcp"}
        values.update(overrides)
        config = WrapperConfig(**values)
        return build_server(
            config,
            backend=self.backend,
            registry=self.registry,
            probes=self.probes,
            graph=self.graph,
            headers_provider=lambda _ctx: self.header_values,
            start_reconciler=False,
        )

    async def call(self, name, arguments):
        async with create_connected_server_and_client_session(self.build()) as session:
            return await session.call_tool(name, arguments)

    def audit(self):
        import sqlite3

        with sqlite3.connect(self.registry.db_path) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(row) for row in conn.execute("SELECT * FROM audit ORDER BY id")]

    def seed_entry(self, content="promote me", **overrides):
        digest = content_hash(normalize_content(content))
        values = {
            "group": "owner--repo",
            "content_hash": digest,
            "uuid": episode_uuid("owner--repo", digest),
            "name": content,
            "content": normalize_content(content),
            "kind": "text",
            "origin": "agent",
            "origin_ref": "",
            "actor": "maki",
            "cwd": "/home/smores/code/example",
            "tags": (),
            "valid_at": "2026-10-03T00:00:00Z",
            "created_at": "2026-10-03T00:00:00Z",
            "status": "active",
        }
        values.update(overrides)
        entry = RegistryEpisode(**values)
        self.registry.insert(entry)
        return entry

    async def test_tool_names_match_the_shim_fallback(self):
        async with create_connected_server_and_client_session(self.build()) as session:
            tools = await session.list_tools()
        names = tuple(tool.name for tool in tools.tools)
        self.assertEqual(set(names), set(FALLBACK_TOOL_NAMES))
        fallback = {tool["name"]: tool for tool in FALLBACK_TOOLS}
        for tool in tools.tools:
            self.assertEqual(tool.inputSchema.get("type"), "object")
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

    async def test_write_queues_a_pending_row_and_returns_before_verification(self):
        result = await self.call("memory_write", {"content": "Use pytest fixtures\r\n", "tags": ["Tests!"]})
        self.assertFalse(result.isError)
        self.assertIn("Queued memory", result.content[0].text)
        self.assertIn("pending", result.content[0].text)
        added = self.backend.added[0]
        self.assertEqual(added["group_id"], "owner--repo")
        self.assertEqual(added["source"], "text")
        self.assertIn("reference_time", added)
        self.assertNotIn("uuid", added)
        self.assertNotIn("=", added["source_description"])
        digest = content_hash(normalize_content("Use pytest fixtures"))
        stored = self.registry.lookup("owner--repo", digest)
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.uuid, episode_uuid("owner--repo", digest))
        self.assertEqual(stored.kind, "text")
        self.assertEqual(stored.origin, "agent")
        self.assertEqual(stored.valid_at, added["reference_time"])
        self.assertRegex(stored.valid_at, r"^\d{4}-\d{2}-\d{2}T")
        self.assertEqual(self.audit()[-1]["status"], "queued")

    async def test_write_does_not_gate_on_model_readiness(self):
        self.probes.failures_list = ["chat model unavailable at http://127.0.0.1:8082"]
        result = await self.call("memory_write", {"content": "offline write"})
        self.assertFalse(result.isError)
        self.assertEqual(len(self.backend.added), 1)
        self.assertEqual(self.registry.stats("owner--repo")["pending"], 1)

    async def test_write_dedupes_an_active_row(self):
        entry = self.seed_entry(status="active")
        result = await self.call("memory_write", {"content": "promote me"})
        self.assertIn("Duplicate memory", result.content[0].text)
        self.assertIn(entry.uuid, result.content[0].text)
        self.assertEqual(self.backend.added, [])
        self.assertEqual(self.audit()[-1]["status"], "duplicate")

    async def test_a_fresh_pending_write_is_already_queued(self):
        entry = self.seed_entry(status="pending", created_at=utcnow())
        result = await self.call("memory_write", {"content": "promote me"})
        self.assertFalse(result.isError)
        self.assertIn("already queued", result.content[0].text)
        self.assertEqual(self.backend.added, [])
        self.assertEqual(self.registry.lookup("owner--repo", entry.content_hash).attempts, 0)
        self.assertEqual(self.audit()[-1]["status"], "pending")

    async def test_a_stale_pending_write_is_resubmitted(self):
        self.seed_entry(status="pending", created_at="2000-01-01T00:00:00Z")
        result = await self.call("memory_write", {"content": "promote me"})
        self.assertFalse(result.isError)
        self.assertIn("Re-queued", result.content[0].text)
        self.assertEqual(len(self.backend.added), 1)
        self.assertEqual(self.audit()[-1]["status"], "retried")

    async def test_writing_tombstoned_content_revives_it(self):
        self.seed_entry(status="tombstoned", tombstoned_at="2026-01-01T00:00:00Z")
        result = await self.call("memory_write", {"content": "promote me"})
        self.assertIn("Revived", result.content[0].text)
        self.assertEqual(len(self.backend.added), 1)
        stored = self.registry.lookup("owner--repo", content_hash(normalize_content("promote me")))
        self.assertEqual(stored.status, "pending")
        self.assertIsNone(stored.tombstoned_at)
        self.assertEqual(self.audit()[-1]["status"], "revived")

    async def test_a_graph_submission_failure_keeps_the_row_pending(self):
        self.backend.fail = True
        result = await self.call("memory_write", {"content": "deferred"})
        self.assertFalse(result.isError)
        self.assertIn("deferred", result.content[0].text)
        stored = self.registry.lookup("owner--repo", content_hash("deferred"))
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 1)
        self.assertIn("graph exploded", stored.last_error)

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

    async def test_empty_and_oversized_content_are_tool_errors(self):
        empty = await self.call("memory_write", {"content": " \n "})
        self.assertTrue(empty.isError)
        oversized = await self.call("memory_write", {"content": "x" * (MAX_CONTENT_CHARS + 1)})
        self.assertTrue(oversized.isError)
        self.assertIn("limit", oversized.content[0].text)
        self.assertEqual(self.backend.added, [])

    async def test_oversized_query_is_rejected(self):
        result = await self.call("memory_search", {"query": "x" * (MAX_QUERY_CHARS + 1)})
        self.assertTrue(result.isError)
        self.assertIn("longer than", result.content[0].text)

    def seed_episode_row(self):
        digest = content_hash("decision text")
        entry = RegistryEpisode(
            group="global",
            content_hash=digest,
            uuid=episode_uuid("global", digest),
            name="memory decision",
            content="decision text",
            kind="text",
            origin="sdlc",
            origin_ref="smores56/sdlc#215#design",
            actor="ingest",
            cwd="",
            tags=("sdlc",),
            valid_at="2026-10-03T00:00:00Z",
            created_at="2026-10-04T00:00:00Z",
            status="active",
            graphiti_uuid="ep-1",
        )
        self.registry.insert(entry)
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
                "group_id": "global",
            }
        ]
        return entry

    async def test_search_renders_typed_provenance_tags(self):
        entry = self.seed_episode_row()
        result = await self.call("memory_search", {"query": "graph store", "limit": 3})
        self.assertFalse(result.isError)
        text = result.content[0].text
        self.assertIn("Quoted memory", text)
        self.assertIn("group=owner--repo", text)
        self.assertIn("group=global", text)
        self.assertIn("[sdlc smores56/sdlc#215#design · 2026-10-03]", text)
        self.assertIn(f"id={entry.uuid}", text)
        self.assertNotIn("hash=", text)
        self.assertEqual(self.audit()[-1]["status"], "ok")
        self.assertLessEqual(len(text), 6000)

    async def test_search_no_results_shape(self):
        result = await self.call("memory_search", {"query": "nothing here"})
        text = result.content[0].text
        self.assertIn("No memory results", text)
        self.assertIn("owner--repo", text)

    async def test_search_partial_results_when_facts_fail(self):
        self.seed_episode_row()
        self.backend.fail_facts = True
        result = await self.call("memory_search", {"query": "graph store"})
        self.assertFalse(result.isError)
        self.assertIn("Partial results", result.content[0].text)
        self.assertEqual(self.audit()[-1]["status"], "partial")

    async def test_search_only_errors_when_both_upstreams_fail(self):
        self.seed_episode_row()
        self.backend.fail_nodes = True
        self.backend.fail_facts = True
        result = await self.call("memory_search", {"query": "graph store"})
        self.assertTrue(result.isError)

    async def test_search_requires_the_embedder(self):
        self.probes.failures_list = ["embedder unavailable at http://127.0.0.1:8183"]
        result = await self.call("memory_search", {"query": "anything"})
        self.assertTrue(result.isError)
        self.assertIn("embedder", result.content[0].text)

    async def test_path_like_query_appends_a_note(self):
        self.seed_episode_row()
        result = await self.call("memory_search", {"query": "modules/nixos/memory.nix"})
        self.assertIn("FTS", result.content[0].text)
        self.assertTrue(json.loads(self.audit()[-1]["details"])["path_like"])

    async def test_get_accepts_uuid_hash_prefix_and_origin_ref(self):
        entry = self.seed_entry(origin="sdlc", origin_ref="issue-215#design")
        for ref in (entry.uuid, entry.content_hash[:12], "sdlc:issue-215#design"):
            with self.subTest(ref=ref):
                result = await self.call("memory_get", {"ref": ref})
                self.assertFalse(result.isError)
                self.assertIn(entry.content, result.content[0].text)
                self.assertIn(f"Memory {entry.uuid}", result.content[0].text)
        missing = await self.call("memory_get", {"ref": entry.name})
        self.assertTrue(missing.isError)
        self.assertIn("no stored episode", missing.content[0].text)

    async def test_retry_resets_a_failed_row_and_resubmits(self):
        entry = self.seed_entry(status="failed", attempts=3, last_error="absent")
        result = await self.call("memory_retry", {"ref": entry.uuid})
        self.assertFalse(result.isError)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 1)
        self.assertIsNone(stored.last_error)
        self.assertEqual(len(self.backend.added), 1)

    async def test_retry_rejects_non_failed_rows(self):
        entry = self.seed_entry(status="active")
        result = await self.call("memory_retry", {"ref": entry.uuid})
        self.assertTrue(result.isError)
        self.assertIn("only failed", result.content[0].text)

    async def test_tombstone_invalidates_exclusive_and_shared_edges(self):
        entry = self.seed_entry(status="active", graphiti_uuid="graph-1")
        result = await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "superseded"})
        self.assertFalse(result.isError)
        text = result.content[0].text
        self.assertIn("Invalidated 2 exclusive edge(s)", text)
        self.assertIn("detached from 1 shared edge(s)", text)
        self.assertEqual(self.graph.tombstoned[0][0], "owner--repo")
        self.assertEqual(self.graph.tombstoned[0][1], "graph-1")
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "tombstoned")
        self.assertEqual(stored.tombstone_reason, "superseded")

    async def test_tombstone_keeps_the_row_when_the_graph_is_unavailable(self):
        entry = self.seed_entry(status="active", graphiti_uuid="graph-1")
        self.graph.unavailable = True
        result = await self.call("memory_tombstone", {"ref": entry.uuid})
        self.assertTrue(result.isError)
        self.assertIn("not applied", result.content[0].text)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "active")

    async def test_tombstone_without_a_graph_uuid_is_registry_only(self):
        entry = self.seed_entry(status="failed", graphiti_uuid=None)
        result = await self.call("memory_tombstone", {"ref": entry.uuid})
        self.assertFalse(result.isError)
        self.assertEqual(self.graph.tombstoned, [])
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned")

    async def test_tombstone_is_idempotent_and_audited(self):
        entry = self.seed_entry(status="active", graphiti_uuid="graph-1")
        first = await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "first"})
        second = await self.call("memory_tombstone", {"ref": entry.uuid})
        self.assertIn("tombstoned", first.content[0].text)
        self.assertIn("already tombstoned", second.content[0].text)
        self.assertEqual(len(self.graph.tombstoned), 1)
        self.assertEqual([row["status"] for row in self.audit()[-2:]], ["tombstoned", "duplicate"])

    async def test_promote_copies_type_and_content_into_global(self):
        entry = self.seed_entry(
            status="active", origin="sdlc", origin_ref="issue-1#body", kind="json", content='{"a": 1}'
        )
        result = await self.call("memory_promote", {"ref": entry.uuid})
        self.assertFalse(result.isError)
        self.assertIn("Promoted", result.content[0].text)
        promoted = self.registry.lookup("global", entry.content_hash)
        self.assertIsNotNone(promoted)
        self.assertEqual(promoted.kind, "json")
        self.assertEqual(promoted.origin, "sdlc")
        self.assertEqual(promoted.origin_ref, "issue-1#body")
        self.assertEqual(promoted.promoted_from_group, "owner--repo")
        self.assertEqual(promoted.promoted_by, "maki")
        self.assertEqual(promoted.status, "pending")
        self.assertEqual(self.backend.added[-1]["group_id"], "global")
        self.assertEqual(self.backend.added[-1]["source"], "json")
        self.assertTrue(self.registry.is_promoted(entry.uuid, "global"))
        again = await self.call("memory_promote", {"ref": entry.uuid})
        self.assertIn("already promoted", again.content[0].text)

    async def test_promote_rejects_non_global_targets_and_tombstoned_sources(self):
        entry = self.seed_entry()
        for target in ("other--repo", "owner--repo", "local--scratch"):
            with self.subTest(target=target):
                result = await self.call("memory_promote", {"ref": entry.uuid, "to": target})
                self.assertTrue(result.isError)
                self.assertIn("global group", result.content[0].text)
        tombstoned = self.seed_entry(content="gone", status="tombstoned")
        result = await self.call("memory_promote", {"ref": tombstoned.uuid})
        self.assertTrue(result.isError)
        self.assertIn("tombstoned", result.content[0].text)

    async def test_promote_refuses_work_targets(self):
        entry = self.seed_entry()
        result = await self.call("memory_promote", {"ref": entry.uuid, "to": "blitzy-org--repo"})
        self.assertTrue(result.isError)
        self.assertIn("employer", result.content[0].text)

    async def test_status_reports_registry_counts(self):
        self.seed_entry(status="active")
        await self.call("memory_write", {"content": "pending one"})
        result = await self.call("memory_status", {})
        text = result.content[0].text
        self.assertIn("group: owner--repo", text)
        self.assertIn("1 active", text)
        self.assertIn("pending", text)
        self.assertIn("models: ok", text)
        self.assertIn("graph: ok", text)

    async def test_cwd_is_sanitized_before_use(self):
        self.header_values = headers(
            **{"x-memory-cwd": "/home/smores/\x1b[31mcode\x1b[0m\u202e\n/etc/passwd"}
        )
        result = await self.call("memory_write", {"content": "sanitized cwd"})
        self.assertFalse(result.isError)
        stored = self.registry.lookup("owner--repo", content_hash("sanitized cwd"))
        self.assertEqual(stored.cwd, "/home/smores/code")
        self.assertIn("cwd: /home/smores/code", (await self.call("memory_status", {})).content[0].text)

    async def test_a_hung_write_times_out_and_audits(self):
        self.backend.delay = 5
        async with create_connected_server_and_client_session(self.build(tool_timeout=0.05)) as session:
            result = await session.call_tool("memory_write", {"content": "slow"})
        self.assertTrue(result.isError)
        self.assertIn("timed out", result.content[0].text)
        self.assertEqual(self.audit()[-1]["status"], "timeout")

    def test_timeout_constants_fit_the_client_budgets(self):
        self.assertLessEqual(DEFAULT_UPSTREAM_TIMEOUT, 25)
        self.assertEqual(DEFAULT_TOOL_TIMEOUT, 60)
        self.assertGreater(DEFAULT_TOOL_TIMEOUT, DEFAULT_UPSTREAM_TIMEOUT)

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


class InternalRouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)
        self.backend = FakeBackend()
        server = build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            backend=self.backend,
            registry=self.registry,
            probes=FakeProbes(),
            graph=FakeGraph(),
            start_reconciler=False,
        )
        self.client = TestClient(server.streamable_http_app())

    def tearDown(self):
        self.client.close()
        self.tmp.cleanup()

    def test_loopback_detection(self):
        self.assertTrue(is_loopback("127.0.0.1"))
        self.assertTrue(is_loopback("::1"))
        self.assertFalse(is_loopback("10.0.0.1"))
        self.assertFalse(is_loopback(None))

    def test_internal_routes_reject_non_loopback_peers(self):
        response = self.client.post(
            "/internal/episodes", json={"group": "global", "content": "x"}
        )
        self.assertEqual(response.status_code, 403)
        response = self.client.post(
            "/internal/lookup", json={"group": "global", "hashes": ["a" * 64]}
        )
        self.assertEqual(response.status_code, 403)

    def test_episodes_payload_validation(self):
        with mock.patch("memory_mcp.wrapper.is_loopback", return_value=True):
            cases = [
                ({"content": "x"}, "group"),
                ({"group": "global"}, "content"),
                ({"group": "global", "content": "x", "kind": "binary"}, "kind"),
                ({"group": "global", "content": "x", "origin": "web"}, "origin"),
                ({"group": "global", "content": "x", "valid_at": "yesterday"}, "valid_at"),
                ({"group": "global", "content": "x", "tags": "one"}, "tags"),
                ({"group": "blitzy-ai--repo", "content": "x"}, "employer"),
            ]
            for payload, needle in cases:
                with self.subTest(payload=payload):
                    response = self.client.post("/internal/episodes", json=payload)
                    self.assertEqual(response.status_code, 400)
                    self.assertIn(needle, response.json()["error"])

    def test_episodes_accepts_a_typed_payload(self):
        payload = {
            "group": "smores56--nix-config",
            "content": '{"legacy": true}',
            "kind": "json",
            "origin": "sdlc",
            "origin_ref": "issue-215#migration",
            "valid_at": "2026-10-03T12:00:00Z",
            "tags": ["sdlc"],
            "actor": "ingest",
        }
        with mock.patch("memory_mcp.wrapper.is_loopback", return_value=True):
            response = self.client.post("/internal/episodes", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "queued")
        self.assertEqual(body["group"], "smores56--nix-config")
        self.assertEqual(body["content_hash"], content_hash('{"legacy": true}'))
        self.assertIn("Queued memory", body["text"])
        stored = self.registry.lookup("smores56--nix-config", body["content_hash"])
        self.assertEqual(stored.kind, "json")
        self.assertEqual(stored.origin, "sdlc")
        self.assertEqual(stored.origin_ref, "issue-215#migration")
        self.assertEqual(stored.valid_at, "2026-10-03T12:00:00Z")
        self.assertEqual(stored.actor, "ingest")
        self.assertEqual(self.backend.added[-1]["source"], "json")
        self.assertEqual(self.backend.added[-1]["reference_time"], "2026-10-03T12:00:00Z")

    def test_lookup_returns_typed_state_for_each_hash(self):
        entry = RegistryEpisode(
            group="global",
            content_hash="a" * 64,
            uuid=episode_uuid("global", "a" * 64),
            name="n",
            content="c",
            kind="text",
            origin="notes",
            origin_ref="note:a.md#body",
            actor="ingest",
            cwd="",
            tags=(),
            valid_at="2026-01-01T00:00:00Z",
            created_at="2026-01-01T00:00:00Z",
            status="active",
            graphiti_uuid="graph-1",
        )
        self.registry.insert(entry)
        with mock.patch("memory_mcp.wrapper.is_loopback", return_value=True):
            response = self.client.post(
                "/internal/lookup",
                json={"group": "global", "hashes": ["a" * 64, "b" * 64]},
            )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["a" * 64]["status"], "active")
        self.assertEqual(body["a" * 64]["graphiti_uuid"], "graph-1")
        self.assertEqual(body["a" * 64]["uuid"], entry.uuid)
        self.assertEqual(body["b" * 64]["status"], "missing")
        self.assertIsNone(body["b" * 64]["graphiti_uuid"])

    def test_lookup_validates_group_and_hashes(self):
        with mock.patch("memory_mcp.wrapper.is_loopback", return_value=True):
            bad_hash = self.client.post(
                "/internal/lookup", json={"group": "global", "hashes": ["xyz"]}
            )
            self.assertEqual(bad_hash.status_code, 400)
            bad_group = self.client.post(
                "/internal/lookup", json={"group": "blitzy-ai--repo", "hashes": ["a" * 64]}
            )
            self.assertEqual(bad_group.status_code, 400)
            self.assertIn("employer", bad_group.json()["error"])


if __name__ == "__main__":
    unittest.main()
