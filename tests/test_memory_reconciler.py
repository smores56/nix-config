import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.graph import EpisodeRef, GraphUnavailable  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid  # noqa: E402
from memory_mcp.reconciler import InFlight, Reconciler, ReconcilerConfig  # noqa: E402
from memory_mcp.registry import Registry, RegistryEpisode  # noqa: E402

NOW = datetime(2026, 10, 22, 12, 0, 0, tzinfo=timezone.utc)


class FakeGraph:
    def __init__(self, results=None, *, error=False):
        self.results = list(results or [])
        self.error = error
        self.calls = []

    def episode_for(self, group, content):
        self.calls.append((group, content))
        if self.error:
            raise GraphUnavailable("connection refused")
        return self.results.pop(0) if self.results else None


class FakeBackend:
    def __init__(self, *, fail=False):
        self.added = []
        self.fail = fail

    async def add_episode(self, **kwargs):
        if self.fail:
            raise RuntimeError("graph exploded")
        self.added.append(kwargs)
        return {"message": "queued"}


class FakeProbes:
    def __init__(self, failures=None):
        self.failures_list = list(failures or [])

    async def failures(self):
        return list(self.failures_list)


class Clock:
    def __init__(self, value=1000.0):
        self.value = value

    def __call__(self):
        return self.value


class ReconcilerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)
        self.clock = Clock()

    def tearDown(self):
        self.tmp.cleanup()

    def entry(self, *, created_at="2026-10-22T10:00:00Z", attempts=1, status="pending", **overrides):
        digest = content_hash("the content")
        values = {
            "group": "owner--repo",
            "content_hash": digest,
            "uuid": episode_uuid("owner--repo", digest),
            "name": "the content",
            "content": "the content",
            "kind": "text",
            "origin": "agent",
            "origin_ref": "",
            "actor": "maki",
            "cwd": "",
            "tags": (),
            "valid_at": "2026-10-22T09:00:00Z",
            "created_at": created_at,
            "status": status,
            "attempts": attempts,
        }
        values.update(overrides)
        entry = RegistryEpisode(**values)
        self.registry.insert(entry)
        return entry

    def reconciler(self, graph, backend=None, *, probes=None, in_flight=None, config=None):
        return Reconciler(
            self.registry,
            graph,
            backend or FakeBackend(),
            probes or FakeProbes(),
            config=config or ReconcilerConfig(grace=600, backoff=60, max_retries=2),
            in_flight=in_flight,
            clock=self.clock,
            now=lambda: NOW,
        )

    async def test_a_found_episode_becomes_active_with_the_graph_uuid(self):
        entry = self.entry()
        graph = FakeGraph([EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")])
        counts = await self.reconciler(graph).reconcile_once()
        self.assertEqual(counts["active"], 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "graph-1")

    async def test_a_pending_row_within_the_grace_window_waits(self):
        entry = self.entry(created_at="2026-10-22T11:55:00Z")
        counts = await self.reconciler(FakeGraph()).reconcile_once()
        self.assertEqual(counts["waiting"], 1)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "pending")

    async def test_absent_past_grace_is_retried_once_per_pass(self):
        entry = self.entry()
        backend = FakeBackend()
        counts = await self.reconciler(FakeGraph(), backend).reconcile_once()
        self.assertEqual(counts["retried"], 1)
        self.assertEqual(len(backend.added), 1)
        self.assertEqual(backend.added[0]["source"], "text")
        self.assertEqual(backend.added[0]["reference_time"], entry.valid_at)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 2)

    async def test_retries_are_bounded_and_end_failed(self):
        entry = self.entry(attempts=3)
        backend = FakeBackend()
        counts = await self.reconciler(FakeGraph(), backend).reconcile_once()
        self.assertEqual(counts["failed"], 1)
        self.assertEqual(backend.added, [])
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "failed")
        self.assertIn("absent from the graph", stored.last_error)

    async def test_retries_pause_while_the_model_is_unhealthy(self):
        entry = self.entry()
        backend = FakeBackend()
        counts = await self.reconciler(
            FakeGraph(), backend, probes=FakeProbes(["chat model unavailable"])
        ).reconcile_once()
        self.assertEqual(counts["paused"], 1)
        self.assertEqual(backend.added, [])
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "pending")

    async def test_a_found_episode_still_resolves_while_unhealthy(self):
        entry = self.entry()
        graph = FakeGraph([EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")])
        counts = await self.reconciler(graph, probes=FakeProbes(["down"])).reconcile_once()
        self.assertEqual(counts["active"], 1)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).graphiti_uuid, "graph-1")

    async def test_an_in_flight_submission_is_not_retried(self):
        entry = self.entry()
        in_flight = InFlight()
        self.assertTrue(in_flight.claim((entry.group, entry.content_hash)))
        backend = FakeBackend()
        counts = await self.reconciler(FakeGraph(), backend, in_flight=in_flight).reconcile_once()
        self.assertEqual(counts["inflight"], 1)
        self.assertEqual(backend.added, [])

    async def test_presence_is_rechecked_immediately_before_resubmission(self):
        entry = self.entry()
        graph = FakeGraph(
            [None, EpisodeRef(uuid="graph-late", created_at="2026-10-22T10:05:00Z")]
        )
        backend = FakeBackend()
        counts = await self.reconciler(graph, backend).reconcile_once()
        self.assertEqual(counts["active"], 1)
        self.assertEqual(backend.added, [])
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.graphiti_uuid, "graph-late")

    async def test_backoff_prevents_a_second_retry_too_soon(self):
        entry = self.entry()
        backend = FakeBackend()
        reconciler = self.reconciler(FakeGraph(), backend)
        await reconciler.reconcile_once()
        self.clock.value += 10
        counts = await reconciler.reconcile_once()
        self.assertEqual(counts["backoff"], 1)
        self.assertEqual(len(backend.added), 1)
        self.clock.value += 60
        counts = await reconciler.reconcile_once()
        self.assertEqual(counts["retried"], 1)
        self.assertEqual(len(backend.added), 2)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).attempts, 3)

    async def test_an_unreachable_graph_leaves_rows_untouched(self):
        entry = self.entry()
        counts = await self.reconciler(FakeGraph(error=True)).reconcile_once()
        self.assertEqual(counts["unavailable"], 1)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "pending")

    async def test_a_failed_retry_submission_is_recorded(self):
        entry = self.entry()
        counts = await self.reconciler(FakeGraph(), FakeBackend(fail=True)).reconcile_once()
        self.assertEqual(counts["retry_failed"], 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 2)
        self.assertIn("graph exploded", stored.last_error)

    async def test_reconciler_writes_audit_rows(self):
        entry = self.entry()
        graph = FakeGraph([EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")])
        await self.reconciler(graph).reconcile_once()
        import sqlite3

        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT actor, tool, status FROM audit").fetchall()
        self.assertEqual(rows, [("reconciler", "reconciler", "active")])


if __name__ == "__main__":
    unittest.main()
