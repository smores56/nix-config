import asyncio
import io
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.graph import (  # noqa: E402
    EpisodeRef,
    GraphStore,
    GraphUnavailable,
    TombstoneResult,
)
from memory_mcp.normalize import content_hash, episode_uuid  # noqa: E402
from memory_mcp.reconciler import MAX_BATCH, InFlight, Reconciler, ReconcilerConfig  # noqa: E402
from memory_mcp.registry import Registry, RegistryEpisode  # noqa: E402

NOW = datetime(2026, 10, 22, 12, 0, 0, tzinfo=timezone.utc)


class FakeGraph:
    def __init__(self, results=None, *, error=False):
        self.results = list(results or [])
        self.error = error
        self.calls = []

    def episode_for(self, group, content, *, since=None):
        self.calls.append((group, content, since))
        if self.error:
            raise GraphUnavailable("connection refused")
        return self.results.pop(0) if self.results else None

    def episode_uuids(self, group, content):
        if self.error:
            raise GraphUnavailable("connection refused")
        return []

    def tombstone(self, group, episode_uuid_value, *, now):
        return TombstoneResult()


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


class RacingGraph:
    """Returns a match, but a concurrent tombstone lands before the write."""

    def __init__(self, registry, entry, ref):
        self.registry = registry
        self.entry = entry
        self.ref = ref

    def episode_for(self, group, content, *, since=None):
        self.registry.tombstone(self.entry, reason="superseded while reconciling")
        return self.ref

    def episode_uuids(self, group, content):
        return []

    def tombstone(self, group, episode_uuid_value, *, now):
        return TombstoneResult()


class RacingBackend:
    """Accepts the submission, but the row is tombstoned while it is in flight."""

    def __init__(self, registry, entry):
        self.registry = registry
        self.entry = entry
        self.added = []

    async def add_episode(self, **kwargs):
        self.added.append(kwargs)
        self.registry.tombstone(self.entry, reason="superseded while resubmitting")
        return {"message": "queued"}


class BlockingGraph:
    """A graph client that blocks its worker thread and then reports an outage."""

    def __init__(self, delay=0.05):
        self.delay = delay
        self.calls = 0

    def episode_for(self, group, content, *, since=None):
        self.calls += 1
        time.sleep(self.delay)
        raise GraphUnavailable("connection refused")

    def episode_uuids(self, group, content):
        raise GraphUnavailable("connection refused")

    def tombstone(self, group, episode_uuid_value, *, now):
        raise GraphUnavailable("connection refused")


class StubRedis:
    """A FalkorDB client that always returns the same episode rows."""

    def __init__(self, rows):
        self.rows = rows

    def execute_command(self, *args):
        if args[0] == "GRAPH.LIST":
            return [b"owner--repo"]
        return [["header"], list(self.rows), []]


class SweepGraph:
    """Pending content is absent; its episodes appear only to the sweep."""

    def __init__(self, uuids=()):
        self.uuids = list(uuids)
        self.scans = 0
        self.tombstoned = []

    def episode_for(self, group, content, *, since=None):
        return None

    def episode_uuids(self, group, content):
        self.scans += 1
        return list(self.uuids)

    def tombstone(self, group, episode_uuid_value, *, now):
        self.tombstoned.append((group, episode_uuid_value, now))
        return TombstoneResult()


class ReconcilerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)
        self.clock = Clock()

    def tearDown(self):
        self.tmp.cleanup()

    def entry(
        self,
        *,
        content="the content",
        created_at="2026-10-22T10:00:00Z",
        attempts=1,
        status="pending",
        **overrides,
    ):
        digest = content_hash(content)
        values = {
            "group": "owner--repo",
            "content_hash": digest,
            "uuid": episode_uuid("owner--repo", digest),
            "name": content,
            "content": content,
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
        stored = self.registry.queue(entry)
        if entry.status == "failed":
            self.registry.mark_failed(
                entry.group, entry.content_hash, entry.last_error or "seeded"
            )
        else:
            for _ in range(entry.attempts):
                self.registry.record_attempt(entry.group, entry.content_hash)
        return stored

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

    async def test_a_revived_row_does_not_bind_to_the_tombstoned_episode(self):
        # The registry stamps `Z` and the graph `+00:00`, and a tombstone keeps
        # its episode, so the bound must compare instants: the old episode
        # predates this write and is not its extraction.
        entry = self.entry(created_at="2026-10-22T10:00:00Z")
        graph = GraphStore(client=StubRedis([["ep-old", "2026-10-22T09:00:00+00:00"]]))
        counts = await self.reconciler(
            graph, config=ReconcilerConfig(grace=86400, backoff=60)
        ).reconcile_once()
        self.assertEqual(counts["active"], 0)
        self.assertEqual(counts["waiting"], 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "pending")
        self.assertIsNone(stored.graphiti_uuid)

    async def test_a_graph_episode_newer_than_the_row_activates_it(self):
        entry = self.entry(created_at="2026-10-22T10:00:00Z")
        graph = GraphStore(
            client=StubRedis(
                [
                    ["ep-new", "2026-10-22T10:05:00+00:00"],
                    ["ep-old", "2026-10-22T09:00:00+00:00"],
                ]
            )
        )
        counts = await self.reconciler(graph).reconcile_once()
        self.assertEqual(counts["active"], 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.graphiti_uuid, "ep-new")

    async def test_a_tombstone_before_extraction_invalidates_the_late_episode(self):
        entry = self.entry(content="tombstoned while pending")
        stored = self.registry.tombstone(entry, reason="forget this")
        self.assertIsNone(stored.graphiti_uuid)
        graph = SweepGraph(["ep-late"])
        reconciler = self.reconciler(graph)

        counts = await reconciler.reconcile_once()

        self.assertEqual(counts["swept"], 1)
        self.assertEqual([call[1] for call in graph.tombstoned], ["ep-late"])
        swept = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(swept.status, "tombstoned")
        self.assertEqual(swept.tombstoned_at, stored.tombstoned_at)
        self.assertEqual(swept.graphiti_uuid, "ep-late")

        scans = graph.scans
        counts = await reconciler.reconcile_once()

        self.assertEqual(counts["swept"], 0)
        self.assertEqual(graph.scans, scans)

    async def test_the_tombstone_sweep_is_skipped_while_the_graph_is_unavailable(self):
        entry = self.entry(content="tombstoned while pending")
        self.registry.tombstone(entry, reason="forget this")
        graph = FakeGraph(error=True)
        counts = await self.reconciler(graph).reconcile_once()
        self.assertEqual(counts["unavailable"], 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "tombstoned")
        self.assertIsNone(stored.graphiti_uuid)

    async def test_the_grace_window_is_measured_from_the_queue_clock(self):
        self.entry(created_at="2026-01-01T00:00:00Z", queued_at="2026-10-22T11:55:00Z")
        counts = await self.reconciler(FakeGraph()).reconcile_once()
        self.assertEqual(counts["waiting"], 1)

    async def test_an_old_queue_clock_is_retried_even_for_a_new_write(self):
        self.entry(created_at="2026-10-22T11:59:00Z", queued_at="2026-01-01T00:00:00Z")
        counts = await self.reconciler(FakeGraph(), FakeBackend()).reconcile_once()
        self.assertEqual(counts["retried"], 1)

    async def test_a_pending_row_within_the_grace_window_waits(self):
        entry = self.entry(created_at="2026-10-22T11:55:00Z")
        counts = await self.reconciler(FakeGraph()).reconcile_once()
        self.assertEqual(counts["waiting"], 1)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "pending")

    async def test_a_requeued_row_waits_out_the_grace_instead_of_failing(self):
        entry = self.entry(created_at="2026-01-01T00:00:00Z")
        self.registry.mark_active(entry.group, entry.content_hash, "graph-old")
        active = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(self.registry.requeue_many([active], actor="cli"), 1)
        requeued = self.registry.lookup(entry.group, entry.content_hash)
        # The queue clock restarts, so the row is inside the grace window even
        # though the memory is months old: it waits for its replay instead of
        # being resubmitted three times and marked failed in minutes. The write
        # time stays put.
        self.assertEqual(requeued.created_at, "2026-01-01T00:00:00Z")
        self.assertGreater(requeued.queued_at, "2026-10-22T12:00:00Z")
        counts = await self.reconciler(FakeGraph()).reconcile_once()
        self.assertEqual(counts["waiting"], 1)
        self.assertEqual(counts["failed"], 0)
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

    async def test_a_tombstone_between_read_and_write_is_not_resurrected(self):
        entry = self.entry()
        graph = RacingGraph(
            self.registry, entry, EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")
        )
        counts = await self.reconciler(graph).reconcile_once()
        self.assertEqual(counts["changed"], 1)
        self.assertEqual(counts["active"], 0)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "tombstoned")
        self.assertIsNone(stored.graphiti_uuid)
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT tool, status FROM audit").fetchall()
        self.assertEqual(rows, [])

    async def test_a_tombstone_during_resubmission_is_not_resurrected(self):
        entry = self.entry()
        backend = RacingBackend(self.registry, entry)
        counts = await self.reconciler(FakeGraph(), backend).reconcile_once()
        self.assertEqual(counts["changed"], 1)
        self.assertEqual(counts["retried"], 0)
        self.assertEqual(len(backend.added), 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "tombstoned")
        self.assertEqual(stored.attempts, 1)
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT tool, status FROM audit").fetchall()
        self.assertEqual(rows, [])

    async def test_a_blocking_graph_call_keeps_the_event_loop_responsive(self):
        for index in range(3):
            self.entry(content=f"content {index}")
        graph = BlockingGraph()
        ticks = 0

        async def ticker():
            nonlocal ticks
            while True:
                ticks += 1
                await asyncio.sleep(0)

        task = asyncio.create_task(ticker())
        try:
            counts = await self.reconciler(graph).reconcile_once()
            ticks_during_pass = ticks
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertGreater(ticks_during_pass, 0)
        # The first outage ends the pass: absence cannot be proven after it.
        self.assertEqual(graph.calls, 1)
        self.assertEqual(counts["unavailable"], 1)

    async def test_a_pass_is_capped_at_the_maximum_batch(self):
        for index in range(MAX_BATCH + 5):
            self.entry(content=f"content {index}", created_at="2026-10-22T11:59:00Z")
        counts = await self.reconciler(
            FakeGraph(), config=ReconcilerConfig(grace=600, backoff=60, batch=MAX_BATCH * 50)
        ).reconcile_once()
        self.assertEqual(counts["waiting"], MAX_BATCH)

    async def test_reconciler_writes_audit_rows(self):
        entry = self.entry()
        graph = FakeGraph([EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")])
        await self.reconciler(graph).reconcile_once()
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT actor, tool, status FROM audit").fetchall()
        self.assertEqual(rows, [("reconciler", "reconciler", "active")])

    async def test_a_pass_records_and_clears_the_graph_error(self):
        self.entry()
        reconciler = self.reconciler(FakeGraph(error=True))
        counts = await reconciler.reconcile_once()
        self.assertEqual(counts["unavailable"], 1)
        self.assertEqual(reconciler.last_error, "connection refused")

        reconciler.graph = FakeGraph(
            [EpisodeRef(uuid="graph-1", created_at="2026-10-22T10:05:00Z")]
        )
        await reconciler.reconcile_once()
        self.assertIsNone(reconciler.last_error)

    def test_report_prints_a_repeated_graph_failure_once(self):
        reconciler = self.reconciler(FakeGraph())
        reconciler.last_error = "connection refused"
        output = io.StringIO()
        with redirect_stderr(output):
            reconciler.report({"unavailable": 1})
            reconciler.report({"unavailable": 1})
        self.assertEqual(output.getvalue().count("graph unavailable"), 1)
        self.assertIn("connection refused", output.getvalue())

    def test_report_prints_the_progress_a_pass_made(self):
        output = io.StringIO()
        with redirect_stderr(output):
            self.reconciler(FakeGraph()).report({"active": 100, "waiting": 4})
        self.assertEqual(output.getvalue().strip(), "memory reconciler: active=100")


if __name__ == "__main__":
    unittest.main()
