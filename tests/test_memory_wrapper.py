import asyncio
import json
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402

from memory_mcp.graph import EpisodeRef, GraphUnavailable, TombstoneResult  # noqa: E402
from memory_mcp.graphiti import BackendError  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402
from memory_mcp.registry import Registry, RegistryEpisode, utcnow  # noqa: E402
from memory_mcp.reconciler import InFlight, Reconciler, ReconcilerConfig  # noqa: E402
from memory_mcp.schema import FALLBACK_TOOLS, FALLBACK_TOOL_NAMES  # noqa: E402
from memory_mcp.wrapper import (  # noqa: E402
    DEFAULT_TOOL_TIMEOUT,
    DEFAULT_UPSTREAM_TIMEOUT,
    MAX_CONTENT_CHARS,
    MAX_INTERNAL_BODY_BYTES,
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
        self.uuids = []
        self.present = None

    def _check(self):
        if self.unavailable:
            raise GraphUnavailable("connection refused")

    def episode_uuids(self, group, content):
        self._check()
        return list(self.uuids)

    def episode_for(self, group, content):
        self._check()
        return self.present

    def tombstone(self, group, episode_uuid_value, *, now):
        self._check()
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
        ).mcp

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
        return self.store(RegistryEpisode(**values))

    def store(self, entry: RegistryEpisode) -> RegistryEpisode:
        """Store a row in any status through the registry's public transitions."""
        stored = self.registry.queue(entry)
        if entry.status == "active" or entry.graphiti_uuid:
            self.registry.mark_active(
                entry.group,
                entry.content_hash,
                entry.graphiti_uuid or f"graph-{entry.content_hash[:12]}",
            )
        if entry.status == "failed":
            self.registry.mark_failed(
                entry.group, entry.content_hash, entry.last_error or "seeded"
            )
        elif entry.status == "tombstoned":
            self.registry.tombstone(stored, reason=entry.tombstone_reason or "seeded")
        elif entry.status == "pending":
            for _ in range(entry.attempts):
                self.registry.record_attempt(entry.group, entry.content_hash)
        return stored

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
        self.store(entry)
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

    async def test_a_second_tombstone_invalidates_the_revived_episode(self):
        entry = self.seed_entry(status="active", content="revived", graphiti_uuid="graph-old")
        self.graph.uuids = ["graph-old"]
        first = await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "first"})
        self.assertFalse(first.isError)

        revived = await self.call("memory_write", {"content": "revived"})
        self.assertIn("Revived", revived.content[0].text)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "pending")

        # The revival re-extracted: both the old and the new episode now match.
        self.graph.uuids = ["graph-new", "graph-old"]
        second = await self.call("memory_tombstone", {"ref": entry.uuid, "reason": "second"})
        self.assertFalse(second.isError)
        self.assertEqual(
            [call[1] for call in self.graph.tombstoned],
            ["graph-old", "graph-new", "graph-old"],
        )
        self.assertIn("Invalidated 4 exclusive edge(s)", second.content[0].text)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "tombstoned")
        self.assertEqual(stored.tombstone_reason, "second")

    async def test_tombstoning_a_pending_row_writes_no_graph_state(self):
        entry = self.seed_entry(content="never landed", status="pending")
        result = await self.call("memory_tombstone", {"ref": entry.uuid})
        self.assertFalse(result.isError)
        self.assertEqual(self.graph.tombstoned, [])
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned")

        # Even if the extraction lands afterwards, the reconciler must not
        # resurrect the row.
        self.graph.present = EpisodeRef(uuid="graph-1", created_at="2026-10-03T00:10:00Z")
        reconciler = Reconciler(
            self.registry,
            self.graph,
            self.backend,
            self.probes,
            config=ReconcilerConfig(grace=0, backoff=0),
        )
        counts = await reconciler.reconcile_once()
        self.assertEqual(counts["active"], 0)
        self.assertEqual(counts["retried"], 0)
        self.assertEqual(
            self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned"
        )

    async def test_retry_marks_a_late_landed_episode_active_instead_of_resubmitting(self):
        entry = self.seed_entry(status="failed", attempts=3, last_error="absent")
        self.graph.present = EpisodeRef(uuid="graph-late", created_at="2026-10-03T00:10:00Z")
        result = await self.call("memory_retry", {"ref": entry.uuid})
        self.assertFalse(result.isError)
        self.assertIn("already in the graph", result.content[0].text)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "graph-late")
        self.assertEqual(self.backend.added, [])

    async def test_an_ambiguous_hash_prefix_is_a_clear_error(self):
        for digest in ("a" * 64, "a" * 63 + "b"):
            self.store(
                RegistryEpisode(
                    group="owner--repo",
                    content_hash=digest,
                    uuid=episode_uuid("owner--repo", digest),
                    name=digest[:6],
                    content=digest[:6],
                    kind="text",
                    origin="agent",
                    origin_ref="",
                    actor="maki",
                    cwd="",
                    tags=(),
                    valid_at="2026-10-03T00:00:00Z",
                    created_at="2026-10-03T00:00:00Z",
                )
            )
        result = await self.call("memory_get", {"ref": "A" * 12})
        self.assertTrue(result.isError)
        self.assertIn("matches more than one episode", result.content[0].text)

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
    TOKEN = "test-internal-token"

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
            internal_token=self.TOKEN,
        )
        self.app = server.streamable_http_app()
        # The tunnel forwards raw TCP to loopback, so Starlette sees 127.0.0.1
        # for every tunneled request: the peer address proves nothing.
        self.local = TestClient(self.app, client=("127.0.0.1", 40000))
        self.remote = TestClient(self.app, client=("10.0.0.1", 40000))

    def tearDown(self):
        self.local.close()
        self.remote.close()
        self.tmp.cleanup()

    @property
    def auth(self):
        return {"Authorization": f"Bearer {self.TOKEN}"}

    def audit(self):
        import sqlite3

        with sqlite3.connect(self.registry.db_path) as conn:
            return conn.execute("SELECT tool, status FROM audit").fetchall()

    def test_loopback_detection(self):
        self.assertTrue(is_loopback("127.0.0.1"))
        self.assertTrue(is_loopback("::1"))
        self.assertFalse(is_loopback("10.0.0.1"))
        self.assertFalse(is_loopback(None))

    def test_internal_routes_reject_non_loopback_peers(self):
        response = self.remote.post(
            "/internal/episodes", json={"group": "global", "content": "x"}, headers=self.auth
        )
        self.assertEqual(response.status_code, 403)
        self.assertIn("loopback", response.json()["error"])
        response = self.remote.post(
            "/internal/lookup", json={"group": "global", "hashes": ["a" * 64]}, headers=self.auth
        )
        self.assertEqual(response.status_code, 403)
        self.assertIn("loopback", response.json()["error"])

    def test_a_tunneled_request_without_the_token_is_rejected(self):
        for path, payload in (
            ("/internal/episodes", {"group": "global", "content": "tunneled"}),
            ("/internal/lookup", {"group": "global", "hashes": ["a" * 64]}),
        ):
            with self.subTest(path=path):
                response = self.local.post(path, json=payload)
                self.assertEqual(response.status_code, 403)
                self.assertIn("internal token", response.json()["error"])
        self.assertEqual(self.registry.stats("global")["total"], 0)
        self.assertEqual(self.backend.added, [])
        self.assertEqual(self.audit(), [])

    def test_a_wrong_or_malformed_token_is_rejected(self):
        for header in (
            {"Authorization": "Bearer wrong"},
            {"Authorization": self.TOKEN},
            {"Authorization": ""},
        ):
            with self.subTest(header=header):
                response = self.local.post(
                    "/internal/episodes",
                    json={"group": "global", "content": "nope"},
                    headers=header,
                )
                self.assertEqual(response.status_code, 403)
        self.assertEqual(self.registry.stats("global")["total"], 0)
        self.assertEqual(self.backend.added, [])

    def test_the_server_writes_a_group_readable_token_at_startup(self):
        with tempfile.TemporaryDirectory() as state_dir:
            build_server(
                WrapperConfig(state_dir=state_dir, graphiti_url="http://127.0.0.1:1/mcp"),
                backend=self.backend,
                registry=Registry(state_dir),
                probes=FakeProbes(),
                graph=FakeGraph(),
                start_reconciler=False,
            )
            path = Path(state_dir) / "internal.token"
            self.assertTrue(path.exists())
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertTrue(path.read_text(encoding="utf-8").strip())

    def test_episodes_payload_validation(self):
        cases = [
            ({"content": "x"}, "group"),
            ({"group": "global"}, "content"),
            ({"group": "global", "content": "x", "kind": "binary"}, "kind"),
            ({"group": "global", "content": "x", "origin": "web"}, "origin"),
            ({"group": "global", "content": "x", "valid_at": "yesterday"}, "valid_at"),
            ({"group": "global", "content": "x", "tags": "one"}, "tags"),
            ({"group": "global", "content": "x\x00y"}, "NUL"),
            ({"group": "blitzy-ai--repo", "content": "x"}, "employer"),
        ]
        for payload, needle in cases:
            with self.subTest(payload=payload):
                response = self.local.post("/internal/episodes", json=payload, headers=self.auth)
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
        response = self.local.post("/internal/episodes", json=payload, headers=self.auth)
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

    def test_an_oversized_body_is_rejected_before_it_is_parsed(self):
        payload = {"group": "global", "content": "x" * (MAX_INTERNAL_BODY_BYTES + 1)}
        response = self.local.post("/internal/episodes", json=payload, headers=self.auth)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.registry.stats("global")["total"], 0)
        self.assertEqual(self.backend.added, [])

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
        self.registry.queue(entry)
        self.registry.mark_active("global", entry.content_hash, "graph-1")
        response = self.local.post(
            "/internal/lookup",
            json={"group": "global", "hashes": ["a" * 64, "b" * 64]},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["a" * 64]["status"], "active")
        self.assertEqual(body["a" * 64]["graphiti_uuid"], "graph-1")
        self.assertEqual(body["a" * 64]["uuid"], entry.uuid)
        self.assertEqual(body["b" * 64]["status"], "missing")
        self.assertIsNone(body["b" * 64]["graphiti_uuid"])

    def test_lookup_answers_every_hash_in_one_request(self):
        digests = [f"{index:064x}" for index in range(1, 4)]
        for digest in digests[:2]:
            self.registry.queue(
                RegistryEpisode(
                    group="global",
                    content_hash=digest,
                    uuid=episode_uuid("global", digest),
                    name="n",
                    content="c",
                    kind="text",
                    origin="notes",
                    origin_ref="",
                    actor="ingest",
                    cwd="",
                    tags=(),
                    valid_at="2026-01-01T00:00:00Z",
                    created_at="2026-01-01T00:00:00Z",
                )
            )
        response = self.local.post(
            "/internal/lookup", json={"group": "global", "hashes": digests}, headers=self.auth
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(set(body), set(digests))
        self.assertEqual(body[digests[0]]["status"], "pending")
        self.assertEqual(body[digests[2]]["status"], "missing")

    def test_lookup_validates_group_and_hashes(self):
        bad_hash = self.local.post(
            "/internal/lookup", json={"group": "global", "hashes": ["xyz"]}, headers=self.auth
        )
        self.assertEqual(bad_hash.status_code, 400)
        bad_group = self.local.post(
            "/internal/lookup",
            json={"group": "blitzy-ai--repo", "hashes": ["a" * 64]},
            headers=self.auth,
        )
        self.assertEqual(bad_group.status_code, 400)
        self.assertIn("employer", bad_group.json()["error"])


class ReconcilerLifespanTests(unittest.TestCase):
    """The reconciler must run under the transport production actually uses.

    FastMCP 1.27 builds the streamable-HTTP Starlette app with its own lifespan
    (`session_manager.run()`) and drops the lifespan passed to `FastMCP(...)`,
    so a reconciler started there would never run: every write would sit
    `pending` forever even after the graph extracted it.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)
        self.graph = FakeGraph()
        self.reconciler = Reconciler(
            self.registry,
            self.graph,
            FakeBackend(),
            FakeProbes(),
            config=ReconcilerConfig(interval=0.02, grace=600, backoff=0, max_retries=2),
        )

    def tearDown(self):
        self.tmp.cleanup()

    def seed_pending(self, content="reconciler probe"):
        digest = content_hash(content)
        entry = RegistryEpisode(
            group="owner--repo",
            content_hash=digest,
            uuid=episode_uuid("owner--repo", digest),
            name=content,
            content=content,
            kind="text",
            origin="agent",
            origin_ref="",
            actor="maki",
            cwd="",
            tags=(),
            valid_at="2026-10-22T09:00:00Z",
            created_at=utcnow(),
            status="pending",
            attempts=1,
        )
        self.registry.queue(entry)
        return entry

    def wait_for(self, predicate, *, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.02)
        return False

    def test_the_streamable_http_app_promotes_a_landed_episode(self):
        entry = self.seed_pending()
        self.graph.present = EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")
        runtime = build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            registry=self.registry,
            probes=FakeProbes(),
            graph=self.graph,
            reconciler=self.reconciler,
        )
        with TestClient(runtime.streamable_http_app()):
            landed = self.wait_for(
                lambda: self.registry.lookup(entry.group, entry.content_hash).status == "active"
            )
        self.assertTrue(landed, "the reconciler never ran under streamable-http")

    def test_stopping_the_app_cancels_the_reconciler(self):
        class SpyReconciler:
            def __init__(self):
                self.in_flight = InFlight()
                self.cancelled = False

            async def run(self):
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    self.cancelled = True
                    raise

        spy = SpyReconciler()
        runtime = build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            registry=self.registry,
            probes=FakeProbes(),
            graph=self.graph,
            reconciler=spy,
        )
        with TestClient(runtime.streamable_http_app()):
            pass
        self.assertTrue(spy.cancelled, "shutdown left the reconciler running")

    def test_a_crashed_reconciler_does_not_fail_shutdown(self):
        class CrashingReconciler:
            in_flight = InFlight()

            async def run(self):
                raise RuntimeError("loop exploded")

        runtime = build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            registry=self.registry,
            probes=FakeProbes(),
            graph=self.graph,
            reconciler=CrashingReconciler(),
        )
        with TestClient(runtime.streamable_http_app()):
            pass


if __name__ == "__main__":
    unittest.main()
