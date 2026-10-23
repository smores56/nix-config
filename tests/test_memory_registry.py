import json
import sqlite3
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.normalize import (  # noqa: E402
    content_hash,
    describe_source,
    episode_name,
    episode_uuid,
    normalize_content,
    normalize_tags,
)
from memory_mcp.registry import (  # noqa: E402
    SCHEMA_VERSION,
    AmbiguousRef,
    Audit,
    Registry,
    RegistryEpisode,
    SchemaVersionError,
    age_seconds,
    parse_timestamp,
)


class NormalizeTests(unittest.TestCase):
    def test_line_endings_and_trailing_space_normalize(self):
        self.assertEqual(normalize_content("  a  \r\nb\t\r\n\r\n\r\nc  \n"), "a\nb\n\nc")

    def test_inline_space_runs_collapse(self):
        self.assertEqual(normalize_content("a \t  b"), "a b")

    def test_hash_is_stable_across_formatting(self):
        self.assertEqual(
            content_hash(normalize_content("one\r\n\r\ntwo\n")),
            content_hash(normalize_content("one\n\ntwo")),
        )

    def test_empty_content_is_rejected(self):
        for value in ("", " \n\t\n "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_content(value)

    def test_a_nul_byte_is_rejected_before_storage(self):
        with self.assertRaises(ValueError) as caught:
            normalize_content("before\x00after")
        self.assertIn("NUL", str(caught.exception))

    def test_uuid_is_deterministic_and_group_scoped(self):
        digest = content_hash("hello")
        self.assertEqual(episode_uuid("a--b", digest), episode_uuid("a--b", digest))
        self.assertNotEqual(episode_uuid("a--b", digest), episode_uuid("c--d", digest))

    def test_uuid_matches_uuid5_of_group_and_hash(self):
        import uuid

        digest = content_hash("hello")
        expected = str(uuid.uuid5(uuid.NAMESPACE_URL, f"a--b:{digest}"))
        self.assertEqual(episode_uuid("a--b", digest), expected)

    def test_episode_name_comes_from_first_line(self):
        self.assertEqual(episode_name("First   line\nsecond", "abc"), "First line")
        self.assertEqual(episode_name("", "0123456789abcdef"), "memory 0123456789ab")

    def test_tags_are_sanitized_and_deduped(self):
        self.assertEqual(normalize_tags(["Foo Bar", "foo-bar", "!!", "x" * 40]), ["foo-bar", "x" * 24])

    def test_source_description_is_human_readable_only(self):
        self.assertEqual(
            describe_source("sdlc", "issue-215#design", "2026-10-03T00:00:00Z"),
            "sdlc issue-215#design (2026-10-03)",
        )
        self.assertNotIn("=", describe_source("notes", "note:a.md#body"))
        self.assertEqual(describe_source("agent", "", ""), "agent")


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self, entry: RegistryEpisode) -> RegistryEpisode:
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

    def entry(self, group="owner--repo", digest="a" * 64, status="pending"):
        return RegistryEpisode(
            group=group,
            content_hash=digest,
            uuid=episode_uuid(group, digest),
            name="a memory",
            content="the content",
            kind="text",
            origin="agent",
            origin_ref="",
            actor="maki",
            cwd="/home/smores/code/example",
            tags=("one", "two"),
            valid_at="2026-01-01T00:00:00Z",
            created_at="2026-01-01T00:00:00Z",
            status=status,
        )

    def test_queue_and_lookup_keeps_typed_fields(self):
        entry = self.entry()
        self.assertEqual(self.registry.queue(entry), entry)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash), entry)

    def test_queueing_twice_keeps_one_row(self):
        entry = self.entry()
        self.registry.queue(entry)
        self.registry.queue(entry)
        self.assertEqual(self.registry.stats(entry.group)["total"], 1)

    def test_tags_are_stored_as_json_array(self):
        entry = self.entry()
        self.seed(entry)
        with sqlite3.connect(self.registry.db_path) as conn:
            raw = conn.execute("SELECT tags FROM episodes").fetchone()[0]
        self.assertEqual(json.loads(raw), ["one", "two"])
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).tags, ("one", "two"))

    def test_queue_clears_prior_graph_identity_and_tombstone(self):
        entry = self.entry(status="tombstoned")
        self.seed(replace(entry, graphiti_uuid="g-1", tombstone_reason="old"))
        queued = self.registry.queue(replace(entry, status="pending"))
        self.assertEqual(queued.status, "pending")
        self.assertEqual(queued.attempts, 0)
        self.assertIsNone(queued.graphiti_uuid)
        self.assertIsNone(queued.tombstone_reason)

    def test_mark_active_records_the_graph_uuid(self):
        entry = self.entry()
        self.seed(entry)
        self.registry.mark_active(entry.group, entry.content_hash, "graph-123")
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "graph-123")

    def test_mark_failed_records_the_reason(self):
        entry = self.entry()
        self.seed(entry)
        self.registry.mark_failed(entry.group, entry.content_hash, "absent")
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "failed")
        self.assertEqual(stored.last_error, "absent")

    def test_record_attempt_counts_and_audits_in_one_transaction(self):
        entry = self.entry()
        self.seed(entry)
        updated = self.registry.record_attempt(
            entry.group,
            entry.content_hash,
            error=None,
            audit=Audit(
                actor="maki",
                group=entry.group,
                tool="memory_write",
                status="queued",
                content_hash=entry.content_hash,
                uuid=entry.uuid,
            ),
        )
        self.assertEqual(updated.attempts, 1)
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT tool, status FROM audit").fetchall()
        self.assertEqual(rows, [("memory_write", "queued")])

    def test_find_exact_uuid_hash_prefix_and_origin_ref(self):
        entry = self.entry()
        self.seed(entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.uuid), entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.content_hash), entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.content_hash[:12]), entry)
        self.assertIsNone(self.registry.find_exact("other--repo", entry.uuid))

    def test_find_exact_origin_ref(self):
        entry = replace(self.entry(), origin="sdlc", origin_ref="issue-215#design")
        self.seed(entry)
        self.assertEqual(
            self.registry.find_exact(entry.group, "sdlc:issue-215#design"), entry
        )
        self.assertIsNone(self.registry.find_exact(entry.group, "sdlc:issue-215#plan"))

    def test_find_exact_does_not_match_names_or_short_prefixes(self):
        entry = self.entry()
        self.seed(entry)
        self.assertIsNone(self.registry.find_exact(entry.group, "a memory"))
        self.assertIsNone(self.registry.find_exact(entry.group, entry.content_hash[:11]))
        self.assertIsNone(self.registry.find_exact(entry.group, "%" * 12))

    def test_find_exact_raises_on_an_ambiguous_hash_prefix(self):
        first = replace(self.entry(digest="a" * 64), uuid="uuid-1")
        second = replace(self.entry(digest="a" * 63 + "b"), uuid="uuid-2")
        self.seed(first)
        self.seed(second)
        with self.assertRaises(AmbiguousRef):
            self.registry.find_exact(first.group, "a" * 12)

    def test_find_exact_lowercases_uuid_and_origin_refs(self):
        entry = replace(self.entry(), origin="sdlc", origin_ref="ISSUE-215#DESIGN")
        self.seed(entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.uuid.upper()), entry)
        self.assertEqual(
            self.registry.find_exact(entry.group, "SDLC:issue-215#design"), entry
        )
        self.assertEqual(
            self.registry.find_exact(entry.group, entry.content_hash[:12].upper()), entry
        )

    def test_tombstone_marks_status_without_deleting(self):
        entry = self.entry(status="active")
        self.seed(entry)
        updated = self.registry.tombstone(entry, reason="superseded")
        self.assertEqual(updated.status, "tombstoned")
        self.assertIsNotNone(updated.tombstoned_at)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned")
        stats = self.registry.stats(entry.group)
        self.assertEqual(stats["tombstoned"], 1)
        self.assertEqual(stats["active"], 0)

    def test_pending_lists_only_pending_rows_oldest_first(self):
        newer = replace(self.entry(digest="b" * 64), created_at="2026-01-02T00:00:00Z")
        older = replace(self.entry(digest="c" * 64), created_at="2026-01-01T00:00:00Z")
        self.seed(newer)
        self.seed(older)
        self.seed(self.entry(digest="d" * 64, status="active"))
        pending = self.registry.pending()
        self.assertEqual([item.content_hash for item in pending], ["c" * 64, "b" * 64])

    def test_by_graphiti_uuids_joins_rows(self):
        first = replace(self.entry(digest="b" * 64), graphiti_uuid="g-1")
        second = replace(self.entry(digest="c" * 64), graphiti_uuid="g-2")
        self.seed(first)
        self.seed(second)
        found = self.registry.by_graphiti_uuids({"g-1", "g-2", "missing"})
        self.assertEqual(set(found), {"g-1", "g-2"})
        self.assertEqual(found["g-1"].content_hash, "b" * 64)

    def test_lookup_many_handles_multiple_chunks(self):
        entries = [
            self.entry(digest=f"{index:064x}") for index in range(5, 0, -1)
        ]
        for entry in entries:
            self.seed(entry)
        digests = [entry.content_hash for entry in entries] + ["f" * 64]
        found = self.registry.lookup_many(entries[0].group, digests, chunk=2)
        self.assertEqual(set(found), {entry.content_hash for entry in entries})
        self.assertEqual(found[entries[2].content_hash], entries[2])

    def test_mark_active_and_mark_failed_are_status_guarded(self):
        entry = self.entry()
        self.seed(entry)
        self.assertEqual(self.registry.mark_active(entry.group, entry.content_hash, "g-1"), True)
        self.assertEqual(self.registry.mark_active(entry.group, entry.content_hash, "g-2"), False)
        self.assertEqual(self.registry.mark_failed(entry.group, entry.content_hash, "late"), False)
        self.assertEqual(self.registry.record_attempt(entry.group, entry.content_hash), None)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "g-1")
        self.assertIsNone(stored.last_error)

    def test_active_page_walks_in_creation_order(self):
        for index, digest in enumerate(("a" * 64, "b" * 64, "c" * 64)):
            entry = replace(
                self.entry(digest=digest, status="active"),
                created_at=f"2026-01-0{index + 1}T00:00:00Z",
            )
            self.seed(entry)
        first = self.registry.active_page(after=None, limit=2)
        self.assertEqual([entry.content_hash[:1] for entry in first], ["a", "b"])
        cursor = (first[-1].created_at, first[-1].content_hash, first[-1].group)
        rest = self.registry.active_page(after=cursor, limit=2)
        self.assertEqual([entry.content_hash[:1] for entry in rest], ["c"])
        end = (rest[-1].created_at, rest[-1].content_hash, rest[-1].group)
        self.assertEqual(self.registry.active_page(after=end, limit=2), [])

    def test_active_page_narrows_to_one_group(self):
        self.seed(self.entry(group="a--one", digest="a" * 64, status="active"))
        self.seed(self.entry(group="b--two", digest="b" * 64, status="active"))
        rows = self.registry.active_page(after=None, limit=10, group="b--two")
        self.assertEqual([entry.group for entry in rows], ["b--two"])

    def test_requeue_many_restarts_the_queue_clock(self):
        seeded = self.seed(self.entry(status="active"))
        entry = self.registry.lookup(seeded.group, seeded.content_hash)
        self.assertEqual(self.registry.requeue_many([entry], actor="cli"), 1)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 0)
        self.assertIsNone(stored.graphiti_uuid)
        self.assertIsNone(stored.last_error)
        self.assertGreater(stored.created_at, entry.created_at)
        with sqlite3.connect(self.registry.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = [dict(row) for row in conn.execute("SELECT * FROM audit")]
        self.assertEqual([(row["tool"], row["status"]) for row in rows], [("memory_reindex", "requeued")])
        self.assertIn(entry.created_at, rows[0]["details"])

    def test_requeue_many_ignores_rows_that_are_not_active(self):
        for status in ("pending", "failed", "tombstoned"):
            seeded = self.seed(self.entry(digest=status[0] * 64, status=status))
            entry = self.registry.lookup(seeded.group, seeded.content_hash)
            self.assertEqual(self.registry.requeue_many([entry], actor="cli"), 0, status)
            self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, status)

    def test_requeue_many_keeps_a_row_whose_graph_uuid_changed(self):
        seeded = self.seed(self.entry(status="active"))
        entry = self.registry.lookup(seeded.group, seeded.content_hash)
        self.registry.mark_active(entry.group, entry.content_hash, "graph-newer", from_statuses=("active",))
        stale = replace(entry, graphiti_uuid="graph-old")
        self.assertEqual(self.registry.requeue_many([stale], actor="cli"), 0)
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "graph-newer")

    def test_tombstone_wins_over_a_concurrent_state_write(self):
        entry = self.entry()
        self.seed(entry)
        tombstoned = self.registry.tombstone(entry, reason="gone")
        self.assertEqual(tombstoned.status, "tombstoned")
        self.assertFalse(self.registry.mark_active(entry.group, entry.content_hash, "g-1"))
        self.assertIsNone(self.registry.record_attempt(entry.group, entry.content_hash))
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned")

    def test_promotion_bookkeeping(self):
        entry = self.entry()
        self.seed(entry)
        self.assertFalse(self.registry.is_promoted(entry.uuid, "global"))
        self.registry.record_promotion(
            source_uuid=entry.uuid,
            target_uuid=episode_uuid("global", entry.content_hash),
            source_group=entry.group,
            target_group="global",
            actor="cli",
        )
        self.assertTrue(self.registry.is_promoted(entry.uuid, "global"))
        self.assertTrue(self.registry.is_promoted(entry.uuid, "global"))

    def test_stats_count_every_status(self):
        self.seed(self.entry(digest="a" * 64, status="active"))
        self.seed(self.entry(digest="b" * 64, status="pending"))
        self.seed(self.entry(digest="c" * 64, status="failed"))
        self.seed(self.entry(digest="d" * 64, status="tombstoned"))
        stats = self.registry.stats("owner--repo")
        self.assertEqual((stats["total"], stats["active"], stats["pending"], stats["failed"]), (4, 1, 1, 1))
        self.assertEqual(stats["tombstoned"], 1)

    def test_audit_table_replaces_the_jsonl_log(self):
        self.registry.audit(
            Audit(
                actor="cli",
                group="g",
                tool="memory_write",
                status="queued",
                content_hash="x",
                details={"note": "one"},
            )
        )
        self.registry.audit(Audit(actor="maki", group="g", tool="memory_search", status="ok"))
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute(
                "SELECT actor, tool, status, details FROM audit ORDER BY id"
            ).fetchall()
        self.assertEqual([(row[0], row[1], row[2]) for row in rows], [
            ("cli", "memory_write", "queued"),
            ("maki", "memory_search", "ok"),
        ])
        self.assertEqual(json.loads(rows[0][3]), {"note": "one"})
        self.assertFalse((Path(self.tmp.name) / "audit.jsonl").exists())

    def test_a_fresh_registry_records_the_schema_version(self):
        with sqlite3.connect(self.registry.db_path) as conn:
            version = conn.execute("PRAGMA user_version").fetchone()[0]
        self.assertEqual(version, SCHEMA_VERSION)

    def test_a_newer_schema_version_is_refused(self):
        with sqlite3.connect(self.registry.db_path) as conn:
            conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION + 1}")
        with self.assertRaises(SchemaVersionError) as caught:
            Registry(self.tmp.name)
        self.assertIn("expected", str(caught.exception))

    def test_an_unversioned_database_with_tables_is_refused(self):
        unversioned = Path(self.tmp.name) / "legacy"
        unversioned.mkdir()
        with sqlite3.connect(unversioned / "registry.sqlite") as conn:
            conn.execute("CREATE TABLE episodes (group_id TEXT)")
            conn.execute("PRAGMA user_version = 0")
        with self.assertRaises(SchemaVersionError) as caught:
            Registry(str(unversioned))
        self.assertIn("unversioned", str(caught.exception))

    def test_timestamp_helpers(self):
        self.assertIsNotNone(parse_timestamp("2026-01-01T00:00:00Z"))
        self.assertIsNone(parse_timestamp("not-a-timestamp"))
        self.assertEqual(age_seconds("2026-01-01T00:00:00Z", parse_timestamp("2026-01-01T01:00:00Z")), 3600)
        self.assertIsNone(age_seconds("bad", parse_timestamp("2026-01-01T00:00:00Z")))


if __name__ == "__main__":
    unittest.main()
